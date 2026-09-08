import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:seance_core/seance_core.dart';
import 'package:seance_core/src/ssh/remote_file_system.dart'
    show DartSshRemoteFileSystem;
import 'package:test/test.dart';

/// Upload conflict guards with the inline digest off (`computeHash: false`):
/// the preflight snapshot checks and the expectedTarget content hash
/// (compare-and-swap) must keep working when the outgoing stream is not
/// hashed. Everything runs through the real adapter over a path-aware
/// in-memory SFTP fake — no sockets, no timing sleeps. Tests that mutate the
/// target mid-upload gate on the first staged write and hold the content
/// stream open, so the mutation always lands strictly between the two
/// preflights.
/// Matches the adapter's exclusive sibling temp files in /srv, so tests
/// and the fake's helpers share one statement of the staging layout.
final tempPathPattern = RegExp(
  '^${RegExp.escape('/srv/')}'
  r'\.seance-upload-[0-9a-f]{8}\.tmp$',
);

void main() {
  const targetPath = '/srv/report.txt';
  const regularFileMode = 0x81A4;

  // Distinct whole-second mtimes, the granularity SFTP v3 reports.
  const firstModifySecond = 1700000100;
  const laterModifySecond = 1700000200;

  final conflictUpload = isA<RemoteFileException>()
      .having((error) => error.kind, 'kind', RemoteFileErrorKind.conflict)
      .having((error) => error.operation, 'operation', 'upload');

  DateTime seconds(int value) =>
      DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);

  // Fail fast and pointed when a regression stops the upload before any
  // byte lands, instead of hanging until the suite's 30 s timeout.
  const stagingTimeout = Duration(seconds: 5);
  const stagingTimeoutMessage =
      'upload never staged bytes - check the first preflight';

  group('DartSshRemoteFileSystem upload CAS with hashing off', () {
    test('rejects a stale expectedTarget before staging anything', () async {
      final client = _PathAwareSftpClient();
      client.putFile(targetPath, [1, 2, 3], modifyTime: firstModifySecond);
      final fileSystem = DartSshRemoteFileSystem(client);

      final stale = RemoteFileEntry(
        path: targetPath,
        name: 'report.txt',
        type: RemoteFileType.file,
        size: 3,
        modifiedAt: seconds(laterModifySecond),
        mode: regularFileMode,
      );

      await expectLater(
        fileSystem.upload(
          targetPath,
          Stream.value(Uint8List.fromList([7, 8, 9])),
          length: 3,
          overwrite: true,
          expectedTarget: stale,
          computeHash: false,
        ),
        throwsA(conflictUpload),
      );

      expect(client.writeOpens, isEmpty);
      expect(client.readOpens, isEmpty);
      expect(client.renames, isEmpty);
      expect(client.contentOf(targetPath), [1, 2, 3]);
    });

    test('rejects a target that changed while bytes were staged', () async {
      final client = _PathAwareSftpClient();
      client.putFile(targetPath, [1, 2, 3], modifyTime: firstModifySecond);
      final fileSystem = DartSshRemoteFileSystem(client);
      final expected = client.expectedTarget(targetPath);

      final staged = Completer<void>();
      client.onWrite = (_) {
        if (!staged.isCompleted) staged.complete();
      };
      final content = StreamController<List<int>>();
      final upload = fileSystem.upload(
        targetPath,
        content.stream,
        length: 5,
        overwrite: true,
        expectedTarget: expected,
        computeHash: false,
      );

      content.add([9, 9, 9, 9, 9]);
      await staged.future.timeout(
        stagingTimeout,
        onTimeout: () {
          unawaited(content.close());
          upload.ignore();
          throw StateError(stagingTimeoutMessage);
        },
      );
      // An external writer replaces the target mid-staging.
      client.putFile(targetPath, [4, 5, 6, 7], modifyTime: laterModifySecond);
      await content.close();

      await expectLater(upload, throwsA(conflictUpload));
      expect(client.renames, isEmpty);
      expect(client.contentOf(targetPath), [4, 5, 6, 7]);
      expect(client.hasTemporaryUpload(), isFalse);
      expect(client.removes, hasLength(1));
      expect(client.removes.single, matches(tempPathPattern));
    });

    test('rejects a target that disappeared while bytes were staged', () async {
      final client = _PathAwareSftpClient();
      client.putFile(targetPath, [1, 2, 3], modifyTime: firstModifySecond);
      final fileSystem = DartSshRemoteFileSystem(client);
      final expected = client.expectedTarget(targetPath);

      final staged = Completer<void>();
      client.onWrite = (_) {
        if (!staged.isCompleted) staged.complete();
      };
      final content = StreamController<List<int>>();
      final upload = fileSystem.upload(
        targetPath,
        content.stream,
        length: 3,
        overwrite: true,
        expectedTarget: expected,
        computeHash: false,
      );

      content.add([7, 8, 9]);
      await staged.future.timeout(
        stagingTimeout,
        onTimeout: () {
          unawaited(content.close());
          upload.ignore();
          throw StateError(stagingTimeoutMessage);
        },
      );
      // An external writer removes the target mid-staging.
      client.deletePath(targetPath);
      await content.close();

      await expectLater(upload, throwsA(conflictUpload));
      expect(client.renames, isEmpty);
      expect(client.paths, isEmpty);
      expect(client.removes, hasLength(1));
      expect(client.removes.single, matches(tempPathPattern));
    });

    test(
      'preserves a destination that appears during a plain upload',
      () async {
        final client = _PathAwareSftpClient();
        final fileSystem = DartSshRemoteFileSystem(client);

        final staged = Completer<void>();
        client.onWrite = (_) {
          if (!staged.isCompleted) staged.complete();
        };
        final content = StreamController<List<int>>();
        final upload = fileSystem.upload(
          targetPath,
          content.stream,
          length: 3,
          computeHash: false,
        );

        content.add([1, 2, 3]);
        await staged.future.timeout(
          stagingTimeout,
          onTimeout: () {
            unawaited(content.close());
            upload.ignore();
            throw StateError(stagingTimeoutMessage);
          },
        );
        // An external writer creates the destination mid-staging; the
        // non-overwrite upload must refuse to replace it.
        client.putFile(targetPath, [7, 7], modifyTime: firstModifySecond);
        await content.close();

        await expectLater(upload, throwsA(conflictUpload));
        expect(client.renames, isEmpty);
        expect(client.contentOf(targetPath), [7, 7]);
        expect(client.hasTemporaryUpload(), isFalse);
        expect(client.removes, hasLength(1));
        expect(client.removes.single, matches(tempPathPattern));
      },
    );

    test(
      'still hashes the target when the upload skips its own digest',
      () async {
        final client = _PathAwareSftpClient();
        client.putFile(targetPath, [1, 2, 3, 4], modifyTime: firstModifySecond);
        final fileSystem = DartSshRemoteFileSystem(client);

        // Snapshot-identical to the server state, but the digest is of
        // different bytes: only the CAS content hash can catch this.
        final sameMetadataDifferentBytes = RemoteFileEntry(
          path: targetPath,
          name: 'report.txt',
          type: RemoteFileType.file,
          size: 4,
          modifiedAt: seconds(firstModifySecond),
          mode: regularFileMode,
          contentSha256: sha256.convert([9, 9, 9, 9]).toString(),
        );

        await expectLater(
          fileSystem.upload(
            targetPath,
            Stream.value(Uint8List.fromList([5, 6, 7, 8])),
            length: 4,
            overwrite: true,
            expectedTarget: sameMetadataDifferentBytes,
            computeHash: false,
          ),
          throwsA(conflictUpload),
        );

        expect(client.readOpens, [targetPath]);
        expect(client.writeOpens, isEmpty);
        expect(client.renames, isEmpty);
        expect(client.contentOf(targetPath), [1, 2, 3, 4]);
      },
    );

    test(
      'commits over a matching target and returns no inline digest',
      () async {
        final client = _PathAwareSftpClient();
        client.putFile(targetPath, [1, 2, 3], modifyTime: firstModifySecond);
        final fileSystem = DartSshRemoteFileSystem(client);
        final expected = client.expectedTarget(targetPath);

        final entry = await fileSystem.upload(
          targetPath,
          Stream.value(Uint8List.fromList([5, 6])),
          length: 2,
          overwrite: true,
          expectedTarget: expected,
          computeHash: false,
        );

        expect(entry.path, targetPath);
        expect(entry.type, RemoteFileType.file);
        expect(entry.size, 2);
        expect(entry.contentSha256, isNull);
        expect(client.contentOf(targetPath), [5, 6]);
        expect(client.renames, hasLength(1));
        expect(client.renames.single.$2, targetPath);
        expect(client.renames.single.$1, matches(tempPathPattern));
        expect(client.hasTemporaryUpload(), isFalse);
        // The CAS hash read the target at both preflights.
        expect(client.readOpens, [targetPath, targetPath]);
      },
    );
  });
}

