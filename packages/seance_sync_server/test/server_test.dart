import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Drives the shelf handler directly — no sockets, fully deterministic.
class TestClient {
  final Handler handler;
  String? token;
  TestClient(this.handler);

  Future<(int, Map<String, dynamic>)> send(
    String method,
    String path, {
    Object? body,
    bool auth = false,
    Map<String, String> query = const {},
  }) async {
    final uri = Uri.parse('http://localhost$path').replace(
        queryParameters: query.isEmpty ? null : query);
    final req = Request(
      method,
      uri,
      headers: {
        'content-type': 'application/json',
        if (auth && token != null) 'authorization': 'Bearer $token',
      },
      body: body == null ? null : jsonEncode(body),
    );
    final res = await handler(req);
    final text = await res.readAsString();
    Map<String, dynamic> json;
    try {
      final decoded = text.isEmpty ? null : jsonDecode(text);
      json = decoded is Map<String, dynamic> ? decoded : {'raw': text};
    } on FormatException {
      json = {'raw': text}; // non-JSON body (e.g. healthz "ok")
    }
    return (res.statusCode, json);
  }
}

RegisterRequest registerReq(String user) => RegisterRequest(
      username: user,
      authVerifier: base64.encode(secureRandomBytes(32)),
      argonSalt: base64.encode(secureRandomBytes(16)),
      argonParams: const Argon2Params(),
    );

EncryptedRecord rec(String id, int updatedAt, String device) =>
    EncryptedRecord(
      id: id,
      updatedAt: updatedAt,
      deviceId: device,
      deleted: false,
      seq: null,
      blob: Uint8List.fromList(utf8.encode('sealed-$id')),
    );

