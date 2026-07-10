import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/managed_remote_file_store.dart';
import 'package:seance_app/services/remote_files_controller.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  test('initializes at home and sorts directories before files', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
      managedFileStore: _store(),
      serverId: 'server',
      editSessionId: 'session',
    );

    await controller.initialize();

    expect(controller.homePath, '/home/test');
    expect(controller.currentPath, '/home/test');
    expect(controller.entries.map((entry) => entry.name), ['folder', 'a.txt']);
    expect(controller.initialized, isTrue);
    expect(controller.error, isNull);

    controller.dispose();
    shellDirectory.dispose();
  });

  test('follows absolute OSC directory metadata when enabled', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
      managedFileStore: _store(),
      serverId: 'server',
      editSessionId: 'session',
    );
    await controller.initialize();

    shellDirectory.value = '/var/log';
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.currentPath, '/var/log');
    expect(controller.entries.single.name, 'system.log');

    controller.setFollowTerminal(false);
    shellDirectory.value = '/home/test';
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentPath, '/var/log');

    controller.dispose();
    shellDirectory.dispose();
  });

  test('falls back to a common Bash cwd title when OSC 7 is absent', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final terminalTitle = ValueNotifier<String?>('root@server: ~/docker');
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
      terminalTitle: terminalTitle,
      managedFileStore: _store(),
      serverId: 'server',
      editSessionId: 'session',
    );

    await controller.initialize();
    expect(controller.currentPath, '/home/test/docker');

    terminalTitle.value = 'root@server: /var/log';
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentPath, '/var/log');

    shellDirectory.value = '/home/test';
    terminalTitle.value = 'root@server: /var/log';
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentPath, '/home/test', reason: 'OSC 7 must win');

    controller.dispose();
    shellDirectory.dispose();
    terminalTitle.dispose();
  });

  test('records upload progress and refreshes the directory', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
      managedFileStore: _store(),
      serverId: 'server',
      editSessionId: 'session',
    );
    await controller.initialize();

    await controller.upload(
      name: 'new.txt',
      content: Stream.value([1, 2, 3]),
      length: 3,
    );

    expect(remote.uploaded['/home/test/new.txt'], [1, 2, 3]);
    expect(controller.entries.map((entry) => entry.name), [
      'folder',
      'a.txt',
      'new.txt',
    ]);
    expect(controller.transfers.single.status, RemoteTransferStatus.completed);
    expect(controller.transfers.single.transferred, 3);

    controller.dispose();
    shellDirectory.dispose();
  });

  test('managed copies detach for reconnect without being discarded', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
      managedFileStore: _store(),
      serverId: 'server',
      editSessionId: 'session',
    );
    await controller.initialize();
    final entry = controller.entries.singleWhere(
      (item) => item.name == 'a.txt',
    );
    await controller.checkoutRemoteFile(entry);

    final detached = controller.takeLocalCopies();
    controller.dispose();

    expect(detached.keys, [entry.path]);
    expect(detached[entry.path]!.localPath, isNotEmpty);
    shellDirectory.dispose();
  });

  test('directory rename migrates managed copies below it', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
      managedFileStore: _store(),
      serverId: 'server',
      editSessionId: 'session',
    );
    await controller.initialize();
    final folder = controller.entries.singleWhere((item) => item.isDirectory);
    const child = RemoteFileEntry(
      path: '/home/test/folder/child.txt',
      name: 'child.txt',
      type: RemoteFileType.file,
      size: 4,
    );
    await controller.checkoutRemoteFile(child);

    await controller.renameEntry(folder, 'renamed');

    expect(controller.localCopies, contains('/home/test/renamed/child.txt'));
    expect(
      controller.localCopies,
      isNot(contains('/home/test/folder/child.txt')),
    );
    controller.takeLocalCopies();
    controller.dispose();
    shellDirectory.dispose();
  });

  test('managed upload guards the snapshot through the transfer', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
      managedFileStore: _store(),
      serverId: 'server',
      editSessionId: 'session',
    );
    await controller.initialize();
    final entry = controller.entries.singleWhere(
      (item) => item.name == 'a.txt',
    );
    final copy = await controller.checkoutRemoteFile(entry);
    await controller.localFile(copy).writeAsBytes([4, 5, 6]);

    await controller.uploadLocalCopy(controller.localCopies[entry.path]!);

    expect(remote.expectedUploadTarget, same(entry));
    await controller.removeLocalCopy(entry.path);
    controller.dispose();
    shellDirectory.dispose();
  });

  test(
    'a save during upload remains dirty and is not silently accepted',
    () async {
      final remote = _FakeRemoteFileSystem();
      final shellDirectory = ValueNotifier<String?>(null);
      final controller = RemoteFilesController(
        () async => remote,
        shellDirectory: shellDirectory,
        managedFileStore: _store(),
        serverId: 'server',
        editSessionId: 'session',
      );
      await controller.initialize();
      final entry = controller.entries.singleWhere(
        (item) => item.name == 'a.txt',
      );
      final copy = await controller.checkoutRemoteFile(entry);
      final local = controller.localFile(copy);
      await local.writeAsBytes([4, 5, 6]);
      remote.duringUpload = () => local.writeAsBytes([7, 8, 9]);

      await controller.uploadLocalCopy(copy);

      expect(remote.uploaded[entry.path], [4, 5, 6]);
      expect(controller.localCopies[entry.path]!.dirty, isTrue);
      controller.dispose();
      shellDirectory.dispose();
    },
  );

  test('concurrent opens share one durable checkout', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final store = _store();
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
      managedFileStore: store,
      serverId: 'server',
      editSessionId: 'session',
    );
    await controller.initialize();
    final entry = controller.entries.singleWhere(
      (item) => item.name == 'a.txt',
    );

    final copies = await Future.wait([
      controller.checkoutRemoteFile(entry),
      controller.checkoutRemoteFile(entry),
    ]);

    expect(copies[0].id, copies[1].id);
    expect(await store.listForSession('session'), hasLength(1));
    controller.dispose();
    shellDirectory.dispose();
  });

  test(
    'filters, sorts, selects, hides dotfiles, and saves bookmarks',
    () async {
      final remote = _FakeRemoteFileSystem();
      remote.directories['/home/test']!.add(
        const RemoteFileEntry(
          path: '/home/test/.secret',
          name: '.secret',
          type: RemoteFileType.file,
          size: 1,
        ),
      );
      final shellDirectory = ValueNotifier<String?>(null);
      List<String>? savedBookmarks;
      final controller = RemoteFilesController(
        () async => remote,
        shellDirectory: shellDirectory,
        managedFileStore: _store(),
        serverId: 'server',
        editSessionId: 'session',
        saveBookmarks: (paths) async => savedBookmarks = paths,
      );
      await controller.initialize();

      controller.setShowHidden(false);
      expect(controller.entries.map((entry) => entry.name), [
        'folder',
        'a.txt',
      ]);
      controller.setFilterQuery('A.');
      expect(controller.entries.single.name, 'a.txt');
      controller.setFilterQuery('');
      controller.setSort(RemoteSortField.size, RemoteSortDirection.descending);
      expect(controller.entries.map((entry) => entry.name), [
        'folder',
        'a.txt',
      ]);

      controller.toggleSelection('/home/test/a.txt');
      expect(controller.selectedEntries.single.name, 'a.txt');
      await controller.toggleCurrentBookmark();
      expect(savedBookmarks, ['/home/test']);

      controller.dispose();
      shellDirectory.dispose();
    },
  );

  test(
    'recursively uploads and downloads directories with aggregate transfer',
    () async {
      final remote = _FakeRemoteFileSystem();
      remote.directories['/home/test/folder'] = [
        const RemoteFileEntry(
          path: '/home/test/folder/child.txt',
          name: 'child.txt',
          type: RemoteFileType.file,
          size: 3,
        ),
      ];
      final shellDirectory = ValueNotifier<String?>(null);
      final controller = RemoteFilesController(
        () async => remote,
        shellDirectory: shellDirectory,
        managedFileStore: _store(),
        serverId: 'server',
        editSessionId: 'session',
      );
      await controller.initialize();
      final localRoot = await Directory.systemTemp.createTemp('seance-tree-');
      addTearDown(() async {
        if (await localRoot.exists()) await localRoot.delete(recursive: true);
      });
      final source = Directory('${localRoot.path}/source');
      await Directory('${source.path}/nested').create(recursive: true);
      await File('${source.path}/root.txt').writeAsBytes([1, 2]);
      await File('${source.path}/nested/child.txt').writeAsBytes([3, 4, 5]);

      await controller.uploadDirectory(source);
      expect(remote.uploaded['/home/test/source/root.txt'], [1, 2]);
      expect(remote.uploaded['/home/test/source/nested/child.txt'], [3, 4, 5]);
      expect(controller.transfers.last.transferred, 5);

      final destination = Directory('${localRoot.path}/downloads');
      final folder = remote.directories['/home/test']!.singleWhere(
        (entry) => entry.name == 'folder',
      );
      await controller.downloadEntries([folder], destination);
      expect(await File('${destination.path}/folder/child.txt').readAsBytes(), [
        1,
        2,
        3,
      ]);

      controller.dispose();
      shellDirectory.dispose();
    },
  );
}

