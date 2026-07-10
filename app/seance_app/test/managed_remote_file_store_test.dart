import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/managed_remote_file.dart';
import 'package:seance_app/services/managed_remote_file_store.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  late Directory temporaryDirectory;
  late File indexFile;
  late Directory checkoutRoot;
  late ManagedRemoteFileStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'seance-managed-files-',
    );
    indexFile = File('${temporaryDirectory.path}/state/managed-files.json');
    checkoutRoot = Directory('${temporaryDirectory.path}/support/checkouts');
    store = ManagedRemoteFileStore(
      indexFile: indexFile,
      checkoutRoot: checkoutRoot,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('model JSON round-trips metadata but not runtime state', () {
    final original = _managedFile(
      id: 'edit-1',
      localPath: 'checkout/file.txt',
      dirty: true,
    );

    final json = original.toJson();
    expect(json, isNot(contains('dirty')));
    expect(json, isNot(contains('missing')));

    final restored = ManagedRemoteFile.fromJson(json);
    expect(restored.id, original.id);
    expect(restored.serverId, original.serverId);
    expect(restored.editSessionId, original.editSessionId);
    expect(restored.remotePath, original.remotePath);
    expect(restored.localPath, original.localPath);
    expect(restored.baselineSha256, original.baselineSha256);
    expect(restored.remoteSnapshot.name, 'file.txt');
    expect(restored.remoteSnapshot.type, RemoteFileType.file);
    expect(restored.remoteSnapshot.size, 3);
    expect(restored.remoteSnapshot.mode, 0x81a4);
    expect(
      restored.remoteSnapshot.modifiedAt,
      DateTime.utc(2026, 7, 10, 12, 30),
    );
    expect(restored.dirty, isFalse);
    expect(restored.missing, isFalse);
  });

  test('model JSON rejects inconsistent or mistyped data', () {
    final json = _managedFile(
      id: 'edit-1',
      localPath: 'checkout/file.txt',
    ).toJson();

    expect(
      () => ManagedRemoteFile.fromJson({...json, 'id': 7}),
      throwsFormatException,
    );
    expect(
      () =>
          ManagedRemoteFile.fromJson({...json, 'remotePath': '/different.txt'}),
      throwsFormatException,
    );
    expect(
      () => ManagedRemoteFile.fromJson({
        ...json,
        'remoteSnapshot': {
          ...(json['remoteSnapshot']! as Map<String, dynamic>),
          'type': 'socket',
        },
      }),
      throwsFormatException,
    );
  });

  test('persists through restart and serializes concurrent writes', () async {
    final first = await _createManagedCheckout(
      store,
      id: 'edit-a',
      serverId: 'server-a',
      sessionId: 'session-a',
      content: 'one',
    );
    await store.put(first);

    final second = _managedFile(
      id: 'edit-b',
      serverId: 'server-a',
      sessionId: 'session-b',
      localPath: store.checkoutPathFor(id: 'edit-b', fileName: 'b.txt'),
    );
    final third = _managedFile(
      id: 'edit-c',
      serverId: 'server-b',
      sessionId: 'session-a',
      localPath: store.checkoutPathFor(id: 'edit-c', fileName: 'c.txt'),
    );
    await Future.wait([store.put(second), store.put(third)]);

    final restarted = ManagedRemoteFileStore(
      indexFile: indexFile,
      checkoutRoot: checkoutRoot,
    );
    expect((await restarted.list()).map((file) => file.id), [
      'edit-a',
      'edit-b',
      'edit-c',
    ]);
    expect((await restarted.listForServer('server-a')).length, 2);
    expect(
      (await restarted.listForSession(
        'session-a',
        serverId: 'server-a',
      )).single.id,
      'edit-a',
    );

    final updated = second.copyWith(
      remotePath: '/home/test/renamed.txt',
      remoteSnapshot: _snapshot('/home/test/renamed.txt'),
    );
    await restarted.update(updated);
    expect((await restarted.get('edit-b'))!.remotePath, contains('renamed'));
    await expectLater(
      restarted.update(_managedFile(id: 'absent', localPath: 'x/y')),
      throwsStateError,
    );

    final decoded = jsonDecode(await indexFile.readAsString()) as Map;
    expect(decoded['version'], 1);
    expect(decoded['files'], hasLength(3));
    expect(await File('${indexFile.path}.tmp').exists(), isFalse);
  });

  test('quarantines malformed and semantically invalid indexes', () async {
    await indexFile.parent.create(recursive: true);
    await indexFile.writeAsString('{"version":1,"files":[');

    expect(await store.list(), isEmpty);
    final corrupt = File('${indexFile.path}.corrupt');
    expect(await indexFile.exists(), isFalse);
    expect(await corrupt.exists(), isTrue);
    expect(await corrupt.readAsString(), '{"version":1,"files":[');

    final invalid = _managedFile(id: 'escape', localPath: '../outside.txt');
    await indexFile.writeAsString(
      jsonEncode({
        'version': 1,
        'files': [invalid.toJson()],
      }),
    );
    final restarted = ManagedRemoteFileStore(
      indexFile: indexFile,
      checkoutRoot: checkoutRoot,
    );
    expect(await restarted.list(), isEmpty);
    expect(await indexFile.exists(), isFalse);
    expect(await corrupt.exists(), isTrue);
  });

  test('rejects absolute, traversal, ambiguous, and Windows paths', () async {
    final outside = File('${temporaryDirectory.path}/outside.txt');
    await outside.writeAsString('keep');
    final invalidPaths = <String>[
      '',
      '../outside.txt',
      'checkout/../../outside.txt',
      '/tmp/outside.txt',
      r'C:\temp\outside.txt',
      r'checkout\outside.txt',
      'checkout//file.txt',
      'checkout/./file.txt',
      'checkout/name:stream',
      'checkout/CON',
      'checkout/file. ',
      'checkout/file?.txt',
    ];

    for (final path in invalidPaths) {
      expect(() => store.checkoutFile(path), throwsArgumentError, reason: path);
    }
    expect(await outside.readAsString(), 'keep');

    await expectLater(
      store.put(_managedFile(id: 'escape', localPath: '../outside.txt')),
      throwsArgumentError,
    );
    expect(await indexFile.exists(), isFalse);
  });

  test(
    'streamed hashing and reconciliation detect edits and missing files',
    () async {
      final managed = await _createManagedCheckout(
        store,
        id: 'edit-1',
        serverId: 'server-a',
        sessionId: 'session-a',
        content: 'abc',
      );
      final local = store.checkoutFile(managed.localPath);
      expect(
        await streamedFileSha256(local),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      await store.put(managed);

      var reconciled = await store.reconcile('edit-1');
      expect(reconciled!.dirty, isFalse);
      expect(reconciled.missing, isFalse);

      await local.writeAsString('changed by editor');
      reconciled = await store.reconcile('edit-1');
      expect(reconciled!.dirty, isTrue);
      expect(reconciled.missing, isFalse);

      final accepted = await store.updateBaseline('edit-1');
      expect(accepted!.dirty, isFalse);
      expect(accepted.baselineSha256, await streamedFileSha256(local));

      await local.delete();
      reconciled = await store.reconcile('edit-1');
      expect(reconciled!.dirty, isFalse);
      expect(reconciled.missing, isTrue);

      final restarted = ManagedRemoteFileStore(
        indexFile: indexFile,
        checkoutRoot: checkoutRoot,
      );
      final loaded = (await restarted.list()).single;
      expect(loaded.baselineSha256, accepted.baselineSha256);
      expect(loaded.dirty, isFalse);
      expect(loaded.missing, isFalse);
    },
  );

  test('remove deletes its checkout and persists removal', () async {
    final managed = await _createManagedCheckout(
      store,
      id: 'edit-1',
      serverId: 'server-a',
      sessionId: 'session-a',
      content: 'plaintext',
    );
    await store.put(managed);
    final local = store.checkoutFile(managed.localPath);

    expect(await local.exists(), isTrue);
    expect((await store.remove('edit-1'))!.id, 'edit-1');
    expect(await local.exists(), isFalse);
    expect(await store.remove('edit-1'), isNull);

    final restarted = ManagedRemoteFileStore(
      indexFile: indexFile,
      checkoutRoot: checkoutRoot,
    );
    expect(await restarted.list(), isEmpty);
  });

  test(
    'deletion unlinks a checkout symlink without touching its target',
    () async {
      final outside = File('${temporaryDirectory.path}/outside.txt');
      await outside.writeAsString('keep');
      final relative = 'links/file.txt';
      final local = store.checkoutFile(relative);
      await local.parent.create(recursive: true);
      await Link(local.path).create(outside.path);

      await store.deleteCheckout(relative);

      expect(
        await FileSystemEntity.type(local.path, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(await outside.readAsString(), 'keep');
    },
    skip: Platform.isWindows,
  );

  test(
    'creation and deletion refuse to traverse a parent symlink',
    () async {
      final outside = Directory('${temporaryDirectory.path}/outside')
        ..createSync();
      final victim = File('${outside.path}/victim.txt');
      await victim.writeAsString('keep');
      await store.list();
      await checkoutRoot.create(recursive: true);
      await Link('${checkoutRoot.path}/redirect').create(outside.path);

      await expectLater(
        store.createCheckout('redirect/new.txt'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        store.deleteCheckout('redirect/victim.txt'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await victim.readAsString(), 'keep');
      expect(await File('${outside.path}/new.txt').exists(), isFalse);
    },
    skip: Platform.isWindows,
  );
}

Future<ManagedRemoteFile> _createManagedCheckout(
  ManagedRemoteFileStore store, {
  required String id,
  required String serverId,
  required String sessionId,
  required String content,
}) async {
  final localPath = store.checkoutPathFor(id: id, fileName: '$id.txt');
  final local = await store.createCheckout(localPath);
  await local.writeAsString(content);
  return _managedFile(
    id: id,
    serverId: serverId,
    sessionId: sessionId,
    localPath: localPath,
    baselineSha256: await streamedFileSha256(local),
  );
}

ManagedRemoteFile _managedFile({
  required String id,
  required String localPath,
  String serverId = 'server-a',
  String sessionId = 'session-a',
  String baselineSha256 =
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  bool dirty = false,
}) => ManagedRemoteFile(
  id: id,
  serverId: serverId,
  editSessionId: sessionId,
  remotePath: '/home/test/file.txt',
  localPath: localPath,
  remoteSnapshot: _snapshot('/home/test/file.txt'),
  baselineSha256: baselineSha256,
  dirty: dirty,
);

RemoteFileEntry _snapshot(String path) => RemoteFileEntry(
  path: path,
  name: path.split('/').last,
  type: RemoteFileType.file,
  size: 3,
  modifiedAt: DateTime.utc(2026, 7, 10, 12, 30),
  mode: 0x81a4,
);
