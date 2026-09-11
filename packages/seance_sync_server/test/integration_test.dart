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
    int maxBodyBytes = 8 * 1024 * 1024,
    int maxRecordsPerPush = 1000,
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
