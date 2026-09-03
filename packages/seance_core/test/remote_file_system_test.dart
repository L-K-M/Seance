import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:seance_core/seance_core.dart';
import 'package:seance_core/src/ssh/remote_file_system.dart'
    show DartSshRemoteFileSystem;
import 'package:test/test.dart';

void main() {
  group('remote POSIX paths', () {
    test('joins names without damaging root or relative paths', () {
      expect(remoteJoin('/', 'file.txt'), '/file.txt');
      expect(remoteJoin('/srv/www/', 'file.txt'), '/srv/www/file.txt');
      expect(remoteJoin('.', 'file.txt'), 'file.txt');
      expect(remoteJoin('', 'file.txt'), 'file.txt');
    });

    test('finds parent and basename at root and below it', () {
      expect(remoteBasename('/srv/www/file.txt'), 'file.txt');
      expect(remoteBasename('/srv/www/'), 'www');
      expect(remoteParent('/srv/www/file.txt'), '/srv/www');
      expect(remoteParent('/file.txt'), '/');
      expect(remoteParent('/'), '/');
      expect(remoteParent('file.txt'), '.');
    });
  });

  test('transfer cancellation is sticky', () {
    final cancellation = RemoteTransferCancellation();
    expect(cancellation.isCancelled, isFalse);
    cancellation.throwIfCancelled();
    cancellation.cancel();
    expect(cancellation.isCancelled, isTrue);
    expect(cancellation.throwIfCancelled, throwsA(anything));
  });

  test('file entries retain optional POSIX metadata', () {
    final accessedAt = DateTime.utc(2025, 1, 2, 3, 4, 5);
    final modifiedAt = DateTime.utc(2025, 2, 3, 4, 5, 6);
    final entry = RemoteFileEntry(
      path: '/srv/file.txt',
      name: 'file.txt',
      type: RemoteFileType.file,
      size: 42,
      uid: 1000,
      gid: 1001,
      accessedAt: accessedAt,
      modifiedAt: modifiedAt,
      mode: 0x81A4,
    );

    expect(entry.uid, 1000);
    expect(entry.gid, 1001);
    expect(entry.accessedAt, accessedAt);
    expect(entry.modifiedAt, modifiedAt);
    expect(entry.mode, 0x81A4);
  });

  group('DartSshRemoteFileSystem', () {
    test('download cancellation contains late source errors', () async {
      final sourceListened = Completer<void>();
      final source = StreamController<Uint8List>(
        onListen: sourceListened.complete,
        onCancel: () => Future<void>.error(StateError('cancel failed')),
      );
      final attrs = SftpFileAttrs(
        size: 1,
        mode: const SftpFileMode.value(0x81A4),
      );
      final client = _FakeSftpClient(statResult: attrs);
      client.openedFile = _FakeSftpFile(client, attrs, source.stream);
      final fileSystem = DartSshRemoteFileSystem(client);
      final cancellation = RemoteTransferCancellation();
      final transfer = fileSystem.download(
        '/srv/file.txt',
        _DiscardingSink(),
        cancellation: cancellation,
      );
      await sourceListened.future;

      cancellation.cancel();
      await expectLater(
        transfer,
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.cancelled,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    });

    test('hashes downloaded content by default', () async {
      final content = Uint8List.fromList([4, 5, 6]);
      final attrs = SftpFileAttrs(
        size: 3,
        mode: const SftpFileMode.value(0x81A4),
      );
      final client = _FakeSftpClient(statResult: attrs);
      client.openedFile = _FakeSftpFile(client, attrs, Stream.value(content));
      final fileSystem = DartSshRemoteFileSystem(client);

      final entry = await fileSystem.download(
        '/srv/file.txt',
        _DiscardingSink(),
      );

      expect(entry.contentSha256, sha256.convert(content).toString());
    });

    test('skips the download digest when computeHash is false', () async {
      final content = Uint8List.fromList([4, 5, 6]);
      final attrs = SftpFileAttrs(
        size: 3,
        mode: const SftpFileMode.value(0x81A4),
      );
      final client = _FakeSftpClient(statResult: attrs);
      client.openedFile = _FakeSftpFile(client, attrs, Stream.value(content));
      final fileSystem = DartSshRemoteFileSystem(client);

      final entry = await fileSystem.download(
        '/srv/file.txt',
        _DiscardingSink(),
        computeHash: false,
      );

      expect(entry.contentSha256, isNull);
    });

    test('hashes uploaded content by default', () async {
      final client = _FakeSftpClient();
      client.openedFile = _FakeWritableSftpFile(client);
      final fileSystem = DartSshRemoteFileSystem(client);

      final entry = await fileSystem.upload(
        '/srv/file.txt',
        Stream.value(Uint8List.fromList([1, 2, 3])),
        length: 3,
        overwrite: true,
      );

      expect(entry.contentSha256, sha256.convert([1, 2, 3]).toString());
    });

    test('skips the upload digest when computeHash is false', () async {
      final client = _FakeSftpClient();
      client.openedFile = _FakeWritableSftpFile(client);
      final fileSystem = DartSshRemoteFileSystem(client);

      final entry = await fileSystem.upload(
        '/srv/file.txt',
        Stream.value(Uint8List.fromList([1, 2, 3])),
        length: 3,
        overwrite: true,
        computeHash: false,
      );

      expect(entry.contentSha256, isNull);
    });

    test('maps SFTP ownership and timestamps into entries', () async {
      final client = _FakeSftpClient(
        statResult: SftpFileAttrs(
          size: 42,
          userID: 1000,
          groupID: 1001,
          mode: const SftpFileMode.value(0x81A4),
          accessTime: 1700000000,
          modifyTime: 1700000100,
        ),
      );
      final fileSystem = DartSshRemoteFileSystem(client);

      final entry = await fileSystem.stat('/srv/file.txt');

      expect(entry.uid, 1000);
      expect(entry.gid, 1001);
      expect(
        entry.accessedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true),
      );
      expect(
        entry.modifiedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000100 * 1000, isUtc: true),
      );
    });

    test('validates permissions before contacting SFTP', () {
      final client = _FakeSftpClient();
      final fileSystem = DartSshRemoteFileSystem(client);

      expect(() => fileSystem.setMode('/srv/file.txt', -1), throwsRangeError);
      expect(
        () => fileSystem.setMode('/srv/file.txt', 0x1000),
        throwsRangeError,
      );
      expect(client.statCalls, 0);
    });

    test('sets boundary permission values without file-type bits', () async {
      final client = _FakeSftpClient();
      final fileSystem = DartSshRemoteFileSystem(client);

      await fileSystem.setMode('/srv/file.txt', 0);
      expect(client.lastSetStat?.mode?.value, 0);

      await fileSystem.setMode('/srv/file.txt', 0xFFF);
      expect(client.lastSetStat?.mode?.value, 0xFFF);
    });

    test('does not change permissions through a symbolic link', () async {
      final client = _FakeSftpClient(
        statResult: SftpFileAttrs(mode: const SftpFileMode.value(0xA1FF)),
      );
      final fileSystem = DartSshRemoteFileSystem(client);

      await expectLater(
        fileSystem.setMode('/srv/link', 0x1A4),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.unsupported,
          ),
        ),
      );
      expect(client.lastSetStat, isNull);
    });

    group('setTimes', () {
      test('sets both timestamps as whole seconds', () async {
        final client = _FakeSftpClient();
        final fileSystem = DartSshRemoteFileSystem(client);
        final accessedAt = DateTime.utc(2025, 1, 2, 3, 4, 5);
        final modifiedAt = DateTime.utc(2025, 2, 3, 4, 5, 6);

        await fileSystem.setTimes(
          '/srv/file.txt',
          accessedAt: accessedAt,
          modifiedAt: modifiedAt,
        );

        expect(
          client.lastSetStat?.accessTime,
          accessedAt.millisecondsSinceEpoch ~/ 1000,
        );
        expect(
          client.lastSetStat?.modifyTime,
          modifiedAt.millisecondsSinceEpoch ~/ 1000,
        );
      });

      test('fills the unspecified timestamp from the server', () async {
        final client = _FakeSftpClient(
          statResult: SftpFileAttrs(
            mode: const SftpFileMode.value(0x81A4),
            accessTime: 1700000000,
            modifyTime: 1700000100,
          ),
        );
        final fileSystem = DartSshRemoteFileSystem(client);

        await fileSystem.setTimes(
          '/srv/file.txt',
          modifiedAt: DateTime.utc(2025, 2, 3, 4, 5, 6),
        );

        expect(client.lastSetStat?.accessTime, 1700000000);
        expect(
          client.lastSetStat?.modifyTime,
          DateTime.utc(2025, 2, 3, 4, 5, 6).millisecondsSinceEpoch ~/ 1000,
        );

        client.lastSetStat = null;
        await fileSystem.setTimes(
          '/srv/file.txt',
          accessedAt: DateTime.utc(2025, 1, 2, 3, 4, 5),
        );

        expect(
          client.lastSetStat?.accessTime,
          DateTime.utc(2025, 1, 2, 3, 4, 5).millisecondsSinceEpoch ~/ 1000,
        );
        expect(client.lastSetStat?.modifyTime, 1700000100);
      });

      test('floors sub-second precision to whole seconds', () async {
        final client = _FakeSftpClient();
        final fileSystem = DartSshRemoteFileSystem(client);

        await fileSystem.setTimes(
          '/srv/file.txt',
          modifiedAt: DateTime.utc(2025, 1, 2, 3, 4, 5, 900),
          accessedAt: DateTime.utc(2025, 1, 2, 3, 4, 5, 100),
        );

        // SFTP v3 stores whole seconds; a fractional second always rounds
        // down.
        expect(
          client.lastSetStat?.modifyTime,
          DateTime.utc(2025, 1, 2, 3, 4, 5).millisecondsSinceEpoch ~/ 1000,
        );
        expect(
          client.lastSetStat?.accessTime,
          DateTime.utc(2025, 1, 2, 3, 4, 5).millisecondsSinceEpoch ~/ 1000,
        );
      });

      test('rejects timestamps the SFTP wire cannot represent', () async {
        final client = _FakeSftpClient();
        final fileSystem = DartSshRemoteFileSystem(client);

        // SFTP v3 carries timestamps as unsigned 32-bit seconds; anything
        // else would silently wrap into a far-future server-side value.
        expect(
          () => fileSystem.setTimes(
            '/srv/file.txt',
            modifiedAt: DateTime.utc(1969, 12, 31, 23, 59, 59, 999),
          ),
          throwsRangeError,
        );
        expect(
          () => fileSystem.setTimes(
            '/srv/file.txt',
            modifiedAt: DateTime.utc(2106, 2, 7, 6, 28, 16),
          ),
          throwsRangeError,
        );
        expect(client.statCalls, 0);

        // Both boundaries themselves stay representable.
        await fileSystem.setTimes(
          '/srv/file.txt',
          accessedAt: DateTime.utc(1970),
          modifiedAt: DateTime.utc(2106, 2, 7, 6, 28, 15),
        );
        expect(client.lastSetStat?.accessTime, 0);
        expect(client.lastSetStat?.modifyTime, 0xFFFFFFFF);
      });

      test('does not change timestamps through a symbolic link', () async {
        final client = _FakeSftpClient(
          statResult: SftpFileAttrs(mode: const SftpFileMode.value(0xA1FF)),
        );
        final fileSystem = DartSshRemoteFileSystem(client);

        await expectLater(
          fileSystem.setTimes('/srv/link', modifiedAt: DateTime.utc(2025)),
          throwsA(
            isA<RemoteFileException>().having(
              (error) => error.kind,
              'kind',
              RemoteFileErrorKind.unsupported,
            ),
          ),
        );
        expect(client.lastSetStat, isNull);
      });

      test('rejects a setTimes call without any timestamp', () async {
        final client = _FakeSftpClient();
        final fileSystem = DartSshRemoteFileSystem(client);

        expect(() => fileSystem.setTimes('/srv/file.txt'), throwsArgumentError);
        expect(client.statCalls, 0);
      });

      test('fails closed when the server hides the current times', () async {
        final client = _FakeSftpClient(
          statResult: SftpFileAttrs(mode: const SftpFileMode.value(0x81A4)),
        );
        final fileSystem = DartSshRemoteFileSystem(client);

        await expectLater(
          fileSystem.setTimes(
            '/srv/file.txt',
            modifiedAt: DateTime.utc(2025, 2, 3, 4, 5, 6),
          ),
          throwsA(
            isA<RemoteFileException>().having(
              (error) => error.kind,
              'kind',
              RemoteFileErrorKind.unsupported,
            ),
          ),
        );
        expect(client.lastSetStat, isNull);
      });

      test('maps a server rejection to the standard message', () async {
        final client = _FakeSftpClient(
          statResult: SftpFileAttrs(
            mode: const SftpFileMode.value(0x81A4),
            accessTime: 1700000000,
            modifyTime: 1700000100,
          ),
          setStatError: SftpStatusError(
            SftpStatusCode.opUnsupported,
            'operation unsupported',
          ),
        );
        final fileSystem = DartSshRemoteFileSystem(client);

        await expectLater(
          fileSystem.setTimes(
            '/srv/file.txt',
            modifiedAt: DateTime.utc(2025, 2, 3, 4, 5, 6),
          ),
          throwsA(
            isA<RemoteFileException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  RemoteFileErrorKind.unsupported,
                )
                .having(
                  (error) => error.message,
                  'message',
                  'Could not change timestamps for "/srv/file.txt": '
                      'operation unsupported',
                ),
          ),
        );
      });
    });

    group('setOwner', () {
      test('sets both uid and gid', () async {
        final client = _FakeSftpClient();
        final fileSystem = DartSshRemoteFileSystem(client);

        await fileSystem.setOwner('/srv/file.txt', uid: 0, gid: 0);

        expect(client.lastSetStat?.userID, 0);
        expect(client.lastSetStat?.groupID, 0);
      });

      test('fills the unspecified owner field from the server', () async {
        final client = _FakeSftpClient(
          statResult: SftpFileAttrs(
            mode: const SftpFileMode.value(0x81A4),
            userID: 1000,
            groupID: 1001,
          ),
        );
        final fileSystem = DartSshRemoteFileSystem(client);

        await fileSystem.setOwner('/srv/file.txt', uid: 0);

        expect(client.lastSetStat?.userID, 0);
        expect(client.lastSetStat?.groupID, 1001);

        client.lastSetStat = null;
        await fileSystem.setOwner('/srv/file.txt', gid: 100);

        expect(client.lastSetStat?.userID, 1000);
        expect(client.lastSetStat?.groupID, 100);
      });

      test('does not change ownership through a symbolic link', () async {
        final client = _FakeSftpClient(
          statResult: SftpFileAttrs(mode: const SftpFileMode.value(0xA1FF)),
        );
        final fileSystem = DartSshRemoteFileSystem(client);

        await expectLater(
          fileSystem.setOwner('/srv/link', uid: 0),
          throwsA(
            isA<RemoteFileException>().having(
              (error) => error.kind,
              'kind',
              RemoteFileErrorKind.unsupported,
            ),
          ),
        );
        expect(client.lastSetStat, isNull);
      });

      test('validates owner ids before contacting SFTP', () async {
        final client = _FakeSftpClient();
        final fileSystem = DartSshRemoteFileSystem(client);

        expect(
          () => fileSystem.setOwner('/srv/file.txt', uid: -1),
          throwsRangeError,
        );
        expect(
          () => fileSystem.setOwner('/srv/file.txt', gid: 0x100000000),
          throwsRangeError,
        );
        expect(() => fileSystem.setOwner('/srv/file.txt'), throwsArgumentError);
        expect(client.statCalls, 0);
      });

      test('fails closed when the server hides the current owner', () async {
        final client = _FakeSftpClient(
          statResult: SftpFileAttrs(mode: const SftpFileMode.value(0x81A4)),
        );
        final fileSystem = DartSshRemoteFileSystem(client);

        await expectLater(
          fileSystem.setOwner('/srv/file.txt', uid: 0),
          throwsA(
            isA<RemoteFileException>().having(
              (error) => error.kind,
              'kind',
              RemoteFileErrorKind.unsupported,
            ),
          ),
        );
        expect(client.lastSetStat, isNull);
      });

      test('maps a server rejection to the standard message', () async {
        final client = _FakeSftpClient(
          statResult: SftpFileAttrs(
            mode: const SftpFileMode.value(0x81A4),
            userID: 1000,
            groupID: 1001,
          ),
          setStatError: SftpStatusError(
            SftpStatusCode.opUnsupported,
            'operation unsupported',
          ),
        );
        final fileSystem = DartSshRemoteFileSystem(client);

        await expectLater(
          fileSystem.setOwner('/srv/file.txt', uid: 0),
          throwsA(
            isA<RemoteFileException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  RemoteFileErrorKind.unsupported,
                )
                .having(
                  (error) => error.message,
                  'message',
                  'Could not change owner for "/srv/file.txt": '
                      'operation unsupported',
                ),
          ),
        );
      });
    });

    test('reads a symbolic link target without resolving it', () async {
      final client = _FakeSftpClient(readlinkResult: '../target');
      final fileSystem = DartSshRemoteFileSystem(client);

      expect(await fileSystem.readSymbolicLink('/srv/link'), '../target');
      expect(client.lastReadlinkPath, '/srv/link');
    });

    test('maps symbolic link read failures to typed errors', () async {
      final client = _FakeSftpClient(
        readlinkError: SftpStatusError(
          SftpStatusCode.permissionDenied,
          'permission denied',
        ),
      );
      final fileSystem = DartSshRemoteFileSystem(client);

      await expectLater(
        fileSystem.readSymbolicLink('/srv/link'),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.permissionDenied,
          ),
        ),
      );
    });

    test(
      'creates non-overwriting links with target-first SFTP order',
      () async {
        final client = _FakeSftpClient(
          statError: SftpStatusError(SftpStatusCode.noSuchFile, 'not found'),
        );
        final fileSystem = DartSshRemoteFileSystem(client);

        await fileSystem.createSymbolicLink('/srv/link', '../target');

        expect(client.lastLinkFirstArgument, '../target');
        expect(client.lastLinkSecondArgument, '/srv/link');
      },
    );

    test('rejects a symbolic link path that already exists', () async {
      final client = _FakeSftpClient();
      final fileSystem = DartSshRemoteFileSystem(client);

      await expectLater(
        fileSystem.createSymbolicLink('/srv/link', '../target'),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
      expect(client.lastLinkFirstArgument, isNull);
    });
  });
}

