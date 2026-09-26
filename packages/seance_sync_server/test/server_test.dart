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
    final uri = Uri.parse(
      'http://localhost$path',
    ).replace(queryParameters: query.isEmpty ? null : query);
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

class ThrowingStorage extends InMemoryStorage {
  @override
  Future<Account?> getAccount(String username) async {
    throw StateError('database password is hunter2');
  }
}

/// Remembers every key it is asked about, so a test can prove what never
/// became one.
class RecordingRateLimiter extends RateLimiter {
  final keys = <String>[];

  @override
  bool allow(String key) {
    keys.add(key);
    return super.allow(key);
  }
}

RegisterRequest registerReq(String user) => RegisterRequest(
  username: user,
  authVerifier: base64.encode(secureRandomBytes(32)),
  argonSalt: base64.encode(secureRandomBytes(16)),
  argonParams: const Argon2Params(),
);

EncryptedRecord rec(String id, int updatedAt, String device) => EncryptedRecord(
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

  group('settings from the environment', () {
    test('a non-positive push limit refuses to start', () {
      for (final key in const [
        'SEANCE_MAX_BODY_BYTES',
        'SEANCE_MAX_RECORDS_PER_PUSH',
        'SEANCE_MAX_BLOB_BYTES',
      ]) {
        for (final value in const ['0', '-1']) {
          // Silently advertising a cap no push can satisfy would surface as
          // every sync failing with an opaque 413. The error names the
          // variable, which is the whole point of failing at startup.
          expect(
              () => ServerSettings.fromEnvironment({key: value}),
              throwsA(isA<ArgumentError>()
                  .having((e) => e.name, 'name', key)),
              reason: '$key=$value');
        }
      }
    });

    test('a limit set to something unparseable refuses to start', () {
      // A typo is not an intent: silently defaulting would run a cap other
      // than the one the operator asked for.
      for (final key in const [
        'SEANCE_MAX_BODY_BYTES',
        'SEANCE_MAX_RECORDS_PER_PUSH',
        'SEANCE_MAX_BLOB_BYTES',
      ]) {
        for (final value in const ['lots', '4096b', '1_000_000']) {
          expect(
              () => ServerSettings.fromEnvironment({key: value}),
              throwsA(isA<ArgumentError>()
                  .having((e) => e.name, 'name', key)),
              reason: '$key=$value');
        }
      }
    });

    test('unset limits keep the shipped defaults', () {
      final settings = ServerSettings.fromEnvironment(const {});
      expect(settings.pushLimits, const PushLimits());
      expect(settings.maxBlobBytes, 1024 * 1024);
    });

    test('an empty value means unset and keeps the default', () {
      // `KEY=` in an env file, an empty Compose interpolation and an empty
      // ConfigMap entry all arrive this way, and all mean "unset".
      for (final value in const ['', '  ']) {
        final settings = ServerSettings.fromEnvironment({
          'SEANCE_MAX_BODY_BYTES': value,
          'SEANCE_MAX_RECORDS_PER_PUSH': value,
          'SEANCE_MAX_BLOB_BYTES': value,
        });
        expect(settings.maxBodyBytes, kDefaultMaxPushBodyBytes);
        expect(settings.maxRecordsPerPush, kDefaultMaxRecordsPerPush);
        expect(settings.maxBlobBytes, 1024 * 1024);
      }
    });

    test('surrounding whitespace is not a typo', () {
      // Env files pick up trailing newlines; that must not stop the server.
      final settings = ServerSettings.fromEnvironment(
          const {'SEANCE_MAX_BODY_BYTES': ' 4096\n'});
      expect(settings.maxBodyBytes, 4096);
    });

    test('valid overrides are parsed and advertised, leaving others alone', () {
      final settings = ServerSettings.fromEnvironment(const {
        'SEANCE_MAX_BODY_BYTES': '4096',
        'SEANCE_MAX_RECORDS_PER_PUSH': '7',
      });
      expect(settings.pushLimits,
          const PushLimits(maxBodyBytes: 4096, maxRecordsPerPush: 7));
      expect(settings.maxBlobBytes, 1024 * 1024,
          reason: 'overriding one cap must not disturb another');
    });

    test('the blob cap is read too, not only validated', () {
      // The other tests here only prove this key is rejected when invalid.
      final settings = ServerSettings.fromEnvironment(
          const {'SEANCE_MAX_BLOB_BYTES': '2048'});
      expect(settings.maxBlobBytes, 2048);
      // Advertised along with the other two: a client that does not know this
      // deployment's blob cap batches a record past it beside records that
      // would have been accepted, and the 413 takes all of them.
      expect(settings.pushLimits, const PushLimits(maxBlobBytes: 2048));
    });
  });

  group('health + registration', () {
    test('healthz is 200', () async {
      final c = TestClient(makeServer().handler);
      final (status, _) = await c.send('GET', '/healthz');
      expect(status, 200);
    });

    test('landing page and favicon are served for browsers', () async {
      final handler = makeServer().handler;
      final home = await handler(
        Request('GET', Uri.parse('http://localhost/')),
      );
      expect(home.statusCode, 200);
      expect(home.headers['content-type'], contains('text/html'));
      expect(await home.readAsString(), contains('Séance sync server'));

      final icon = await handler(
        Request('GET', Uri.parse('http://localhost/favicon.ico')),
      );
      expect(icon.statusCode, 200);
      expect(icon.headers['content-type'], 'image/png');
      final bytes = await icon.read().expand((b) => b).toList();
      // PNG magic bytes — the embedded base64 decoded to a real image.
      expect(bytes.length, greaterThan(1000));
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('register returns a token and rejects duplicates', () async {
      final c = TestClient(makeServer().handler);
      final (s1, b1) = await c.send(
        'POST',
        '/v1/register',
        body: registerReq('alice').toJson(),
      );
      expect(s1, 200);
      expect(b1['token'], isNotEmpty);

      final (s2, b2) = await c.send(
        'POST',
        '/v1/register',
        body: registerReq('alice').toJson(),
      );
      expect(s2, 409);
      expect(b2['error'], 'account_exists');
    });

    test('registration refused when closed', () async {
      final c = TestClient(makeServer(openRegistration: false).handler);
      final (status, body) = await c.send(
        'POST',
        '/v1/register',
        body: registerReq('bob').toJson(),
      );
      expect(status, 403);
      expect(body['error'], 'registration_closed');
    });

    test('rejects a protocol-version mismatch', () async {
      final c = TestClient(makeServer().handler);
      final payload = registerReq('carol').toJson()..['protocolVersion'] = 999;
      final (status, body) = await c.send(
        'POST',
        '/v1/register',
        body: payload,
      );
      expect(status, 400);
      expect(body['error'], 'protocol_version');
    });

    test('rejects malformed register verifier as a bad request', () async {
      final c = TestClient(makeServer().handler);
      final payload = registerReq('bad-register').toJson()
        ..['authVerifier'] = 'not base64!';
      final (status, body) = await c.send(
        'POST',
        '/v1/register',
        body: payload,
      );
      expect(status, 400);
      expect(body['error'], 'bad_request');
    });

    test('internal errors do not leak exception details', () async {
      final server = SyncServer(
        storage: ThrowingStorage(),
        settings: const ServerSettings(openRegistration: true),
      );
      final c = TestClient(server.handler);
      final (status, body) = await c.send(
        'POST',
        '/v1/register',
        body: registerReq('leaky').toJson(),
      );
      expect(status, 500);
      expect(body['error'], 'internal_error');
      expect(body['message'], 'Internal server error');
      expect(jsonEncode(body), isNot(contains('hunter2')));
    });
  });

  group('auth', () {
    test(
      'login succeeds with the same verifier and fails with a wrong one',
      () async {
        final server = makeServer();
        final c = TestClient(server.handler);
        final req = registerReq('dave');
        await c.send('POST', '/v1/register', body: req.toJson());

        final (okStatus, okBody) = await c.send(
          'POST',
          '/v1/login',
          body: LoginRequest(
            username: 'dave',
            authVerifier: req.authVerifier,
          ).toJson(),
        );
        expect(okStatus, 200);
        expect(okBody['token'], isNotEmpty);

        final (badStatus, badBody) = await c.send(
          'POST',
          '/v1/login',
          body: LoginRequest(
            username: 'dave',
            authVerifier: base64.encode(secureRandomBytes(32)),
          ).toJson(),
        );
        expect(badStatus, 401);
        expect(badBody['error'], 'invalid_credentials');
      },
    );

    test('prelogin returns the KDF salt/params for a new device', () async {
      final c = TestClient(makeServer().handler);
      final req = registerReq('erin');
      await c.send('POST', '/v1/register', body: req.toJson());
      final (status, body) = await c.send(
        'POST',
        '/v1/prelogin',
        body: {'username': 'erin'},
      );
      expect(status, 200);
      expect(body['argonSalt'], req.argonSalt);
      expect(body['argonParams']['memory'], 19456);
    });

    test('protected routes require a valid bearer token', () async {
      final c = TestClient(makeServer().handler);
      final (status, body) = await c.send(
        'GET',
        '/v1/sync',
        query: {'since': '0'},
      );
      expect(status, 401);
      expect(body['error'], 'unauthorized');
    });

    test('login rate limiting kicks in', () async {
      final server = SyncServer(
        storage: InMemoryStorage(),
        settings: const ServerSettings(openRegistration: true),
        loginLimiter: RateLimiter(
          maxAttempts: 3,
          window: const Duration(minutes: 1),
        ),
      );
      final c = TestClient(server.handler);
      await c.send('POST', '/v1/register', body: registerReq('frank').toJson());
      final wrong = LoginRequest(
        username: 'frank',
        authVerifier: base64.encode(secureRandomBytes(32)),
      ).toJson();
      // 3 allowed attempts (401), then throttled (429).
      expect((await c.send('POST', '/v1/login', body: wrong)).$1, 401);
      expect((await c.send('POST', '/v1/login', body: wrong)).$1, 401);
      expect((await c.send('POST', '/v1/login', body: wrong)).$1, 401);
      expect((await c.send('POST', '/v1/login', body: wrong)).$1, 429);
    });

    test('rejects malformed login verifier as a bad request', () async {
      final c = TestClient(makeServer().handler);
      await c.send('POST', '/v1/register', body: registerReq('gary').toJson());
      final (status, body) = await c.send(
        'POST',
        '/v1/login',
        body: {'username': 'gary', 'authVerifier': 'not base64!'},
      );
      expect(status, 400);
      expect(body['error'], 'bad_request');
    });
  });

  group('records', () {
    Future<TestClient> authed(SyncServer server, String user) async {
      final c = TestClient(server.handler);
      final (_, body) = await c.send(
        'POST',
        '/v1/register',
        body: registerReq(user).toJson(),
      );
      c.token = body['token'] as String;
      return c;
    }

    test('push assigns sequence numbers and pull returns them', () async {
      final server = makeServer();
      final c = await authed(server, 'grace');

      final (pStatus, pBody) = await c.send(
        'PUT',
        '/v1/records',
        auth: true,
        body: PushRequest(
          records: [rec('a', 10, 'd1'), rec('b', 11, 'd1')],
        ).toJson(),
      );
      expect(pStatus, 200);
      final push = PushResponse.fromJson(pBody);
      expect(push.results.every((r) => r.accepted), isTrue);
      expect(push.latestSeq, 2);

      final (sStatus, sBody) = await c.send(
        'GET',
        '/v1/sync',
        auth: true,
        query: {'since': '0'},
      );
      expect(sStatus, 200);
      final pull = PullResponse.fromJson(sBody);
      expect(pull.records.map((r) => r.id).toSet(), {'a', 'b'});
      expect(pull.latestSeq, 2);
    });

    test('a pull advertises this deployment\'s push limits', () async {
      // Env-tunable, so a client cannot infer them: it sizes its push batches
      // from what the pull it just made told it.
      final server = SyncServer(
        storage: InMemoryStorage(),
        settings: const ServerSettings(
          openRegistration: true,
          maxBodyBytes: 4096,
          maxRecordsPerPush: 7,
        ),
      );
      final c = await authed(server, 'limits');

      final (status, body) = await c.send(
        'GET',
        '/v1/sync',
        auth: true,
        query: {'since': '0'},
      );

      expect(status, 200);
      expect(PullResponse.fromJson(body).limits,
          const PushLimits(maxBodyBytes: 4096, maxRecordsPerPush: 7));
    });

    test('since filter returns only newer records', () async {
      final server = makeServer();
      final c = await authed(server, 'heidi');
      await c.send(
        'PUT',
        '/v1/records',
        auth: true,
        body: PushRequest(records: [rec('a', 10, 'd1')]).toJson(),
      );
      await c.send(
        'PUT',
        '/v1/records',
        auth: true,
        body: PushRequest(records: [rec('b', 11, 'd1')]).toJson(),
      );

      final (_, body) = await c.send(
        'GET',
        '/v1/sync',
        auth: true,
        query: {'since': '1'},
      );
      final pull = PullResponse.fromJson(body);
      expect(pull.records.map((r) => r.id), ['b']); // only seq > 1
    });

    test('an older concurrent push is rejected by LWW', () async {
      final server = makeServer();
      final c = await authed(server, 'ivan');
      // Newer version stored first.
      await c.send(
        'PUT',
        '/v1/records',
        auth: true,
        body: PushRequest(records: [rec('x', 100, 'd1')]).toJson(),
      );
      // Older version loses.
      final (_, body) = await c.send(
        'PUT',
        '/v1/records',
        auth: true,
        body: PushRequest(records: [rec('x', 50, 'd2')]).toJson(),
      );
      final push = PushResponse.fromJson(body);
      expect(push.results.single.accepted, isFalse);
    });

    test('records are isolated per account', () async {
      final server = makeServer();
      final a = await authed(server, 'judy');
      final b = await authed(server, 'ken');
      await a.send(
        'PUT',
        '/v1/records',
        auth: true,
        body: PushRequest(records: [rec('a', 1, 'd')]).toJson(),
      );

      final (_, body) = await b.send(
        'GET',
        '/v1/sync',
        auth: true,
        query: {'since': '0'},
      );
      expect(PullResponse.fromJson(body).records, isEmpty);
    });

    test('deleting the account clears its data and token', () async {
      final server = makeServer();
      final c = await authed(server, 'laura');
      await c.send(
        'PUT',
        '/v1/records',
        auth: true,
        body: PushRequest(records: [rec('a', 1, 'd')]).toJson(),
      );
      final (delStatus, _) = await c.send('DELETE', '/v1/account', auth: true);
      expect(delStatus, 200);
      // Token is now invalid.
      final (afterStatus, _) = await c.send(
        'GET',
        '/v1/sync',
        auth: true,
        query: {'since': '0'},
      );
      expect(afterStatus, 401);
    });
  });

  group('request limits', () {
    test('rejects an oversized request body with 413', () async {
      final server = SyncServer(
        storage: InMemoryStorage(),
        settings: const ServerSettings(
            openRegistration: true, maxBodyBytes: 200),
      );
      final c = TestClient(server.handler);
      // A register payload padded well past the 200-byte cap.
      final (status, body) = await c.send(
        'POST',
        '/v1/register',
        body: registerReq('a' * 500).toJson(),
      );
      expect(status, 413);
      expect(body['error'], 'payload_too_large');
    });

    test('rejects too many records and oversized blobs in a push', () async {
      final server = SyncServer(
        storage: InMemoryStorage(),
        settings: const ServerSettings(
            openRegistration: true, maxRecordsPerPush: 1, maxBlobBytes: 8),
      );
      final c = TestClient(server.handler);
      final (_, reg) =
          await c.send('POST', '/v1/register', body: registerReq('bob').toJson());
      c.token = reg['token'] as String;

      final (tooMany, b1) = await c.send(
        'PUT',
        '/v1/records',
        auth: true,
        body: PushRequest(records: [rec('x', 1, 'd'), rec('y', 2, 'd')]).toJson(),
      );
      expect(tooMany, 413);
      expect(b1['error'], 'payload_too_large');

      // A single record whose blob ('sealed-toolongid' = 16 bytes) exceeds 8.
      final (tooBig, b2) = await c.send(
        'PUT',
        '/v1/records',
        auth: true,
        body: PushRequest(records: [rec('toolongid', 1, 'd')]).toJson(),
      );
      expect(tooBig, 413);
      expect(b2['error'], 'payload_too_large');

      final (_, after) = await c.send('GET', '/v1/sync', auth: true);
      expect(after['latestSeq'], 0);
      expect(after['records'], isEmpty);
    });
  });

  group('unauthenticated input bounds', () {
    /// Posts [bytes] verbatim. Unless [declareLength], they arrive as a
    /// chunked stream with no Content-Length, so only the cap applied while
    /// reading stands between the body and memory.
    Future<(int, Map<String, dynamic>)> postRaw(
      Handler handler,
      String path,
      List<int> bytes, {
      bool declareLength = true,
    }) async {
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost$path'),
          headers: {'content-type': 'application/json'},
          body: declareLength
              ? bytes
              : Stream.fromIterable([
                  for (var i = 0; i < bytes.length; i += 1024)
                    bytes.sublist(i, (i + 1024).clamp(0, bytes.length)),
                ]),
        ),
      );
      return (
        res.statusCode,
        jsonDecode(await res.readAsString()) as Map<String, dynamic>,
      );
    }

    test('an auth body past 16 KiB is refused on every auth route', () async {
      // Well-formed JSON, so only the size can refuse it. These routes run
      // before any authentication, yet the whole default push cap was
      // theirs to fill.
      final padded = utf8.encode(
        jsonEncode({
          ...registerReq('mallory').toJson(),
          'authVerifier': 'A' * (17 * 1024),
        }),
      );
      for (final path in const ['/v1/register', '/v1/prelogin', '/v1/login']) {
        for (final declareLength in const [true, false]) {
          final (status, body) = await postRaw(
            makeServer().handler,
            path,
            padded,
            declareLength: declareLength,
          );
          expect(status, 413, reason: '$path, declared: $declareLength');
          expect(body['error'], 'payload_too_large');
        }
      }
    });

    test('a push past the auth cap still fits the push cap', () async {
      final c = TestClient(makeServer().handler);
      final (_, reg) = await c.send(
        'POST',
        '/v1/register',
        body: registerReq('pusher').toJson(),
      );
      c.token = reg['token'] as String;
      final big = EncryptedRecord(
        id: 'big',
        updatedAt: 1,
        deviceId: 'd',
        deleted: false,
        seq: null,
        blob: secureRandomBytes(32 * 1024),
      );

      final (status, body) = await c.send(
        'PUT',
        '/v1/records',
        auth: true,
        body: PushRequest(records: [big]).toJson(),
      );

      expect(status, 200);
      expect(PushResponse.fromJson(body).results.single.accepted, isTrue);
    });

    test('registration refuses empty, overlong and control-character '
        'usernames', () async {
      final storage = InMemoryStorage();
      final c = TestClient(
        SyncServer(
          storage: storage,
          settings: const ServerSettings(openRegistration: true),
        ).handler,
      );
      final refused = {
        'empty': '',
        'NUL': 'a\u0000b',
        'tab': 'a\tb',
        'newline': 'a\nb',
        'DEL': 'a\u007fb',
        'C1': 'a\u0085b',
        'soft hyphen': 'a\u00adb',
        'zero-width space': 'a\u200bb',
        'right-to-left override': 'a\u202eb',
        'word joiner': 'a\u2060b',
        'byte-order mark': '\ufeffab',
        '257 ASCII bytes': 'a' * 257,
        '258 UTF-8 bytes': 'é' * 129,
      };
      for (final MapEntry(key: label, value: name) in refused.entries) {
        final (status, body) = await c.send(
          'POST',
          '/v1/register',
          body: registerReq(name).toJson(),
        );
        expect(status, 400, reason: label);
        expect(body['error'], 'bad_username', reason: label);
        expect(await storage.getAccount(name), isNull, reason: label);
      }

      // The limit is in bytes, and inclusive.
      for (final name in ['a' * 256, 'é' * 128, 'Zoë van der Berg']) {
        final (status, _) = await c.send(
          'POST',
          '/v1/register',
          body: registerReq(name).toJson(),
        );
        expect(status, 200, reason: name);
      }
    });

    test(
      'a username that is not a string is a bad request, not a crash',
      () async {
        final c = TestClient(makeServer().handler);
        for (final username in <Object?>[
          null,
          5,
          true,
          <String, Object>{},
          [],
        ]) {
          for (final (path, body) in [
            ('/v1/register', registerReq('x').toJson()),
            ('/v1/prelogin', <String, dynamic>{}),
            (
              '/v1/login',
              LoginRequest(username: 'x', authVerifier: '').toJson(),
            ),
          ]) {
            final (status, response) = await c.send(
              'POST',
              path,
              body: {...body, 'username': username},
            );
            expect(status, 400, reason: '$path with $username');
            expect(
              response['error'],
              'bad_request',
              reason: '$path with $username',
            );
          }
        }
      },
    );

    test('login and prelogin refuse an out-of-bounds username before the '
        'limiter sees it', () async {
      final limiter = RecordingRateLimiter();
      final c = TestClient(
        SyncServer(
          storage: InMemoryStorage(),
          settings: const ServerSettings(openRegistration: true),
          loginLimiter: limiter,
        ).handler,
      );
      for (final name in ['', 'a' * 257, 'é' * 129]) {
        final (preStatus, pre) = await c.send(
          'POST',
          '/v1/prelogin',
          body: {'username': name},
        );
        expect(preStatus, 400);
        expect(pre['error'], 'bad_username');

        final (loginStatus, login) = await c.send(
          'POST',
          '/v1/login',
          body: LoginRequest(
            username: name,
            authVerifier: base64.encode(secureRandomBytes(32)),
          ).toJson(),
        );
        expect(loginStatus, 400);
        expect(login['error'], 'bad_username');
      }
      // Its keys outlive the request by a whole window.
      expect(limiter.keys, isEmpty);
    });

    test(
      'an account registered before the username rule can still sign in',
      () async {
        // Nothing checked names before, so a stored one may hold a character a
        // new registration is refused (a pasted tab, say). Login and prelogin
        // only bound the length.
        final storage = InMemoryStorage();
        const legacy = 'old\taccount';
        final verifier = secureRandomBytes(32);
        final verifierSalt = secureRandomBytes(16);
        final argonSalt = base64.encode(secureRandomBytes(16));
        await storage.createAccount(
          Account(
            username: legacy,
            authVerifierHash: VaultCrypto.hashAuthVerifier(
              verifier,
              verifierSalt,
            ),
            verifierSalt: base64.encode(verifierSalt),
            argonSalt: argonSalt,
            argonParams: const Argon2Params(),
          ),
        );
        final c = TestClient(
          SyncServer(
            storage: storage,
            settings: const ServerSettings(),
          ).handler,
        );

        final (preStatus, pre) = await c.send(
          'POST',
          '/v1/prelogin',
          body: {'username': legacy},
        );
        expect(preStatus, 200);
        expect(pre['argonSalt'], argonSalt);

        final (loginStatus, login) = await c.send(
          'POST',
          '/v1/login',
          body: LoginRequest(
            username: legacy,
            authVerifier: base64.encode(verifier),
          ).toJson(),
        );
        expect(loginStatus, 200);
        expect(login['token'], isNotEmpty);
      },
    );

    test(
      'registration refuses a salt or verifier of the wrong shape',
      () async {
        final storage = InMemoryStorage();
        final c = TestClient(
          SyncServer(
            storage: storage,
            settings: const ServerSettings(openRegistration: true),
          ).handler,
        );
        String bytes(int n) => base64.encode(secureRandomBytes(n));
        final refused = {
          'empty verifier': {'authVerifier': ''},
          '31-byte verifier': {'authVerifier': bytes(31)},
          '33-byte verifier': {'authVerifier': bytes(33)},
          'empty salt': {'argonSalt': ''},
          '15-byte salt': {'argonSalt': bytes(15)},
          'salt not base64': {'argonSalt': 'not base64!'},
        };
        for (final MapEntry(key: label, value: override) in refused.entries) {
          final (status, body) = await c.send(
            'POST',
            '/v1/register',
            body: {...registerReq('shape').toJson(), ...override},
          );
          expect(status, 400, reason: label);
          expect(body['error'], 'bad_request', reason: label);
          expect(await storage.getAccount('shape'), isNull, reason: label);
        }

        // A longer salt is still a valid Argon2 salt.
        final (status, _) = await c.send(
          'POST',
          '/v1/register',
          body: {...registerReq('shape').toJson(), 'argonSalt': bytes(32)},
        );
        expect(status, 200);

        // A malformed payload is refused before the name is looked up, so
        // it cannot tell a taken name from a free one.
        final (takenStatus, takenBody) = await c.send(
          'POST',
          '/v1/register',
          body: {...registerReq('shape').toJson(), 'authVerifier': bytes(31)},
        );
        expect(takenStatus, 400);
        expect(takenBody['error'], 'bad_request');
      },
    );
  });
}
