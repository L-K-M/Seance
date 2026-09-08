import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:seance_core/seance_core.dart';
import 'package:seance_core/src/ssh/remote_file_system.dart'
    show DartSshRemoteFileSystem;
import 'package:test/test.dart';

const _path = '/file';
const _newPath = '/new';
const _regularMode = SftpFileMode.value(0x81a4);
final _attrs = SftpFileAttrs(size: 1, mode: _regularMode);
const _entry = RemoteFileEntry(
  path: _path,
  name: 'file',
  type: RemoteFileType.file,
);
const _directory = RemoteFileEntry(
  path: '/directory',
  name: 'directory',
  type: RemoteFileType.directory,
);

void main() {
  final metadataCalls = <String, Future<Object?> Function(RemoteFileSystem)>{
    'canonicalize': (fs) => fs.canonicalize(_path),
    'list': (fs) => fs.listDirectory(_path),
    'stat': (fs) => fs.stat(_path),
    'mode': (fs) => fs.setMode(_path, 0x1a4),
    'times': (fs) => fs.setTimes(
      _path,
      accessedAt: DateTime.utc(2026),
      modifiedAt: DateTime.utc(2026),
    ),
    'owner': (fs) => fs.setOwner(_path, uid: 1000, gid: 1000),
    'readlink': (fs) => fs.readSymbolicLink(_path),
    'symlink': (fs) => fs.createSymbolicLink(_newPath, _path),
    'mkdir': (fs) => fs.createDirectory(_path),
    'rename': (fs) => fs.rename(_path, _newPath),
    'remove': (fs) => fs.delete(_entry),
    'rmdir': (fs) => fs.delete(_directory),
  };

  for (final MapEntry(key: name, value: call) in metadataCalls.entries) {
    test('$name stays active through every nested request', () async {
      final gate = Completer<void>();
      final client = _ActivityClient();
      final fs = DartSshRemoteFileSystem(client);
      client.beforeRequest = (_) {
        expect(fs.hasActiveOperations, isTrue);
        return gate.future;
      };
      expect(fs.hasActiveOperations, isFalse);
      final result = call(fs);
      expect(fs.hasActiveOperations, isTrue);
      gate.complete();
      await result;
      expect(fs.hasActiveOperations, isFalse);
    });
  }

  test('one completion cannot mark another outstanding call idle', () async {
    final first = Completer<void>();
    final second = Completer<void>();
    final client = _ActivityClient()
      ..beforeRequest = (path) => path == _path ? first.future : second.future;
    final fs = DartSshRemoteFileSystem(client);
    final a = fs.canonicalize(_path);
    final b = fs.canonicalize(_newPath);
    first.complete();
    await a;
    expect(fs.hasActiveOperations, isTrue);
    second.complete();
    await b;
    expect(fs.hasActiveOperations, isFalse);
  });

  for (final failure in [
    StateError('synchronous failure'),
    SftpStatusError(SftpStatusCode.permissionDenied, 'denied'),
  ]) {
    test(
      'clears activity after $failure without changing error mapping',
      () async {
        final client = _ActivityClient()..failure = failure;
        final fs = DartSshRemoteFileSystem(client);
        await expectLater(
          fs.canonicalize(_path),
          throwsA(
            isA<RemoteFileException>().having(
              (e) => e.cause,
              'cause',
              same(failure),
            ),
          ),
        );
        expect(fs.hasActiveOperations, isFalse);
      },
    );
  }

  test('validation failures do not leave activity armed', () {
    final fs = DartSshRemoteFileSystem(_ActivityClient());
    expect(() => fs.setMode(_path, -1), throwsRangeError);
    expect(fs.hasActiveOperations, isFalse);
  });

  test(
    'timeout retires the call even if its wire request settles late',
    () async {
      final gate = Completer<void>();
      final client = _ActivityClient()..beforeRequest = (_) => gate.future;
      final fs = DartSshRemoteFileSystem(
        client,
        operationTimeout: Duration.zero,
      );
      final result = fs.canonicalize(_path);
      expect(fs.hasActiveOperations, isTrue);
      await expectLater(
        result,
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.disconnected,
          ),
        ),
      );
      expect(fs.hasActiveOperations, isFalse);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(fs.hasActiveOperations, isFalse);
    },
  );

  test(
    'download stays active while streaming and awaiting file close',
    () async {
      final listened = Completer<void>();
      final source = StreamController<Uint8List>(onListen: listened.complete);
      final client = _ActivityClient();
      final file = client.file = _ActivityFile(client, source.stream);
      final fs = DartSshRemoteFileSystem(client);
      final sink = StreamController<List<int>>();
      final drained = sink.stream.drain<void>();
      final result = fs.download(_path, sink.sink);
      await listened.future;
      expect(fs.hasActiveOperations, isTrue);
      source.add(Uint8List.fromList([1]));
      await source.close();
      await file.closing.future;
      expect(fs.hasActiveOperations, isTrue);
      file.closed.complete();
      await result;
      expect(fs.hasActiveOperations, isFalse);
      await sink.close();
      await drained;
    },
  );

  for (final outcome in _UploadOutcome.values) {
    test(
      'upload ${outcome.name} tracks streaming, nesting and cleanup',
      () async {
        final listened = Completer<void>();
        final source = StreamController<List<int>>(onListen: listened.complete);
        final client = _ActivityClient();
        final file = client.file = _ActivityFile(client, const Stream.empty());
        final fs = DartSshRemoteFileSystem(client);
        client.beforeRequest = (_) async =>
            expect(fs.hasActiveOperations, isTrue);
        final cancellation = RemoteTransferCancellation();
        final result = fs.upload(
          _path,
          source.stream,
          overwrite: true,
          cancellation: cancellation,
        );
        final checked = outcome == _UploadOutcome.cancel
            ? expectLater(
                result,
                throwsA(
                  isA<RemoteFileException>().having(
                    (e) => e.kind,
                    'kind',
                    RemoteFileErrorKind.cancelled,
                  ),
                ),
              )
            : result;
        await listened.future;
        expect(fs.hasActiveOperations, isTrue);
        if (outcome == _UploadOutcome.cancel) {
          cancellation.cancel();
        } else {
          source.add([1]);
          await source.close();
        }
        await file.closing.future;
        expect(fs.hasActiveOperations, isTrue);
        file.closed.complete();
        await checked;
        expect(fs.hasActiveOperations, isFalse);
        await source.close();
      },
    );
  }
}

