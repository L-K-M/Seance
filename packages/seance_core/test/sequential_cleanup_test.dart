import 'dart:async';

import 'package:seance_core/src/ssh/sequential_cleanup.dart';
import 'package:test/test.dart';

void main() {
  const actionTimeout = Duration(milliseconds: 10);

  test('single-flight cleanup shares its result', () async {
    final cleanup = SingleFlightCleanup();
    final release = Completer<void>();
    var calls = 0;

    final first = cleanup.run(() {
      calls++;
      return release.future;
    });
    final second = cleanup.run(() {
      calls++;
    });

    expect(second, same(first));
    expect(calls, 1);

    release.complete();
    await first;
    expect(cleanup.run(() => calls++), same(first));
    expect(calls, 1);
  });

  test('single-flight cleanup contains synchronous reentry', () async {
    final cleanup = SingleFlightCleanup();
    late Future<void> nested;
    var calls = 0;

    final first = cleanup.run(() {
      calls++;
      nested = cleanup.run(() => calls++);
    });

    expect(nested, same(first));
    await first;
    expect(calls, 1);
  });

  test('single-flight cleanup delivers a failure once', () async {
    final cleanup = SingleFlightCleanup();
    final failure = StateError('cleanup failed');
    var laterActionRan = false;

    await expectLater(cleanup.run(() => throw failure), throwsA(same(failure)));
    await cleanup.run(() => laterActionRan = true);

    expect(laterActionRan, isFalse);
  });

  test('cleanup attempts every action and preserves the first error', () async {
    final firstError = StateError('first');
    final actionsRun = <String>[];

    await expectLater(
      runSequentialCleanup([
        () {
          actionsRun.add('first');
          throw firstError;
        },
        () => actionsRun.add('second'),
        () {
          actionsRun.add('third');
          throw StateError('third');
        },
      ], actionTimeout: actionTimeout),
      throwsA(same(firstError)),
    );

    expect(actionsRun, ['first', 'second', 'third']);
  });

  test('ignored cleanup failures remain bounded', () async {
    var laterActionRan = false;

    await runSequentialCleanup(
      [() => Completer<void>().future, () => laterActionRan = true],
      actionTimeout: actionTimeout,
      failureMode: CleanupFailureMode.ignore,
    );

    expect(laterActionRan, isTrue);
  });
}
