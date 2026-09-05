import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

EncryptedRecord _record(String id, int revision) => EncryptedRecord(
  id: id,
  updatedAt: revision,
  deviceId: 'device',
  deleted: false,
  seq: null,
  blob: Uint8List.fromList([revision]),
);

void main() {
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
      BEGIN SELECT RAISE(ROLLBACK, 'injected rollback'); END;
    ''');
      await expectLater(
        storage.pushRecords('user', [_record('record', 10)]),
        throwsA(
          isA<SqliteException>().having(
            (e) => e.message,
            'cause',
            contains('injected rollback'),
          ),
        ),
      );
      expect(database.autocommit, isTrue);
      expect((await storage.pullSnapshot('user', 0)).records, isEmpty);
    },
  );
}