/// One in-memory remote file. [modifyTime] is whole seconds, matching what
/// SFTP v3 reports and what snapshot comparisons may see.
class _StoredFile {
  _StoredFile(this.content, this.modifyTime, this.mode);

  List<int> content;
  int modifyTime;
  int mode;
}

/// Path-aware SFTP fake: an in-memory file tree with exclusive-create
/// write opens and observable rename/remove calls, so the upload
/// protocol's preflight and CAS behavior runs without sockets. Only the
/// surface the upload path touches is implemented; anything else throws.
class _PathAwareSftpClient implements SftpClient {
  final Map<String, _StoredFile> _files = {};

  /// Paths opened for writing (the staging temp files), in order.
  final List<String> writeOpens = [];

  /// Paths opened for reading (the CAS digest reads), in order.
  final List<String> readOpens = [];

  /// Recorded (oldPath, newPath) rename calls — the commit path.
  final List<(String, String)> renames = [];

  /// Recorded remove calls — the temporary-file cleanup path.
  final List<String> removes = [];

  /// Invoked after each write-mode byte write lands. Tests gate on the
  /// first call to know staging has begun; no timing sleeps anywhere.
  void Function(String path)? onWrite;

  void putFile(String path, List<int> bytes, {required int modifyTime}) {
    _files[path] = _StoredFile(List.of(bytes), modifyTime, _regularMode);
  }

