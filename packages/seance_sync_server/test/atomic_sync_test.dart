@Timeout(Duration(seconds: 15))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

enum _Backend { memory, sqlite }

enum _ReadPoint { record, pull }

// Force the old handler's split operations to interleave without timed sleeps.
class _ReadBarrier {
  _ReadPoint? _point;
  final reached = Completer<void>();
  final release = Completer<void>();

  void arm(_ReadPoint point) => _point = point;

  Future<T> hold<T>(_ReadPoint point, T value) async {
    if (_point != point) return value;
    _point = null;
    reached.complete();
    await release.future;
    return value;
  }
}

class _MemoryStorage extends InMemoryStorage {
  final _ReadBarrier _barrier;
  _MemoryStorage(this._barrier);

  @override
  Future<EncryptedRecord?> getRecord(String username, String id) async =>
      _barrier.hold(_ReadPoint.record, await super.getRecord(username, id));

  @override
  Future<List<EncryptedRecord>> recordsSince(
    String username,
    int since,
  ) async =>
      _barrier.hold(_ReadPoint.pull, await super.recordsSince(username, since));
}

class _SqliteStorage extends SqliteStorage {
  final _ReadBarrier _barrier;
  _SqliteStorage(super.db, this._barrier);

  @override
  Future<EncryptedRecord?> getRecord(String username, String id) async =>
      _barrier.hold(_ReadPoint.record, await super.getRecord(username, id));

  @override
  Future<List<EncryptedRecord>> recordsSince(
    String username,
    int since,
  ) async =>
      _barrier.hold(_ReadPoint.pull, await super.recordsSince(username, since));
}

EncryptedRecord _record(String id, int revision) => EncryptedRecord(
  id: id,
  updatedAt: revision,
  deviceId: 'device',
  deleted: false,
  seq: null,
  blob: Uint8List.fromList(utf8.encode('payload-$revision')),
);

Future<HttpSyncClient> _connect(Storage storage) async {
  final running = await SyncServer(
    storage: storage,
    settings: const ServerSettings(
      openRegistration: true,
      bindAddress: '127.0.0.1',
      port: 0,
    ),
  ).start();
  addTearDown(running.close);
  final client = HttpSyncClient(
    baseUrl: 'http://${running.host}:${running.port}',
  );
  addTearDown(client.close);
  await client.register(
    RegisterRequest(
      username: 'user',
      authVerifier: base64Encode(secureRandomBytes(32)),
      argonSalt: base64Encode(secureRandomBytes(16)),
      argonParams: const Argon2Params(),
    ),
  );
  return client;
}

