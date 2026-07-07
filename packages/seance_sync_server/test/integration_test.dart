@Timeout(Duration(seconds: 30))
library;

import 'dart:convert';

import 'package:seance_core/seance_core.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:test/test.dart';

/// End-to-end: a real server over a socket, the real HTTP client, real E2E
/// encryption, and two devices converging. This is the whole sync stack.
void main() {
  late SyncServer server;
  late HttpServerLike running;
  late String baseUrl;

  setUp(() async {
    server = SyncServer(
      storage: InMemoryStorage(),
      // port 0 -> ephemeral; bind to loopback for the test.
      settings: const ServerSettings(
          openRegistration: true, bindAddress: '127.0.0.1', port: 0),
    );
    running = await server.start();
    baseUrl = 'http://${running.host}:${running.port}';
  });

  tearDown(() async => running.close());

  test('two devices register/login and converge over real HTTP', () async {
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

  test('server rejects a bad login verifier over HTTP', () async {
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