ManagedRemoteFileStore _store() {
  final directory = Directory.systemTemp.createTempSync('seance-files-test-');
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return ManagedRemoteFileStore(
    indexFile: File('${directory.path}/index.json'),
    checkoutRoot: Directory('${directory.path}/checkouts'),
  );
}

class _FakeRemoteFileSystem implements RemoteFileSystem {
  final Map<String, List<RemoteFileEntry>> directories = {
    '/home/test': [
      const RemoteFileEntry(
        path: '/home/test/a.txt',
        name: 'a.txt',
        type: RemoteFileType.file,
        size: 10,
      ),
      const RemoteFileEntry(
        path: '/home/test/folder',
        name: 'folder',
        type: RemoteFileType.directory,
      ),
    ],
    '/var/log': [
      const RemoteFileEntry(
        path: '/var/log/system.log',
        name: 'system.log',
        type: RemoteFileType.file,
        size: 20,
      ),
    ],
    '/home/test/docker': [],
  };
  final Map<String, List<int>> uploaded = {};
  RemoteFileEntry? expectedUploadTarget;
  Future<void> Function()? duringUpload;

  @override
  Future<void> setMode(String path, int permissions) async {}

  @override
  Future<String> readSymbolicLink(String path) async => 'target';

  @override
  Future<void> createSymbolicLink(String linkPath, String targetPath) async {}