void main() {
  SyncServer makeServer({bool openRegistration = true}) => SyncServer(
        storage: InMemoryStorage(),
        settings: ServerSettings(openRegistration: openRegistration),
      );

  group('health + registration', () {
    test('healthz is 200', () async {
      final c = TestClient(makeServer().handler);
      final (status, _) = await c.send('GET', '/healthz');
      expect(status, 200);
    });

    test('register returns a token and rejects duplicates', () async {
      final c = TestClient(makeServer().handler);
      final (s1, b1) = await c.send('POST', '/v1/register',
          body: registerReq('alice').toJson());
      expect(s1, 200);
      expect(b1['token'], isNotEmpty);

      final (s2, b2) = await c.send('POST', '/v1/register',
          body: registerReq('alice').toJson());
      expect(s2, 409);
      expect(b2['error'], 'account_exists');
    });

    test('registration refused when closed', () async {
      final c = TestClient(makeServer(openRegistration: false).handler);
      final (status, body) = await c.send('POST', '/v1/register',
          body: registerReq('bob').toJson());
      expect(status, 403);
      expect(body['error'], 'registration_closed');
    });

    test('rejects a protocol-version mismatch', () async {
      final c = TestClient(makeServer().handler);
      final payload = registerReq('carol').toJson()..['protocolVersion'] = 999;
      final (status, body) =
          await c.send('POST', '/v1/register', body: payload);
      expect(status, 400);
      expect(body['error'], 'protocol_version');
    });
  });

  group('auth', () {
    test('login succeeds with the same verifier and fails with a wrong one',
        () async {
      final server = makeServer();
      final c = TestClient(server.handler);
      final req = registerReq('dave');
      await c.send('POST', '/v1/register', body: req.toJson());

      final (okStatus, okBody) = await c.send('POST', '/v1/login',
          body: LoginRequest(username: 'dave', authVerifier: req.authVerifier)
              .toJson());
      expect(okStatus, 200);
      expect(okBody['token'], isNotEmpty);

      final (badStatus, badBody) = await c.send('POST', '/v1/login',
          body: LoginRequest(
                  username: 'dave',
                  authVerifier: base64.encode(secureRandomBytes(32)))
              .toJson());
      expect(badStatus, 401);
      expect(badBody['error'], 'invalid_credentials');
    });

    test('prelogin returns the KDF salt/params for a new device', () async {
      final c = TestClient(makeServer().handler);
      final req = registerReq('erin');
      await c.send('POST', '/v1/register', body: req.toJson());
      final (status, body) =
          await c.send('POST', '/v1/prelogin', body: {'username': 'erin'});
      expect(status, 200);
      expect(body['argonSalt'], req.argonSalt);
      expect(body['argonParams']['memory'], 19456);
    });

    test('protected routes require a valid bearer token', () async {
      final c = TestClient(makeServer().handler);
      final (status, body) =
          await c.send('GET', '/v1/sync', query: {'since': '0'});
      expect(status, 401);
      expect(body['error'], 'unauthorized');
    });

    test('login rate limiting kicks in', () async {
      final server = SyncServer(
        storage: InMemoryStorage(),
        settings: const ServerSettings(openRegistration: true),
        loginLimiter: RateLimiter(maxAttempts: 3, window: const Duration(minutes: 1)),
      );
      final c = TestClient(server.handler);
      await c.send('POST', '/v1/register', body: registerReq('frank').toJson());
      final wrong = LoginRequest(
              username: 'frank',
              authVerifier: base64.encode(secureRandomBytes(32)))
          .toJson();
      // 3 allowed attempts (401), then throttled (429).
      expect((await c.send('POST', '/v1/login', body: wrong)).$1, 401);
      expect((await c.send('POST', '/v1/login', body: wrong)).$1, 401);
      expect((await c.send('POST', '/v1/login', body: wrong)).$1, 401);
      expect((await c.send('POST', '/v1/login', body: wrong)).$1, 429);
    });
  });

  group('records', () {
    Future<TestClient> authed(SyncServer server, String user) async {
      final c = TestClient(server.handler);
      final (_, body) =
          await c.send('POST', '/v1/register', body: registerReq(user).toJson());
      c.token = body['token'] as String;
      return c;
    }

    test('push assigns sequence numbers and pull returns them', () async {
      final server = makeServer();
      final c = await authed(server, 'grace');

      final (pStatus, pBody) = await c.send('PUT', '/v1/records',
          auth: true,
          body: PushRequest(records: [rec('a', 10, 'd1'), rec('b', 11, 'd1')])
              .toJson());
      expect(pStatus, 200);
      final push = PushResponse.fromJson(pBody);
      expect(push.results.every((r) => r.accepted), isTrue);
      expect(push.latestSeq, 2);

      final (sStatus, sBody) =
          await c.send('GET', '/v1/sync', auth: true, query: {'since': '0'});
      expect(sStatus, 200);
      final pull = PullResponse.fromJson(sBody);
      expect(pull.records.map((r) => r.id).toSet(), {'a', 'b'});
      expect(pull.latestSeq, 2);
    });

    test('since filter returns only newer records', () async {
      final server = makeServer();
      final c = await authed(server, 'heidi');
      await c.send('PUT', '/v1/records',
          auth: true, body: PushRequest(records: [rec('a', 10, 'd1')]).toJson());
      await c.send('PUT', '/v1/records',
          auth: true, body: PushRequest(records: [rec('b', 11, 'd1')]).toJson());

      final (_, body) =
          await c.send('GET', '/v1/sync', auth: true, query: {'since': '1'});
      final pull = PullResponse.fromJson(body);
      expect(pull.records.map((r) => r.id), ['b']); // only seq > 1
    });

    test('an older concurrent push is rejected by LWW', () async {
      final server = makeServer();
      final c = await authed(server, 'ivan');
      // Newer version stored first.
      await c.send('PUT', '/v1/records',
          auth: true,
          body: PushRequest(records: [rec('x', 100, 'd1')]).toJson());
      // Older version loses.
      final (_, body) = await c.send('PUT', '/v1/records',
          auth: true, body: PushRequest(records: [rec('x', 50, 'd2')]).toJson());
      final push = PushResponse.fromJson(body);
      expect(push.results.single.accepted, isFalse);
    });

    test('records are isolated per account', () async {
      final server = makeServer();
      final a = await authed(server, 'judy');
      final b = await authed(server, 'ken');
      await a.send('PUT', '/v1/records',
          auth: true, body: PushRequest(records: [rec('a', 1, 'd')]).toJson());

      final (_, body) =
          await b.send('GET', '/v1/sync', auth: true, query: {'since': '0'});
      expect(PullResponse.fromJson(body).records, isEmpty);
    });

    test('deleting the account clears its data and token', () async {
      final server = makeServer();
      final c = await authed(server, 'laura');
      await c.send('PUT', '/v1/records',
          auth: true, body: PushRequest(records: [rec('a', 1, 'd')]).toJson());
      final (delStatus, _) = await c.send('DELETE', '/v1/account', auth: true);
      expect(delStatus, 200);
      // Token is now invalid.
      final (afterStatus, _) =
          await c.send('GET', '/v1/sync', auth: true, query: {'since': '0'});
      expect(afterStatus, 401);
    });
  });
}
