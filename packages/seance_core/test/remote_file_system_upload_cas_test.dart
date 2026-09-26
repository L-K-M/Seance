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
/// preflights. The replace-safety group covers what an overwrite may
/// replace and which modes the staged file gets.
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

  group('DartSshRemoteFileSystem upload replace safety', () {
    // Full lstat modes: file-type field plus permission bits.
    const symlinkMode = 0xA1FF; // S_IFLNK | 0777
    const fifoMode = 0x11A4; // S_IFIFO | 0644
    const directoryMode = 0x41ED; // S_IFDIR | 0755
    const setuidExecutableMode = 0x89ED; // S_IFREG | 04755
    const privateFileMode = 0x81A0; // S_IFREG | 0640
    const ownerOnlyStagingMode = 0x8180; // S_IFREG | 0600

    final cases = [
      (
        name: 'a symbolic link',
        mode: symlinkMode,
        passLstatAsExpectedTarget: false,
        message:
            '"report.txt" is a symbolic link; replacing it would '
            'replace the link, not its target.',
      ),
      // The folder upload hands over the lstat entry it just read, which
      // the link's own snapshot matches.
      (
        name: 'a symbolic link matching expectedTarget',
        mode: symlinkMode,
        passLstatAsExpectedTarget: true,
        message:
            '"report.txt" is a symbolic link; replacing it would '
            'replace the link, not its target.',
      ),
      (
        name: 'a FIFO',
        mode: fifoMode,
        passLstatAsExpectedTarget: false,
        message:
            '"report.txt" is not reported as a regular file, so the '
            'upload will not replace it.',
      ),
    ];
    for (final testCase in cases) {
      test('refuses to replace ${testCase.name}', () async {
        final client = _PathAwareSftpClient();
        client.putSpecial(
          targetPath,
          mode: testCase.mode,
          modifyTime: firstModifySecond,
        );
        final fileSystem = DartSshRemoteFileSystem(client);
        final expectedTarget = testCase.passLstatAsExpectedTarget
            ? await fileSystem.stat(targetPath, followLinks: false)
            : null;

        await expectLater(
          fileSystem.upload(
            targetPath,
            Stream.value(Uint8List.fromList([7, 8, 9])),
            length: 3,
            overwrite: true,
            expectedTarget: expectedTarget,
          ),
          throwsA(
            conflictUpload.having(
              (error) => error.message,
              'message',
              testCase.message,
            ),
          ),
        );

        expect(client.writeOpens, isEmpty);
        expect(client.readOpens, isEmpty);
        expect(client.modeSetStats, isEmpty);
        expect(client.renames, isEmpty);
        expect(client.hasTemporaryUpload(), isFalse);
        expect(client.modeOf(targetPath), testCase.mode);
      });
    }

    test(
      'refuses a symbolic link that replaced the target mid-upload',
      () async {
        final client = _PathAwareSftpClient();
        client.putFile(targetPath, [1, 2, 3], modifyTime: firstModifySecond);
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
          overwrite: true,
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
        client.putSpecial(
          targetPath,
          mode: symlinkMode,
          modifyTime: laterModifySecond,
        );
        await content.close();

        await expectLater(upload, throwsA(conflictUpload));
        expect(client.renames, isEmpty);
        expect(client.modeOf(targetPath), symlinkMode);
        expect(client.hasTemporaryUpload(), isFalse);
        expect(client.removes.single, matches(tempPathPattern));
      },
    );

    test('does not give a file the mode of a directory', () async {
      final client = _PathAwareSftpClient();
      client.putSpecial(
        targetPath,
        mode: directoryMode,
        modifyTime: firstModifySecond,
      );
      final fileSystem = DartSshRemoteFileSystem(client);

      // Refused up front, not after a transfer the rename would fail.
      await expectLater(
        fileSystem.upload(
          targetPath,
          Stream.value(Uint8List.fromList([7, 8, 9])),
          length: 3,
          overwrite: true,
        ),
        throwsA(
          isA<RemoteFileException>()
              .having((e) => e.kind, 'kind', RemoteFileErrorKind.conflict)
              .having((e) => e.message, 'message', contains('is a folder')),
        ),
      );

      expect(client.renames, isEmpty);
      expect(client.modeSetStats, isEmpty);
      expect(client.modeHandleSetStats, isEmpty);
      expect(client.modeOf(targetPath), directoryMode);
      expect(client.hasTemporaryUpload(), isFalse);
    });

    test('keeps only the permission bits of a replaced file', () async {
      final client = _PathAwareSftpClient();
      client.putFile(
        targetPath,
        [1, 2, 3],
        modifyTime: firstModifySecond,
        mode: setuidExecutableMode,
      );
      final fileSystem = DartSshRemoteFileSystem(client);

      await fileSystem.upload(
        targetPath,
        Stream.value(Uint8List.fromList([5, 6])),
        length: 2,
        overwrite: true,
      );

      // The file-type field never goes over the wire; setuid, setgid and
      // sticky are permission bits and stay.
      expect(client.modeSetStats, hasLength(1));
      expect(client.modeSetStats.single.$1, matches(tempPathPattern));
      expect(client.modeSetStats.single.$2, setuidExecutableMode & 0xFFF);
      // Group and others may not write the result, so the temp is staged
      // owner-only rather than at a server default that might let them.
      expect(client.modeHandleSetStats.single.$2, ownerOnlyStagingMode & 0xFFF);
      expect(client.modeOf(targetPath), setuidExecutableMode);
    });

    test('skips staging when the final mode hides nothing', () async {
      final client = _PathAwareSftpClient();
      final fileSystem = DartSshRemoteFileSystem(client);

      await fileSystem.upload(
        targetPath,
        Stream.value(Uint8List.fromList([5, 6])),
        length: 2,
        preserveMode: 0x81B6, // S_IFREG | 0666
      );

      // Group and others may read and write the result, so no default the
      // server picks is more permissive: no extra request.
      expect(client.modeHandleSetStats, isEmpty);
      expect(client.modeSetStats.single.$2, 0x1B6);
    });

    test('masks the file-type bits of an explicit preserveMode', () async {
      final client = _PathAwareSftpClient();
      final fileSystem = DartSshRemoteFileSystem(client);

      await fileSystem.upload(
        targetPath,
        Stream.value(Uint8List.fromList([5, 6])),
        length: 2,
        preserveMode: regularFileMode,
      );

      expect(client.modeSetStats.single.$2, regularFileMode & 0xFFF);
      expect(client.modeOf(targetPath), regularFileMode);
    });

    test('stages a private file owner-only before the first byte', () async {
      final client = _PathAwareSftpClient();
      client.putFile(
        targetPath,
        [1, 2, 3],
        modifyTime: firstModifySecond,
        mode: privateFileMode,
      );
      final fileSystem = DartSshRemoteFileSystem(client);
      int? modeAtFirstWrite;
      client.onWrite = (path) => modeAtFirstWrite ??= client.modeOf(path);

      await fileSystem.upload(
        targetPath,
        Stream.value(Uint8List.fromList([5, 6])),
        length: 2,
        overwrite: true,
      );

      expect(modeAtFirstWrite, ownerOnlyStagingMode);
      expect(client.modeHandleSetStats.single.$2, ownerOnlyStagingMode & 0xFFF);
      expect(client.modeSetStats.single.$2, privateFileMode & 0xFFF);
      expect(client.modeOf(targetPath), privateFileMode);
    });

    test('stages an explicitly private new file owner-only', () async {
      final client = _PathAwareSftpClient();
      final fileSystem = DartSshRemoteFileSystem(client);
      int? modeAtFirstWrite;
      client.onWrite = (path) => modeAtFirstWrite ??= client.modeOf(path);

      await fileSystem.upload(
        targetPath,
        Stream.value(Uint8List.fromList([5, 6])),
        length: 2,
        preserveMode: privateFileMode,
      );

      expect(modeAtFirstWrite, ownerOnlyStagingMode);
      expect(client.modeSetStats.single.$2, privateFileMode & 0xFFF);
      expect(client.modeOf(targetPath), privateFileMode);
    });

    test('leaves a new file at the server default mode', () async {
      final client = _PathAwareSftpClient();
      final fileSystem = DartSshRemoteFileSystem(client);

      await fileSystem.upload(
        targetPath,
        Stream.value(Uint8List.fromList([5, 6])),
        length: 2,
      );

      expect(client.modeSetStats, isEmpty);
      expect(client.modeHandleSetStats, isEmpty);
      expect(client.modeOf(targetPath), regularFileMode);
    });
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

  /// Raw mode values sent through path setstat, as (path, mode) — what
  /// went over the wire, before the server's own permission mask.
  final List<(String, int)> modeSetStats = [];

  /// Raw mode values sent through handle setstat (fsetstat), as
  /// (path, mode).
  final List<(String, int)> modeHandleSetStats = [];

  /// Invoked after each write-mode byte write lands. Tests gate on the
  /// first call to know staging has begun; no timing sleeps anywhere.
  void Function(String path)? onWrite;

  void putFile(
    String path,
    List<int> bytes, {
    required int modifyTime,
    int mode = _regularMode,
  }) {
    _files[path] = _StoredFile(List.of(bytes), modifyTime, mode);
  }

  /// A non-regular node. [stat] models lstat, which is all the upload
  /// path asks for, so the node itself is reported rather than a target.
  void putSpecial(String path, {required int mode, required int modifyTime}) {
    _files[path] = _StoredFile([], modifyTime, mode);
  }

  int modeOf(String path) => _files[path]!.mode;

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
    // Created with the server's default mode (umask 022), as dartssh2
    // sends no attributes with the open request.
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
    if (attrs.mode case final mode?) {
      modeSetStats.add((path, mode.value));
      _chmod(stored, mode.value);
    }
    if (attrs.modifyTime != null) stored.modifyTime = attrs.modifyTime!;
  }

  void _handleSetStat(String path, _StoredFile stored, SftpFileAttrs attrs) {
    if (attrs.mode case final mode?) {
      modeHandleSetStats.add((path, mode.value));
      _chmod(stored, mode.value);
    }
  }

  /// OpenSSH's sftp-server applies `perm & 07777`: setstat never changes
  /// the file type, whatever the client sends.
  static void _chmod(_StoredFile stored, int mode) {
    stored.mode = (stored.mode & ~_permissionBits) | (mode & _permissionBits);
  }

  static const int _permissionBits = 0xFFF;
  static const int _fileTypeBits = 0xF000;
  static const int _directoryType = 0x4000;

  @override
  Future<void> rename(String oldPath, String newPath) async {
    // Models dartssh2's client-side rename: it prefers the
    // posix-rename@openssh.com extension (atomic, replaces an existing
    // destination), which the adapter's commit relies on. Bare
    // SSH_FXP_RENAME would refuse an existing [newPath]; modeling that
    // extension-less server would sit below this API's negotiation.
    // rename(2) still refuses a file over a directory (EISDIR).
    if (_files[newPath] case final target?
        when target.mode & _fileTypeBits == _directoryType) {
      throw SftpStatusError(SftpStatusCode.failure, 'is a directory');
    }
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
  _FakeWritableSftpFile(this._owner, this.path, this.stored, this._onWrite)
    : super(_owner, Uint8List(0));

  final _PathAwareSftpClient _owner;
  final String path;
  final _StoredFile stored;
  final void Function(String path)? _onWrite;

  @override
  Future<void> setStat(SftpFileAttrs attrs) async =>
      _owner._handleSetStat(path, stored, attrs);

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