enum _UploadOutcome { complete, cancel }

class _ActivityClient implements SftpClient {
  Future<void> Function(String)? beforeRequest;
  Object? failure;
  _ActivityFile? file;

  Future<T> _request<T>(String path, T value) async {
    await beforeRequest?.call(path);
    return value;
  }

  @override
  Future<String> absolute(String path) {
    if (failure case final error?) throw error;
    return _request(path, path);
  }

  @override
  Future<List<SftpName>> listdir(String path) => _request(path, []);
  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    await _request(path, null);
    if (path == _newPath) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'absent');
    }
    return _attrs;
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) =>
      _request(path, null);
  @override
  Future<String> readlink(String path) => _request(path, _path);
  @override
  Future<void> link(String path, String target) => _request(path, null);
  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) => _request(path, null);
  @override
  Future<void> rename(String path, String target) => _request(path, null);
  @override
  Future<void> remove(String path) => _request(path, null);
  @override
  Future<void> rmdir(String path) => _request(path, null);
  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) => _request(path, file!);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ActivityFile extends SftpFile {
  final Stream<Uint8List> source;
  final closing = Completer<void>();
  final closed = Completer<void>();

  _ActivityFile(SftpClient client, this.source) : super(client, Uint8List(0));

  @override
  Future<SftpFileAttrs> stat() async => _attrs;
  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {}
  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int)? onProgress,
    int chunkSize = 1,
    int maxPendingRequests = 1,
  }) async* {
    var total = 0;
    await for (final chunk in source) {
      total += chunk.length;
      onProgress?.call(total);
      yield chunk;
    }
  }

  @override
  Future<void> close() {
    if (!closing.isCompleted) closing.complete();
    return closed.future;
  }
}
