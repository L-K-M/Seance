import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/remote_files_controller.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  test('initializes at home and sorts directories before files', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
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

  test('records upload progress and refreshes the directory', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
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
    );
    await controller.initialize();
    final entry = controller.entries.singleWhere(
      (item) => item.name == 'a.txt',
    );
    controller.trackLocalCopy(entry, '/tmp/managed-copy');

    final detached = controller.takeLocalCopies();
    controller.dispose();

    expect(detached.keys, [entry.path]);
    expect(detached[entry.path]!.localPath, '/tmp/managed-copy');
    shellDirectory.dispose();
  });

  test('directory rename migrates managed copies below it', () async {
    final remote = _FakeRemoteFileSystem();
    final shellDirectory = ValueNotifier<String?>(null);
    final controller = RemoteFilesController(
      () async => remote,
      shellDirectory: shellDirectory,
    );
    await controller.initialize();
    final folder = controller.entries.singleWhere((item) => item.isDirectory);
    const child = RemoteFileEntry(
      path: '/home/test/folder/child.txt',
      name: 'child.txt',
      type: RemoteFileType.file,
      size: 4,
    );
    controller.trackLocalCopy(child, '/tmp/child-copy');

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
    );
    await controller.initialize();
    final entry = controller.entries.singleWhere(
      (item) => item.name == 'a.txt',
    );
    final directory = await Directory.systemTemp.createTemp(
      'seance-edit-test-',
    );
    final local = File('${directory.path}/a.txt');
    await local.writeAsBytes([4, 5, 6]);
    controller.trackLocalCopy(entry, local.path);

    await controller.uploadLocalCopy(controller.localCopies[entry.path]!);

    expect(remote.expectedUploadTarget, same(entry));
    await controller.removeLocalCopy(entry.path);
    controller.dispose();
    shellDirectory.dispose();
  });
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
  };
  final Map<String, List<int>> uploaded = {};
  RemoteFileEntry? expectedUploadTarget;

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
    return RemoteFileEntry(
      path: path,
      name: remoteBasename(path),
      type: RemoteFileType.file,
      size: 3,
    );
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
