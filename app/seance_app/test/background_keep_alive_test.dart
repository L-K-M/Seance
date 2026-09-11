import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/background_keep_alive.dart';

/// Records backend calls so the state machine's exact activation protocol can
/// be asserted without a platform.
class RecordingBackend implements BackgroundKeepAliveBackend {
  final calls = <String>[];

  @override
  Future<void> activate(int sessionCount) async =>
      calls.add('activate $sessionCount');

  @override
  Future<void> sessionCountChanged(int sessionCount) async =>
      calls.add('count $sessionCount');

  @override
  Future<void> deactivate() async => calls.add('deactivate');
}

/// Longer than the state machine's internal zero-crossing grace, so a test
/// that pumps it has deterministically left the grace window.
const pastGrace = Duration(seconds: 5);

void main() {
  testWidgets('activates on the first live session and deactivates on the last',
      (tester) async {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(1);
    expect(backend.calls, ['activate 1']);

    keepAlive.refresh(0);
    await tester.pump(pastGrace);

    expect(backend.calls, ['activate 1', 'deactivate']);
  });

  testWidgets('updates the count while anchored instead of re-activating',
      (tester) async {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(1);
    keepAlive.refresh(3);
    keepAlive.refresh(2);

    expect(backend.calls, ['activate 1', 'count 3', 'count 2']);
  });

  testWidgets('coalesces repeated counts into a single call', (tester) async {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(2);
    keepAlive.refresh(2);
    keepAlive.refresh(0);
    keepAlive.refresh(0);
    await tester.pump(pastGrace);

    expect(backend.calls, ['activate 2', 'deactivate']);
  });

  testWidgets('graces zero-crossings instead of cycling the anchor',
      (tester) async {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    // A failed connect: activate, drop to zero, reconnect — all inside the
    // grace window. The service must be started once, not stopped/started;
    // the count never visibly changed, so nothing is re-sent either.
    keepAlive.refresh(1);
    keepAlive.refresh(0);
    keepAlive.refresh(1);

    expect(backend.calls, ['activate 1']);

    // But a count that ends up different after the dip still updates.
    keepAlive.refresh(0);
    keepAlive.refresh(2);

    expect(backend.calls, ['activate 1', 'count 2']);
  });

  testWidgets('deactivation happens only after the grace elapses',
      (tester) async {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(2);
    keepAlive.refresh(0);
    // Inside the grace: still anchored.
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.calls, ['activate 2']);

    await tester.pump(pastGrace);
    expect(backend.calls, ['activate 2', 'deactivate']);
  });

  testWidgets('stop drops the anchor immediately, grace ignored',
      (tester) async {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(1);
    keepAlive.refresh(0);
    keepAlive.stop();

    expect(backend.calls, ['activate 1', 'deactivate']);
  });

  test('a disabled keep-alive never activates and drops an active anchor', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend, enabled: false);

    keepAlive.refresh(2);
    expect(backend.calls, isEmpty);

    keepAlive.setEnabled(true);
    keepAlive.refresh(2);
    keepAlive.refresh(1);
    expect(backend.calls, ['activate 2', 'count 1']);

    keepAlive.setEnabled(false);
    // Further session churn while disabled must not resurrect the anchor.
    keepAlive.refresh(3);
    expect(backend.calls, ['activate 2', 'count 1', 'deactivate']);
  });

  test('re-enabling re-anchors with the last reported count', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(2);
    keepAlive.setEnabled(false);
    keepAlive.setEnabled(true);

    expect(backend.calls, ['activate 2', 'deactivate', 'activate 2']);
  });

  test('churn while disabled updates the count used on re-enable', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(2);
    keepAlive.setEnabled(false);
    keepAlive.refresh(4);
    keepAlive.setEnabled(true);

    expect(backend.calls, ['activate 2', 'deactivate', 'activate 4']);
  });

  test('re-enabling after all sessions closed does not anchor', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(2);
    keepAlive.setEnabled(false);
    keepAlive.refresh(0);
    keepAlive.setEnabled(true);

    expect(backend.calls, ['activate 2', 'deactivate']);
  });

  test('enablement state changes that change nothing call nothing', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend, enabled: true);

    keepAlive.setEnabled(true);
    keepAlive.setEnabled(false);
    keepAlive.setEnabled(false);

    expect(backend.calls, isEmpty);
  });
}
