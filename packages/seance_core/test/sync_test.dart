import 'dart:typed_data';

import 'package:seance_core/src/sync/local_record_store.dart';
import 'package:seance_core/src/sync/sync_engine.dart';
import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

/// An in-memory stand-in for the sync server: stores the LWW-winning version of
/// each record and hands out monotonic sequence numbers. Two [SyncEngine]s
/// pointed at one instance must converge.
class FakeServer implements SyncApi {
  final Map<String, EncryptedRecord> _store = {};
  int _seq = 0;

  @override
  Future<PullResponse> pull({required int since}) async {
    final records = _store.values
        .where((r) => (r.seq ?? 0) > since)
        .toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return PullResponse(records: records, latestSeq: _seq);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    final results = <PushResult>[];
    for (final incoming in records) {
      final existing = _store[incoming.id];
      final winner =
          existing == null ? incoming : Lww.resolve(existing, incoming);
      final incomingWon = identical(winner, incoming) || existing == null;
      if (incomingWon) {
        final assigned = incoming.withSeq(++_seq);
        _store[incoming.id] = assigned;
        results.add(
            PushResult(id: incoming.id, seq: assigned.seq!, accepted: true));
      } else {
        results.add(PushResult(
            id: incoming.id, seq: existing.seq ?? 0, accepted: false));
      }
    }
    return PushResponse(results: results, latestSeq: _seq);
  }
}

EncryptedRecord rec(String id, int updatedAt, String device,
        {bool deleted = false, int tag = 0}) =>
    EncryptedRecord(
      id: id,
      updatedAt: updatedAt,
      deviceId: device,
      deleted: deleted,
      seq: null,
      blob: Uint8List.fromList([tag]),
    );

void main() {
  group('SyncEngine', () {
    test('pushes local records to an empty server', () async {
      final server = FakeServer();
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('a', 10, 'dev1'));
      await store.putLocal(rec('b', 11, 'dev1'));
      final engine = SyncEngine(store);

      final outcome = await engine.sync(server);
      expect(outcome.pushed, 2);
      expect((await store.dirtyRecords()), isEmpty);

      final onServer = await server.pull(since: 0);
      expect(onServer.records.map((r) => r.id).toSet(), {'a', 'b'});
    });

    test('two devices converge on the same records', () async {
      final server = FakeServer();

      final storeA = InMemoryLocalRecordStore();
      final storeB = InMemoryLocalRecordStore();
      final devA = SyncEngine(storeA);
      final devB = SyncEngine(storeB);

      // Device A creates two servers; device B creates one.
      await storeA.putLocal(rec('a', 10, 'A', tag: 1));
      await storeA.putLocal(rec('b', 10, 'A', tag: 2));
      await storeB.putLocal(rec('c', 10, 'B', tag: 3));

      await devA.sync(server);
      await devB.sync(server);
      await devA.sync(server); // A pulls B's record

      Future<Set<String>> liveIds(InMemoryLocalRecordStore s) async =>
          (await s.allRecords())
              .where((r) => !r.deleted)
              .map((r) => r.id)
              .toSet();

      expect(await liveIds(storeA), {'a', 'b', 'c'});
      expect(await liveIds(storeB), {'a', 'b', 'c'});
    });

    test('concurrent edit to one record resolves by last-write-wins', () async {
      final server = FakeServer();
      final storeA = InMemoryLocalRecordStore();
      final storeB = InMemoryLocalRecordStore();

      // Both start from a shared record.
      await storeA.putLocal(rec('x', 5, 'A', tag: 1));
      await SyncEngine(storeA).sync(server);
      await SyncEngine(storeB).sync(server); // B pulls x

      // Both edit x concurrently; B's edit is later (higher updatedAt).
      await storeA.putLocal(rec('x', 20, 'A', tag: 10));
      await storeB.putLocal(rec('x', 30, 'B', tag: 20));

      await SyncEngine(storeA).sync(server);
      await SyncEngine(storeB).sync(server);
      await SyncEngine(storeA).sync(server); // A reconciles

      final a = await storeA.getRecord('x');
      final b = await storeB.getRecord('x');
      // B's later write (updatedAt 30) wins on both devices.
      expect(a!.updatedAt, 30);
      expect(a.deviceId, 'B');
      expect(b!.updatedAt, 30);
      expect(a.blob, equals(b.blob));
    });

    test('a delete propagates as a tombstone', () async {
      final server = FakeServer();
      final storeA = InMemoryLocalRecordStore();
      final storeB = InMemoryLocalRecordStore();

      await storeA.putLocal(rec('y', 5, 'A', tag: 1));
      await SyncEngine(storeA).sync(server);
      await SyncEngine(storeB).sync(server); // B has y

      // A deletes y (later timestamp).
      await storeA.putLocal(rec('y', 50, 'A', deleted: true));
      await SyncEngine(storeA).sync(server);
      await SyncEngine(storeB).sync(server); // B pulls the tombstone

      final onB = await storeB.getRecord('y');
      expect(onB!.deleted, isTrue);
    });
  });
}
