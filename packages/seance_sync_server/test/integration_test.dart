@Timeout(Duration(seconds: 30))
library;

import 'dart:convert';

import 'package:seance_core/seance_core.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:test/test.dart';

/// End-to-end: a real server over a socket, the real HTTP client, real E2E
/// encryption, and two devices converging. This is the whole sync stack.
void main() {
  /// Start a server on an ephemeral loopback port and return its base URL. The
  /// push limits are per-test, so a test can shrink them instead of having to
  /// build a payload that exceeds the shipped 8 MiB / 1000-record defaults.
  Future<String> startServer({
    int maxBodyBytes = kDefaultMaxPushBodyBytes,
    int maxRecordsPerPush = kDefaultMaxRecordsPerPush,
    int maxBlobBytes = kDefaultMaxBlobBytes,
  }) async {
    final server = SyncServer(
      storage: InMemoryStorage(),
      // port 0 -> ephemeral; bind to loopback for the test.
      settings: ServerSettings(
        openRegistration: true,
        bindAddress: '127.0.0.1',
        port: 0,
        maxBodyBytes: maxBodyBytes,
        maxRecordsPerPush: maxRecordsPerPush,
        maxBlobBytes: maxBlobBytes,
      ),
    );
    final running = await server.start();
    addTearDown(running.close);
    return 'http://${running.host}:${running.port}';
  }

  /// Register a fresh account and return the authenticated client.
  Future<HttpSyncClient> registerDevice(String baseUrl, String username) async {
    final client = HttpSyncClient(baseUrl: baseUrl);
    addTearDown(client.close);
    await client.register(RegisterRequest(
      username: username,
      authVerifier: base64.encode(secureRandomBytes(32)),
      argonSalt: base64.encode(secureRandomBytes(16)),
      argonParams: const Argon2Params.fast(),
    ));
    return client;
  }

  /// An opaque record of roughly [blobBytes] sealed bytes. The server never
  /// looks inside a blob, so random bytes stand in for a real sealed payload.
  EncryptedRecord record(String id, {required int blobBytes}) => EncryptedRecord(
        id: id,
        updatedAt: 1,
        deviceId: 'device-A',
        deleted: false,
        seq: null,
        blob: secureRandomBytes(blobBytes),
      );

  test('two devices register/login and converge over real HTTP', () async {
    final baseUrl = await startServer();
    // Shared vault key (in reality derived from the passphrase / recovery code).
    final vaultKey = secureRandomBytes(32);
    final codec = RecordCodec(vaultKey);

    // Device A registers.
    final clientA = HttpSyncClient(baseUrl: baseUrl);
    await clientA.register(RegisterRequest(
      username: 'user',
      authVerifier: base64.encode(secureRandomBytes(32)),
      argonSalt: base64.encode(secureRandomBytes(16)),
      argonParams: const Argon2Params.fast(),
    ));
    expect(clientA.token, isNotNull);

    // Device A creates a server config record and syncs it up.
    final storeA = InMemoryLocalRecordStore();
    final cfg = ServerConfig(
      id: uuidV4(),
      label: 'prod',
      host: 'prod.example.com',
      username: 'deploy',
      createdAt: 1,
      updatedAt: 1,
    );
    await storeA.putLocal(await codec.encrypt(DecryptedRecord(
      id: cfg.id,
      kind: RecordKind.serverConfig,
      updatedAt: cfg.updatedAt,
      deviceId: 'device-A',
      data: cfg.toJson(),
    )));
    final outcomeA = await SyncEngine(storeA).sync(clientA);
    expect(outcomeA.pushed, 1);

    // Device B logs in to the same account with a fresh token…
    final clientB = HttpSyncClient(baseUrl: baseUrl);
    clientB.token = clientA.token; // same account/session for the test
    final storeB = InMemoryLocalRecordStore();
    await SyncEngine(storeB).sync(clientB);

    // …and now holds device A's record, decryptable with the shared vault key.
    final records = await storeB.allRecords();
    expect(records, hasLength(1));
    final decoded = await codec.decrypt(records.single);
    final roundTripped = ServerConfig.fromJson(decoded.data);
    expect(roundTripped.host, 'prod.example.com');
    expect(roundTripped.label, 'prod');
  });

  test('a dirty set larger than one request body converges', () async {
    // Five times the server's body limit once the 12 KiB blobs are
    // base64-encoded (~16 KiB of JSON each): unbatched, this push is rejected
    // whole and every later round repeats it identically, so the sync never
    // converges rather than merely running slowly.
    final baseUrl = await startServer(maxBodyBytes: 64 * 1024);
    final client = await registerDevice(baseUrl, 'bulky');

    final store = InMemoryLocalRecordStore();
    for (var i = 0; i < 20; i++) {
      await store.putLocal(record('r$i', blobBytes: 12 * 1024));
    }

    final outcome = await SyncEngine(store).sync(client);

    expect(outcome.pushed, 20);
    expect(await store.dirtyRecords(), isEmpty);
    final onServer = await client.pull(since: 0);
    expect(onServer.records.map((r) => r.id).toSet(),
        {for (var i = 0; i < 20; i++) 'r$i'});
  });

  test('the body limit is inclusive on both sides', () async {
    // The batcher fills a batch up to maxBodyBytes; the server refuses only
    // what exceeds it. Both halves of that "inclusive" reading are this
    // package's own, and an off-by-one between them is a 413 no retry clears.
    // Pushed directly rather than through the engine: the engine would split a
    // body one byte too large and converge anyway, hiding the disagreement.
    final records = [
      for (var i = 0; i < 4; i++) record('r$i', blobBytes: 700),
    ];
    final exactBody =
        utf8.encode(jsonEncode(PushRequest(records: records).toJson())).length;

    final atLimit = await registerDevice(
        await startServer(maxBodyBytes: exactBody), 'exact');
    final accepted = await atLimit.push(records);
    expect(accepted.results.where((r) => r.accepted), hasLength(4),
        reason: 'a body of exactly maxBodyBytes must be accepted whole');

    final overLimit = await registerDevice(
        await startServer(maxBodyBytes: exactBody - 1), 'over');
    await expectLater(
        overLimit.push(records),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'payload_too_large')),
        reason: 'one byte more than the limit must be refused, so the '
            'accepted case above is the boundary and not slack');
  });

  test('a dirty set with more records than one push allows converges',
      () async {
    final baseUrl = await startServer(maxRecordsPerPush: 3);
    final client = await registerDevice(baseUrl, 'many');

    final store = InMemoryLocalRecordStore();
    for (var i = 0; i < 10; i++) {
      await store.putLocal(record('r$i', blobBytes: 16));
    }

    final outcome = await SyncEngine(store).sync(client);

    expect(outcome.pushed, 10);
    expect(await store.dirtyRecords(), isEmpty);
    final onServer = await client.pull(since: 0);
    expect(onServer.records, hasLength(10));
  });

  test('one over-sized blob does not hold back the rest of the dirty set',
      () async {
    // The per-record blob cap is refused with the same 413 as an over-sized
    // body, but it is refused for the *whole* push: one record past the cap
    // takes every record batched beside it down with it, and since the batcher
    // is deterministic the next round rebuilds the same doomed batch. The
    // record past the cap can never be accepted — nothing local can shrink a
    // sealed blob — so the account's sync stops until the user finds and
    // deletes it. Batching the oversized record alone, and last, keeps the
    // failure to the one record that caused it.
    final baseUrl = await startServer(maxBlobBytes: 4 * 1024);
    final client = await registerDevice(baseUrl, 'oversized');

    final store = InMemoryLocalRecordStore();
    for (var i = 0; i < 5; i++) {
      await store.putLocal(record('r$i', blobBytes: 128));
    }
    await store.putLocal(record('huge', blobBytes: 8 * 1024));

    await expectLater(
      SyncEngine(store).sync(client),
      throwsA(isA<ApiError>()
          .having((e) => e.code, 'code', 'payload_too_large')),
      reason: 'the record past the blob cap can never be accepted, so the '
          'failure must still surface rather than be swallowed',
    );

    final onServer = await client.pull(since: 0);
    expect(
      onServer.records.map((r) => r.id).toSet(),
      {for (var i = 0; i < 5; i++) 'r$i'},
      reason: 'every record that fits the cap must reach the server; only the '
          'one past it stays behind',
    );
    expect(
      (await store.dirtyRecords()).map((r) => r.id),
      ['huge'],
      reason: 'and only that record stays dirty, so the next round retries it '
          'alone instead of rebuilding a doomed batch',
    );
  });

  test('server rejects a bad login verifier over HTTP', () async {
    final baseUrl = await startServer();
    final client = HttpSyncClient(baseUrl: baseUrl);
    final verifier = base64.encode(secureRandomBytes(32));
    await client.register(RegisterRequest(
      username: 'someone',
      authVerifier: verifier,
      argonSalt: base64.encode(secureRandomBytes(16)),
      argonParams: const Argon2Params.fast(),
    ));

    final other = HttpSyncClient(baseUrl: baseUrl);
    await expectLater(
      other.login(LoginRequest(
          username: 'someone',
          authVerifier: base64.encode(secureRandomBytes(32)))),
      throwsA(isA<ApiError>()),
    );
  });
}