  @override
  Future<String> canonicalize(String path) async =>
      path == '.' ? '/home/test' : path;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async =>
      List.of(directories[path] ?? const []);

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    for (final entries in directories.values) {
      for (final entry in entries) {
        if (entry.path == path) return entry;
      }
    }
    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'inspect',
      path: path,
      message: 'Not found',
    );
  }

  @override
  Future<void> createDirectory(String path) async {
    final parent = remoteParent(path);
    directories
        .putIfAbsent(parent, () => [])
        .add(
          RemoteFileEntry(
            path: path,
            name: remoteBasename(path),
            type: RemoteFileType.directory,
          ),
        );
    directories[path] = [];
  }

  @override
  Future<void> delete(RemoteFileEntry entry) async {
    directories[remoteParent(entry.path)]?.removeWhere(
      (candidate) => candidate.path == entry.path,
    );
  }

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    destination.add([1, 2, 3]);
    onProgress?.call(3, 3);
    try {
      return await stat(path, followLinks: false);
    } on RemoteFileException {
      return RemoteFileEntry(
        path: path,
        name: remoteBasename(path),
        type: RemoteFileType.file,
        size: 3,
      );
    }
  }

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) async {
    final entries = directories[remoteParent(oldPath)] ?? [];
    final index = entries.indexWhere((entry) => entry.path == oldPath);
    if (index < 0) return;
    final old = entries[index];
    entries[index] = RemoteFileEntry(
      path: newPath,
      name: remoteBasename(newPath),
      type: old.type,
      size: old.size,
      modifiedAt: old.modifiedAt,
      mode: old.mode,
    );
  }

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
  }) async {
    expectedUploadTarget = expectedTarget;
    final bytes = <int>[];
    await for (final chunk in content) {
      cancellation?.throwIfCancelled();
      bytes.addAll(chunk);
      onProgress?.call(bytes.length, length);
    }
    await duringUpload?.call();
    uploaded[path] = bytes;
    final entry = RemoteFileEntry(
      path: path,
      name: remoteBasename(path),
      type: RemoteFileType.file,
      size: bytes.length,
      mode: preserveMode,
    );
    final entries = directories.putIfAbsent(remoteParent(path), () => []);
    entries.removeWhere((candidate) => candidate.path == path);
    entries.add(entry);
    return entry;
  }
}
