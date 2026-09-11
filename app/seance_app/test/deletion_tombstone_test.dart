import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/file_stores.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Regression for issue #54: a delete must leave a durable tombstone so the
/// next sync pushes it, or the deleted record returns on the next full pull.
/// The coordinator's own tests prove the tombstone then propagates and is not
/// re-adopted; these prove the app records it, durably, the way the coordinator
/// expects to find it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-deletion-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
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

  test('deleting a server records a durable tombstone', () async {
    final services = await AppServices.initialize();
    final state = AppState(services);
    addTearDown(() async {
      state.dispose();
      await services.probe.dispose();
    });

    await state.saveServer(server('a'));
    await state.deleteServer('a');

    final pending = await services.tombstoneStore.all();
    expect(pending, hasLength(1));
    expect(pending.single.id, 'a');
    expect(pending.single.deleted, isTrue);
    expect(pending.single.blob, isEmpty, reason: 'a tombstone leaks no payload');
    expect(pending.single.deviceId, services.settings.deviceId);
    expect(await services.configStore.getServer('a'), isNull);

    // A fresh services on the same directory still owes the deletion, so an
    // app restart before the next sync round does not lose it.
    final reopened = await AppServices.initialize();
    addTearDown(() => reopened.probe.dispose());
    final stillPending = await reopened.tombstoneStore.all();
    expect(stillPending, hasLength(1));
    expect(stillPending.single.id, 'a');
    expect(stillPending.single.deleted, isTrue);
  });

  test('a delete stamps its tombstone past a future-dated record', () async {
    // Clock skew or a same-ms tie must not let the live copy on the sync server
    // win last-write-wins and resurrect the row. The tombstone is stamped
    // max(now, prior.updatedAt + 1), so it outranks every version this device
    // has seen while still losing to a peer's genuinely newer edit.
    final services = await AppServices.initialize();
    final state = AppState(services);
    addTearDown(() async {
      state.dispose();
      await services.probe.dispose();
    });

    final future = DateTime.now().millisecondsSinceEpoch + 1000000;
    await state.saveServer(ServerConfig(
      id: 'a',
      label: 'a',
      host: 'a.example.com',
      username: 'u',
      createdAt: 1,
      updatedAt: future,
    ));
    await state.deleteServer('a');

    final tombstone = (await services.tombstoneStore.all()).single;
    expect(tombstone.id, 'a');
    expect(tombstone.updatedAt, future + 1,
        reason: 'the tombstone must outrank the record it deletes');
  });

  test('deleting a snippet records a snippet-scoped tombstone', () async {
    final services = await AppServices.initialize();
    final state = AppState(services);
    addTearDown(() async {
      state.dispose();
      await services.probe.dispose();
    });

    await state.saveSnippet(const Snippet(
      id: 's1',
      title: 'list',
      body: 'ls -la',
      createdAt: 1,
      updatedAt: 1,
    ));
    await state.deleteSnippet('s1');

    final pending = await services.tombstoneStore.all();
    expect(pending, hasLength(1));
    expect(pending.single.id, 'snippet:s1',
        reason: 'the tombstone id must match the snippet record id');
    expect(pending.single.deleted, isTrue);
  });

  test('re-saving a server cancels its pending deletion tombstone', () async {
    final services = await AppServices.initialize();
    final state = AppState(services);
    addTearDown(() async {
      state.dispose();
      await services.probe.dispose();
    });

    await state.saveServer(server('a'));
    await state.deleteServer('a');
    expect(await services.tombstoneStore.all(), hasLength(1));

    await state.saveServer(server('a'));
    expect(await services.tombstoneStore.all(), isEmpty,
        reason: 're-saving an id clears its pending deletion');
    expect(await services.configStore.getServer('a'), isNotNull);
  });

  test('re-saving a snippet cancels its pending deletion tombstone', () async {
    final services = await AppServices.initialize();
    final state = AppState(services);
    addTearDown(() async {
      state.dispose();
      await services.probe.dispose();
    });

    const snippet = Snippet(
        id: 's1', title: 'list', body: 'ls -la', createdAt: 1, updatedAt: 1);
    await state.saveSnippet(snippet);
    await state.deleteSnippet('s1');
    expect(await services.tombstoneStore.all(), hasLength(1));

    await state.saveSnippet(snippet);
    expect(await services.tombstoneStore.all(), isEmpty,
        reason: 're-saving a snippet clears its pending deletion');
  });

  test('FileTombstoneStore round-trips and tolerates a corrupt file', () async {
    final file = File('${directory.path}/deleted_records.json');
    final store = FileTombstoneStore(file);
    await store.add(
        EncryptedRecord.tombstone(id: 'x', updatedAt: 42, deviceId: 'D'));

    final reloaded = await FileTombstoneStore(file).all();
    expect(reloaded, hasLength(1));
    expect(reloaded.single.id, 'x');
    expect(reloaded.single.updatedAt, 42);
    expect(reloaded.single.deviceId, 'D');
    expect(reloaded.single.deleted, isTrue);
    expect(reloaded.single.blob, isEmpty);

    await store.remove('x');
    expect(await FileTombstoneStore(file).all(), isEmpty);

    // A corrupt file must not wedge startup: it reads as empty (quarantined),
    // like the other file-backed stores.
    await file.writeAsString('{not valid json');
    expect(await FileTombstoneStore(file).all(), isEmpty);
  });

  test('FileTombstoneStore.add keeps the higher-stamped tombstone', () async {
    // A retry or double-delete after the row is gone recomputes an older
    // stamp; a blind overwrite would regress the pending skew-beating
    // tombstone and let the live record win last-write-wins.
    final file = File('${directory.path}/deleted_records.json');
    final store = FileTombstoneStore(file);

    await store
        .add(EncryptedRecord.tombstone(id: 'x', updatedAt: 2000, deviceId: 'D'));
    await store
        .add(EncryptedRecord.tombstone(id: 'x', updatedAt: 1000, deviceId: 'D'));
    expect((await store.all()).single.updatedAt, 2000,
        reason: 'an older stamp must not regress the pending tombstone');

    await store
        .add(EncryptedRecord.tombstone(id: 'x', updatedAt: 3000, deviceId: 'D'));
    expect((await store.all()).single.updatedAt, 3000,
        reason: 'a newer stamp replaces it');
  });
}
