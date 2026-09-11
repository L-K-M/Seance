import 'dart:convert';
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

  /// What one push may carry, enforced exactly as the real server does and
  /// advertised in every pull. Null models a server too old to advertise: it
  /// still enforces the shipped defaults, so a client that guesses them wrong
  /// is caught here rather than in production.
  final PushLimits? advertisedLimits;

  /// The size of each push the engine sent, in order, so a test can assert how
  /// a dirty set was split rather than only that it arrived.
  final List<int> pushedBatchSizes = [];

  FakeServer({this.advertisedLimits});

  PushLimits get _enforced => advertisedLimits ?? const PushLimits();

  @override
  Future<PullResponse> pull({required int since}) async {
    final records = _store.values
        .where((r) => (r.seq ?? 0) > since)
        .toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return PullResponse(
        records: records, latestSeq: _seq, limits: advertisedLimits);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    pushedBatchSizes.add(records.length);
    if (records.length > _enforced.maxRecordsPerPush) {
      throw ApiError(
          code: 'payload_too_large',
          message: 'Too many records in one push '
              '(max ${_enforced.maxRecordsPerPush})');
    }
    // Measured the way the server measures it — the bytes of the encoded body
    // — not with the arithmetic the batcher uses, so a batch sized by a wrong
    // count is rejected here just as it would be over HTTP.
    final bodyBytes =
        utf8.encode(jsonEncode(PushRequest(records: records).toJson())).length;
    if (bodyBytes > _enforced.maxBodyBytes) {
      throw ApiError(
          code: 'payload_too_large',
          message: 'Request body too large ($bodyBytes bytes)');
    }
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

class PushRaceApi implements SyncApi {
  final FakeServer server;
  final EncryptedRecord concurrentRecord;
  final bool concurrentFirst;
  bool _injected = false;

  PushRaceApi(
    this.server,
    this.concurrentRecord, {
    this.concurrentFirst = false,
  });

  @override
  Future<PullResponse> pull({required int since}) => server.pull(since: since);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    if (_injected) return server.push(records);

    _injected = true;
    if (concurrentFirst) {
      await server.push([concurrentRecord]);
      return server.push(records);
    }

    final response = await server.push(records);
    final concurrentResponse = await server.push([concurrentRecord]);
    return PushResponse(
      results: response.results,
      latestSeq: concurrentResponse.latestSeq,
    );
  }
}

class PullRaceApi implements SyncApi {
  final EncryptedRecord initiallyUnseen;
  final List<int> requestedSince = [];
  bool _returnedRacedSnapshot = false;

  PullRaceApi(this.initiallyUnseen);

  @override
  Future<PullResponse> pull({required int since}) async {
    requestedSince.add(since);
    if (!_returnedRacedSnapshot) {
      _returnedRacedSnapshot = true;
      return PullResponse(records: const [], latestSeq: initiallyUnseen.seq!);
    }

    final records = initiallyUnseen.seq! > since
        ? [initiallyUnseen]
        : const <EncryptedRecord>[];
    return PullResponse(records: records, latestSeq: initiallyUnseen.seq!);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) =>
      throw UnsupportedError('PullRaceApi does not accept pushes');
}

/// Fails from the [failFromPush]th push onwards, so a test can observe what the
/// engine has already committed when a later batch dies.
class FailingBatchApi implements SyncApi {
  final FakeServer server;
  final int failFromPush;
  int _pushes = 0;

  FailingBatchApi(this.server, {required this.failFromPush});

  @override
  Future<PullResponse> pull({required int since}) => server.pull(since: since);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    _pushes++;
    if (_pushes >= failFromPush) {
      throw const ApiError(code: 'storage_busy', message: 'Storage is busy');
    }
    return server.push(records);
  }
}

/// Accepts nothing, ever: the standing-rejection case the round cap exists for.
class RejectEverythingApi implements SyncApi {
  @override
  Future<PullResponse> pull({required int since}) async =>
      const PullResponse(records: [], latestSeq: 0);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async =>
      PushResponse(
        results: [
          for (final r in records)
            PushResult(id: r.id, seq: 0, accepted: false),
        ],
        latestSeq: 0,
      );
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