class _FakeSftpClient implements SftpClient {
  _FakeSftpClient({
    SftpFileAttrs? statResult,
    this.statError,
    this.setStatError,
    this.readlinkResult = 'target',
    this.readlinkError,
  }) : statResult =
           statResult ?? SftpFileAttrs(mode: const SftpFileMode.value(0x81A4));

  final SftpFileAttrs statResult;
  final Object? statError;
  final Object? setStatError;
  final String readlinkResult;
  final Object? readlinkError;

  int statCalls = 0;
  SftpFileAttrs? lastSetStat;
  String? lastReadlinkPath;
  String? lastLinkFirstArgument;
  String? lastLinkSecondArgument;
  String? lastRenameOldPath;
  SftpFile? openedFile;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    statCalls++;
    if (statError case final error?) throw error;
    return statResult;
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async => openedFile ?? (throw StateError('No fake file configured'));

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    if (setStatError case final error?) throw error;
    lastSetStat = attrs;
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    lastRenameOldPath = oldPath;
  }

  @override
  Future<String> readlink(String path) async {
    lastReadlinkPath = path;
    if (readlinkError case final error?) throw error;
    return readlinkResult;
  }

  @override
  Future<void> link(String linkPath, String targetPath) async {
    lastLinkFirstArgument = linkPath;
    lastLinkSecondArgument = targetPath;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSftpFile extends SftpFile {
  _FakeSftpFile(SftpClient client, this.attrs, this.source)
    : super(client, Uint8List(0));

  final SftpFileAttrs attrs;
  final Stream<Uint8List> source;

  @override
  Future<SftpFileAttrs> stat() async => attrs;

  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 1,
    int maxPendingRequests = 1,
  }) async* {
    var total = 0;
    await for (final chunk in source) {
      total += chunk.length;
      yield chunk;
    }
    onProgress?.call(total);
  }

  @override
  Future<void> close() async {}
}

class _FakeWritableSftpFile extends SftpFile {
  _FakeWritableSftpFile(SftpClient client) : super(client, Uint8List(0));

  final List<Uint8List> writes = [];

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    writes.add(data);
  }

  @override
  Future<void> close() async {}
}

class _DiscardingSink implements StreamSink<List<int>> {
  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}
