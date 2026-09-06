import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The mutation queue's re-entrancy guard: it must catch the one shape of
/// call that deadlocks the queue, and nothing else.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  late AppState state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-mutation-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services);
  });

  tearDown(() async {
    state.dispose();
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  ServerConfig server(String id) => ServerConfig(
        id: id,
        label: id,
        host: '$id.example.com',
        username: 'deploy',
        createdAt: 1,
        updatedAt: 1,
      );

  test('a queued call from inside a running action is refused', () async {
    // The deadlock is an action awaiting a mutation queued behind itself,
    // forever and silently. The guard cannot tell an awaited call from a
    // fire-and-forget one, so it refuses every queued call made from inside
    // the running action — and a listener fires inside it, which is the one
    // shape a test can produce without a seam into the action body.
    // A closure rather than the future: `throwsStateError` invokes it, so a
    // guard that ever threw synchronously would still be caught here instead
    // of escaping into the running mutation and failing at the matcher.
    Future<void> Function()? inner;
    void reenter() => inner ??= () => state.saveServer(server('b'));
    state.addListener(reenter);
    await state.saveServer(server('a'));
    state.removeListener(reenter);
    await expectLater(inner, throwsStateError);
  });

  test('a changed source is named as it appears in the list now', () async {
    // The caller's snapshot can be stale in every field, the label included:
    // an error naming a server the list no longer shows sends the user
    // looking for a row that is not there.
    await state.saveServer(server('a'));
    final snapshot = (await services.configStore.getServer('a'))!;
    await services.configStore.putServer(
      snapshot.copyWith(label: 'renamed', secretRef: 'moved', updatedAt: 2),
    );
    await expectLater(
      state.duplicateServer(snapshot),
      throwsA(predicate((e) => '$e'.contains('renamed'))),
    );
  });

  test('a callback carrying a finished mutation\'s zone may queue', () async {
    // A listener's microtask or a timer is bound to the zone it was created
    // in, and keeps it after the mutation ends. Refusing it then guarded
    // against a deadlock that cannot happen: the queue is idle, or running
    // some other action this call would simply wait behind.
    final outerZone = Zone.current;
    Zone? insideMutation;
    void capture() => insideMutation ??= Zone.current;
    state.addListener(capture);
    await state.saveServer(server('a'));
    state.removeListener(capture);
    // Not merely captured: captured *inside* the mutation's zone. From the
    // test's own zone the call below is the ordinary allowed path, and the
    // guard would go unexercised.
    expect(insideMutation, allOf(isNotNull, isNot(same(outerZone))));

    await expectLater(
      insideMutation!.run(() => state.saveServer(server('b'))),
      completes,
    );
    expect(state.servers.map((s) => s.id), containsAll(['a', 'b']));
  });

  test('two callers arriving while an action is suspended are serialized',
      () async {
    // The normal case the queue exists for, which a plain busy flag would
    // have read as re-entry.
    await Future.wait([
      state.saveServer(server('a')),
      state.saveServer(server('b')),
      state.saveServer(server('c')),
    ]);
    expect(state.servers.map((s) => s.id).toSet(), {'a', 'b', 'c'});
  });
}