  void deletePath(String path) {
    _files.remove(path);
  }

  Uint8List contentOf(String path) => Uint8List.fromList(_files[path]!.content);

  Iterable<String> get paths => _files.keys;

  bool hasTemporaryUpload() => _files.keys.any(tempPathPattern.hasMatch);

  /// The expectedTarget a caller would hold after previously downloading
  /// [path]: the current snapshot plus its content digest.
  RemoteFileEntry expectedTarget(String path) {
    final stored = _files[path]!;
    return RemoteFileEntry(
      path: path,
      name: remoteBasename(path),
      type: RemoteFileType.file,
      size: stored.content.length,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        stored.modifyTime * 1000,
        isUtc: true,
      ),
      mode: stored.mode,
      contentSha256: sha256.convert(stored.content).toString(),
    );
  }

  static const int _regularMode = 0x81A4;

  // mtime stamped on a staging temp at creation; nothing compares it.
  static const int _tempModifySecond = 1700000300;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    final stored = _files[path];
    if (stored == null) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'no such file');
    }
    return _attrsOf(stored);
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    if (mode.flag & SftpFileOpenMode.write.flag == 0) {
      readOpens.add(path);
      final stored = _files[path];
      if (stored == null) {
        throw SftpStatusError(SftpStatusCode.noSuchFile, 'no such file');
      }
      return _FakeReadableSftpFile(this, Uint8List.fromList(stored.content));
    }
    writeOpens.add(path);
    if (_files.containsKey(path)) {
      // SSH_FXF_EXCL semantics: a real server refuses an existing path.
      throw SftpStatusError(SftpStatusCode.failure, 'file already exists');
    }
    final stored = _StoredFile([], _tempModifySecond, _regularMode);
    _files[path] = stored;
    return _FakeWritableSftpFile(this, path, stored, onWrite);
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    final stored = _files[path];
    if (stored == null) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'no such file');
    }
    if (attrs.mode != null) stored.mode = attrs.mode!.value;
    if (attrs.modifyTime != null) stored.modifyTime = attrs.modifyTime!;
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    // Models dartssh2's client-side rename: it prefers the
    // posix-rename@openssh.com extension (atomic, replaces an existing
    // destination), which the adapter's commit relies on. Bare
    // SSH_FXP_RENAME would refuse an existing [newPath]; modeling that
    // extension-less server would sit below this API's negotiation.
    final stored = _files.remove(oldPath);
    if (stored == null) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'no such file');
    }
    renames.add((oldPath, newPath));
    _files[newPath] = stored;
  }

  @override
  Future<void> remove(String path) async {
    removes.add(path);
    if (_files.remove(path) == null) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'no such file');
    }
  }

  static SftpFileAttrs _attrsOf(_StoredFile stored) => SftpFileAttrs(
    size: stored.content.length,
    mode: SftpFileMode.value(stored.mode),
    accessTime: stored.modifyTime,
    modifyTime: stored.modifyTime,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeReadableSftpFile extends SftpFile {
  _FakeReadableSftpFile(SftpClient client, this.content)
    : super(client, Uint8List(0));

  final Uint8List content;

  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 1,
    int maxPendingRequests = 1,
  }) async* {
    var end = content.length;
    if (length != null && offset + length < end) end = offset + length;
    if (offset < end) {
      yield Uint8List.sublistView(content, offset, end);
    }
    // Real servers report a short/empty read, never negative progress.
    onProgress?.call(offset < end ? end - offset : 0);
  }

  @override
  Future<void> close() async {}
}

class _FakeWritableSftpFile extends SftpFile {
  _FakeWritableSftpFile(
    SftpClient client,
    this.path,
    this.stored,
    this._onWrite,
  ) : super(client, Uint8List(0));

  final String path;
  final _StoredFile stored;
  final void Function(String path)? _onWrite;

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    // The upload protocol writes sequentially; tolerate gaps and
    // overlapping writes that extend the file, defensively.
    final gap = offset - stored.content.length;
    if (gap > 0) stored.content.addAll(List.filled(gap, 0));
    if (offset == stored.content.length) {
      stored.content.addAll(data);
    } else {
      final end = offset + data.length;
      if (end > stored.content.length) {
        stored.content.addAll(List.filled(end - stored.content.length, 0));
      }
      stored.content.setRange(offset, end, data);
    }
    _onWrite?.call(path);
  }

  @override
  Future<void> close() async {}
}