    test('push latest sequence cannot skip another device record', () async {
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('local', 10, 'A'));
      final api = PushRaceApi(FakeServer(), rec('concurrent', 11, 'B'));
      final engine = SyncEngine(store);

      await engine.sync(api);

      expect(await store.highWaterSeq(), 0);

      await engine.sync(api);

      expect(await store.getRecord('concurrent'), isNotNull);
      expect(await store.highWaterSeq(), 2);
    });

    test('rejected push adopts lexicographically larger device ID on a tie',
        () async {
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('shared', 10, 'A', tag: 1));
      final api = PushRaceApi(
        FakeServer(),
        rec('shared', 10, 'B', tag: 2),
        concurrentFirst: true,
      );

      final outcome = await SyncEngine(store).sync(api);

      final adopted = await store.getRecord('shared');
      expect(outcome.pulled, 1);
      expect(outcome.pushed, 0);
      expect(adopted!.updatedAt, 10);
      expect(adopted.deviceId, 'B');
      expect(adopted.blob, equals(Uint8List.fromList([2])));
      expect(await store.dirtyRecords(), isEmpty);
      expect(await store.highWaterSeq(), 1);
    });

    test('rejected equal-metadata payload adopts the sequenced blob', () async {
      final store = InMemoryLocalRecordStore();
      await store.putLocal(rec('shared', 10, 'A', tag: 1));
      final api = PushRaceApi(
        FakeServer(),
        rec('shared', 10, 'A', tag: 2),
        concurrentFirst: true,
      );

      await SyncEngine(store).sync(api);

      final adopted = await store.getRecord('shared');
      expect(adopted!.seq, 1);
      expect(adopted.blob, equals(Uint8List.fromList([2])));
      expect(await store.dirtyRecords(), isEmpty);
    });

    test(
      'pull latest sequence cannot skip an unseen snapshot record',
      () async {
        final store = InMemoryLocalRecordStore();
        // Sequence 1 was superseded by the current seq-2 version before the
        // second snapshot, as happens with the server's upsert storage.
        final api = PullRaceApi(rec('remote', 10, 'B').withSeq(2));
        final engine = SyncEngine(store);

        await engine.sync(api);

        expect(await store.highWaterSeq(), 0);

        await engine.sync(api);

        expect(
          api.requestedSince.take(2),
          [0, 0],
          reason: 'an unobserved latestSeq must not advance the next pull',
        );
        expect(await store.getRecord('remote'), isNotNull);
        expect(await store.highWaterSeq(), 2);
      },
    );

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

    group('push batching', () {
      /// A record of roughly [blobBytes] sealed bytes.
      EncryptedRecord bulky(String id, int blobBytes) => EncryptedRecord(
            id: id,
            updatedAt: 10,
            deviceId: 'A',
            deleted: false,
            seq: null,
            blob: Uint8List(blobBytes),
          );

      test('splits a dirty set too large for one body', () async {
        const limits = PushLimits(maxBodyBytes: 8 * 1024);
        final server = FakeServer(advertisedLimits: limits);
        final store = InMemoryLocalRecordStore();
        // ~40 KiB of records against an 8 KiB body limit: unbatched this is
        // rejected whole, and the next round rebuilds the same request.
        for (var i = 0; i < 20; i++) {
          await store.putLocal(bulky('r$i', 1500));
        }

        final outcome = await SyncEngine(store).sync(server);

        expect(outcome.pushed, 20);
        expect(await store.dirtyRecords(), isEmpty);
        expect(server.pushedBatchSizes.length, greaterThan(1),
            reason: 'the dirty set cannot fit in one body');
        expect((await server.pull(since: 0)).records, hasLength(20));
      });

      test('splits a dirty set with more records than one push allows',
          () async {
        const limits = PushLimits(maxRecordsPerPush: 3);
        final server = FakeServer(advertisedLimits: limits);
        final store = InMemoryLocalRecordStore();
        for (var i = 0; i < 10; i++) {
          await store.putLocal(rec('r$i', 10, 'A'));
        }

        final outcome = await SyncEngine(store).sync(server);

        expect(outcome.pushed, 10);
        expect(await store.dirtyRecords(), isEmpty);
        expect(server.pushedBatchSizes, [3, 3, 3, 1]);
      });

      test('falls back to the shipped limits when none are advertised',
          () async {
        final server = FakeServer();
        final store = InMemoryLocalRecordStore();
        for (var i = 0; i < kDefaultMaxRecordsPerPush + 1; i++) {
          await store.putLocal(rec('r$i', 10, 'A'));
        }

        final outcome = await SyncEngine(store).sync(server);

        expect(outcome.pushed, kDefaultMaxRecordsPerPush + 1);
        expect(server.pushedBatchSizes, [kDefaultMaxRecordsPerPush, 1],
            reason: 'an unadvertised server still enforces what it shipped '
                'with, so the fallback has to match it');
      });

      test('a failing batch keeps the earlier batches marked synced', () async {
        const limits = PushLimits(maxRecordsPerPush: 2);
        final server = FakeServer(advertisedLimits: limits);
        final api = FailingBatchApi(server, failFromPush: 2);
        final store = InMemoryLocalRecordStore();
        for (var i = 0; i < 6; i++) {
          await store.putLocal(rec('r$i', 10, 'A'));
        }

        await expectLater(SyncEngine(store).sync(api), throwsA(isA<ApiError>()));

        // The first batch was accepted and recorded before the second left, so
        // its records are clean and the retry only carries what is still owed.
        final stillDirty =
            (await store.dirtyRecords()).map((r) => r.id).toSet();
        expect(stillDirty, hasLength(4));
        expect((await server.pull(since: 0)).records, hasLength(2));
      });

      test('a server that rejects every batch still terminates', () async {
        final api = RejectEverythingApi();
        final store = InMemoryLocalRecordStore();
        for (var i = 0; i < 5; i++) {
          await store.putLocal(rec('r$i', 10, 'A'));
        }

        final engine = SyncEngine(store, maxRounds: 3);
        final outcome = await engine.sync(api);

        // Nothing converges, but the round cap ends it: batching must not turn
        // a standing rejection into an unbounded retry loop.
        expect(outcome.pushed, 0);
        expect(outcome.rounds, 3);
        expect(await store.dirtyRecords(), hasLength(5));
      });
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