void main() {
  for (final backend in _Backend.values) {
    group(backend.name, () {
      late _ReadBarrier barrier;
      late HttpSyncClient client;

      setUp(() async {
        barrier = _ReadBarrier();
        final Storage storage;
        if (backend == _Backend.sqlite) {
          final sqlite = _SqliteStorage(sqlite3.openInMemory(), barrier);
          addTearDown(sqlite.close);
          storage = sqlite;
        } else {
          storage = _MemoryStorage(barrier);
        }
        client = await _connect(storage);
      });

      test('a delayed stale push cannot overwrite the LWW winner', () async {
        barrier.arm(_ReadPoint.record);
        final older = client.push([_record('shared', 10)]);
        // Atomic storage can finish without exposing an intermediate read.
        await Future.any([barrier.reached.future, older.then((_) {})]);
        await client.push([_record('shared', 20)]);
        barrier.release.complete();
        await older;

        final pull = await client.pull(since: 0);
        expect(pull.records.single.updatedAt, 20);
        expect(utf8.decode(pull.records.single.blob), 'payload-20');
      });

      test('pull records and watermark describe the same snapshot', () async {
        await client.push([_record('shared', 10)]);
        barrier.arm(_ReadPoint.pull);
        final pulling = client.pull(since: 0);
        await Future.any([barrier.reached.future, pulling.then((_) {})]);
        await client.push([_record('shared', 20)]);
        barrier.release.complete();
        final snapshot = await pulling;

        expect(snapshot.records.single.seq, snapshot.latestSeq);
        final next = await client.pull(since: snapshot.latestSeq);
        expect(next.records.single.updatedAt, 20);
      });
    });
  }

  test('SQLite contention fails atomically and can be retried', () async {
    final directory = await Directory.systemTemp.createTemp('seance-lock-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/sync.sqlite';
    final storage = SqliteStorage.open(path);
    addTearDown(storage.close);
    final client = await _connect(storage);
    await client.push([_record('existing', 10)]);
    final before = await client.pull(since: 0);
    final writer = sqlite3.open(path);
    addTearDown(writer.dispose);

    writer.execute('BEGIN IMMEDIATE');
    try {
      await expectLater(
        client.push([_record('existing', 20), _record('new', 30)]),
        throwsA(
          isA<ApiError>().having((e) => e.code, 'code', 'internal_error'),
        ),
      );
      expect((await client.pull(since: 0)).toJson(), before.toJson());
    } finally {
      writer.execute('ROLLBACK');
    }

    final retry = await client.push([_record('existing', 20)]);
    expect(retry.results.single.seq, before.latestSeq + 1);
    expect((await client.pull(since: 0)).records.single.updatedAt, 20);
  });

  test('SQLite snapshot survives a commit from another connection', () async {
    final directory = await Directory.systemTemp.createTemp('seance-snapshot-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/sync.sqlite';
    final database = sqlite3.open(path);
    final storage = SqliteStorage(database);
    addTearDown(storage.close);
    final client = await _connect(storage);
    await client.push([_record('shared', 10)]);
    final writer = sqlite3.open(path);
    addTearDown(writer.dispose);

    // A test-only view commits another connection while the watermark is read.
    // Only a real read transaction can keep the following row query on that snapshot.
    var committed = false;
    database.createFunction(
      functionName: 'capture_sequence',
      argumentCount: const AllowedArgumentCount(1),
      directOnly: false,
      function: (arguments) {
        if (!committed) {
          writer.execute('BEGIN IMMEDIATE');
          writer.execute('UPDATE records SET updated_at = 20, seq = 2');
          writer.execute('UPDATE sequence_data SET value = 2');
          writer.execute('COMMIT');
          committed = true;
        }
        return arguments.single;
      },
    );
    database.execute('ALTER TABLE seqs RENAME TO sequence_data');
    database.execute(
      'CREATE VIEW seqs AS SELECT username, '
      'capture_sequence(value) AS value FROM sequence_data',
    );

    final snapshot = await client.pull(since: 0);
    expect(committed, isTrue);
    expect(snapshot.latestSeq, 1);
    expect(snapshot.records.single.updatedAt, 10);
    final delta = await client.pull(since: snapshot.latestSeq);
    expect(delta.records.single.updatedAt, 20);
    expect(delta.latestSeq, 2);
  });

  test(
    'SQLite rolls back the entire failed HTTP push and its sequence',
    () async {
      final directory = await Directory.systemTemp.createTemp('seance-atomic-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/sync.sqlite';
      final database = sqlite3.open(path);
      final storage = SqliteStorage(database);
      addTearDown(storage.close);
      final client = await _connect(storage);
      await client.push([_record('existing', 10)]);
      final before = await client.pull(since: 0);

      // A late write failure must also undo earlier upserts and seq allocation.
      database.execute('''
      CREATE TRIGGER fail_record BEFORE INSERT ON records
      WHEN NEW.id = 'abort'
      BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;
    ''');
      await expectLater(
        client.push([
          _record('existing', 20),
          _record('new', 20),
          _record('abort', 20),
        ]),
        throwsA(
          isA<ApiError>().having((e) => e.code, 'code', 'internal_error'),
        ),
      );
      expect((await client.pull(since: 0)).toJson(), before.toJson());

      // A fresh connection sees the rollback, not just cached in-process state.
      final reopened = SqliteStorage.open(path);
      addTearDown(reopened.close);
      expect(await reopened.latestSeq('user'), before.latestSeq);
      expect((await reopened.getRecord('user', 'existing'))!.updatedAt, 10);
      expect(await reopened.getRecord('user', 'new'), isNull);

      database.execute('DROP TRIGGER fail_record');
      final retry = await client.push([_record('new', 30)]);
      expect(retry.results.single.seq, before.latestSeq + 1);
    },
  );
}
