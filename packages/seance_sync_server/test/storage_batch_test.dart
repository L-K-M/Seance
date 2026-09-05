import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

EncryptedRecord _record(
  String id,
  int revision, {
  String deviceId = 'device',
}) => EncryptedRecord(
  id: id,
  updatedAt: revision,
  deviceId: deviceId,
  deleted: false,
  seq: null,
  blob: Uint8List.fromList([revision]),
);

enum _CleanupFault { rollback, stateRead }

class _FaultingDatabase implements Database {
  final Database _inner;
  final _CleanupFault _fault;
  bool disposed = false;

  _FaultingDatabase(this._inner, this._fault);

  @override
  void execute(String sql, [List<Object?> parameters = const []]) {
    if (sql == 'ROLLBACK' && _fault == _CleanupFault.rollback) {
      throw StateError('injected cleanup failure');
    }
    _inner.execute(sql, parameters);
  }

  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
      _inner.select(sql, parameters);

  @override
  bool get autocommit {
    if (_fault == _CleanupFault.stateRead) {
      throw StateError('injected state-read failure');
    }
    return _inner.autocommit;
  }

  @override
  void dispose() {
    disposed = true;
    _inner.dispose();
  }

  @override
  Never noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '_FaultingDatabase does not implement ${invocation.memberName}',
  );
}

void main() {
  for (final fault in _CleanupFault.values) {
    test(
      'failed ${fault.name} preserves the cause and closes storage',
      () async {
        final database = sqlite3.openInMemory();
        final adapter = _FaultingDatabase(database, fault);
        final storage = SqliteStorage(adapter);
        addTearDown(storage.close);
        database.execute('''
        CREATE TRIGGER fail_record BEFORE INSERT ON records
        BEGIN SELECT RAISE(ABORT, 'original write failure'); END;
      ''');

        await expectLater(
          storage.pushRecords('user', [_record('record', 10)]),
          throwsA(
            isA<SqliteException>().having(
              (e) => e.message,
              'cause',
              contains('original write failure'),
            ),
          ),
        );
        expect(adapter.disposed, isTrue);
        final handler = SyncServer(
          storage: storage,
          settings: const ServerSettings(),
        ).handler;
        for (final (method, path) in [
          ('GET', '/v1/sync'),
          ('PUT', '/v1/records'),
        ]) {
          final response = await handler(
            Request(
              method,
              Uri.parse('http://localhost$path'),
              headers: {'authorization': 'Bearer unused'},
            ),
          );
          expect(response.statusCode, HttpStatus.serviceUnavailable);
          expect(
            jsonDecode(await response.readAsString())['error'],
            'storage_unavailable',
          );
        }
        expect(storage.close, returnsNormally);
      },
    );
  }

  final factories = <String, Storage Function()>{
    'memory': InMemoryStorage.new,
    'sqlite': () {
      final storage = SqliteStorage.open(':memory:');
      addTearDown(storage.close);
      return storage;
    },
  };

  for (final entry in factories.entries) {
    group(entry.key, () {
      late Storage storage;
      setUp(() async {
        storage = entry.value();
        for (final username in ['alice', 'bob']) {
          await storage.createAccount(
            Account(
              username: username,
              authVerifierHash: 'unused',
              verifierSalt: 'unused',
              argonSalt: 'unused',
              argonParams: const Argon2Params(),
            ),
          );
        }
      });

      test('mixed batches allocate only accepted writes, in order', () async {
        await storage.pushRecords('alice', [_record('old', 20)]);
        final result = await storage.pushRecords('alice', [
          _record('old', 10),
          _record('new', 30),
          _record('another', 40),
        ]);
        expect(result.results.map((r) => r.accepted), [false, true, true]);
        expect(result.results.map((r) => r.seq), [1, 2, 3]);
        expect(result.latestSeq, 3);
        final delta = await storage.pullSnapshot('alice', 1);
        expect(delta.records.map((r) => r.id), ['new', 'another']);
        expect(delta.latestSeq, 3);
        expect((await storage.pullSnapshot('alice', 3)).records, isEmpty);
      });

      test('repeated ids resolve against earlier staged writes', () async {
        final result = await storage.pushRecords('alice', [
          _record('same', 10),
          _record('same', 20),
          _record('same', 15),
        ]);
        expect(result.results.map((r) => r.accepted), [true, true, false]);
        expect(result.results.map((r) => r.seq), [1, 2, 2]);
        expect(result.latestSeq, 2);
        expect(
          (await storage.pullSnapshot('alice', 0)).records.single.updatedAt,
          20,
        );
      });

      test('timestamp ties use device id then server sequence', () async {
        await storage.pushRecords('alice', [
          _record('same', 10, deviceId: 'a'),
        ]);
        final result = await storage.pushRecords('alice', [
          _record('same', 10, deviceId: 'z'),
          _record('same', 10, deviceId: 'b'),
          _record('same', 10, deviceId: 'z'),
        ]);
        expect(result.results.map((r) => r.accepted), [true, false, false]);
        expect(result.results.map((r) => r.seq), [2, 2, 2]);
        expect(
          (await storage.pullSnapshot('alice', 0)).records.single.deviceId,
          'z',
        );
      });

      test(
        'accounts, empty batches and captured snapshots stay isolated',
        () async {
          expect((await storage.pushRecords('alice', [])).latestSeq, 0);
          await storage.pushRecords('alice', [_record('same-id', 10)]);
          final snapshot = await storage.pullSnapshot('alice', 0);
          await storage.pushRecords('alice', [_record('same-id', 20)]);
          await storage.pushRecords('bob', [_record('same-id', 30)]);

          expect(snapshot.latestSeq, 1);
          expect(snapshot.records.single.updatedAt, 10);
          final bob = await storage.pullSnapshot('bob', 0);
          expect(bob.latestSeq, 1);
          expect(bob.records.single.updatedAt, 30);
          expect((await storage.pushRecords('alice', [])).latestSeq, 2);
        },
      );

      test(
        'a failed batch leaves both records and sequence unchanged',
        () async {
          await storage.pushRecords('alice', [_record('existing', 10)]);
          final before = await storage.pullSnapshot('alice', 0);
          // A lazy list failure exercises rollback after the first staged write.
          final invalid = <Object>[
            _record('existing', 20),
            'not a record',
          ].cast<EncryptedRecord>();
          await expectLater(
            storage.pushRecords('alice', invalid),
            throwsA(isA<TypeError>()),
          );
          expect(
            (await storage.pullSnapshot('alice', 0)).toJson(),
            before.toJson(),
          );
        },
      );
    });
  }

  test(
    'SQLite preserves the cause when a trigger rolls back the transaction',
    () async {
      final database = sqlite3.openInMemory();
      final storage = SqliteStorage(database);
      addTearDown(storage.close);
      database.execute('''
      CREATE TRIGGER fail_record BEFORE INSERT ON records
      WHEN NEW.id = 'poison'
      BEGIN SELECT RAISE(ROLLBACK, 'injected rollback'); END;
    ''');
      await expectLater(
        storage.pushRecords('user', [_record('ok', 10), _record('poison', 20)]),
        throwsA(
          isA<SqliteException>().having(
            (e) => e.message,
            'cause',
            contains('injected rollback'),
          ),
        ),
      );
      expect(database.autocommit, isTrue);
      final snapshot = await storage.pullSnapshot('user', 0);
      expect(snapshot.records, isEmpty);
      expect(snapshot.latestSeq, 0);
      expect(
        (await storage.pushRecords('user', [_record('ok', 10)])).latestSeq,
        1,
      );
    },
  );
}
