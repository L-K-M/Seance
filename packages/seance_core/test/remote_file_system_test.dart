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
    this.readlinkResult = 'target',
    this.readlinkError,
  }) : statResult =
           statResult ?? SftpFileAttrs(mode: const SftpFileMode.value(0x81A4));

  final SftpFileAttrs statResult;
  final Object? statError;
  final String readlinkResult;
  final Object? readlinkError;

  int statCalls = 0;
  SftpFileAttrs? lastSetStat;
  String? lastReadlinkPath;
  String? lastLinkFirstArgument;
  String? lastLinkSecondArgument;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    statCalls++;
    if (statError case final error?) throw error;
    return statResult;
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    lastSetStat = attrs;
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
