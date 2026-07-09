import 'dart:async';
import 'dart:convert';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'favicon.dart';
import 'rate_limiter.dart';
import 'storage.dart';

/// The Séance sync server. A dumb, breach-tolerant blob store: it authenticates
/// devices, stores end-to-end encrypted records, and resolves conflicts with
/// the same last-write-wins rule the client uses. It can decrypt nothing.
class SyncServer {
  final Storage storage;
  final ServerSettings settings;
  final RateLimiter loginLimiter;

  SyncServer({
    required this.storage,
    required this.settings,
    RateLimiter? loginLimiter,
  }) : loginLimiter =
           loginLimiter ??
           RateLimiter(
             maxAttempts: settings.loginMaxAttempts,
             window: settings.loginWindow,
           );

  Handler get handler {
    final router = Router()
      ..get('/healthz', (Request r) => Response.ok('ok'))
      // A browser hitting the server sees what it is instead of a 404 (the
      // API itself lives under /v1/); the favicon is embedded in the binary.
      ..get(
        '/',
        (Request r) => Response.ok(
          _landingPage,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      )
      ..get(
        '/favicon.ico',
        (Request r) =>
            Response.ok(faviconPng, headers: {'content-type': 'image/png'}),
      )
      ..post('/v1/register', _register)
      ..post('/v1/prelogin', _prelogin)
      ..post('/v1/login', _login)
      ..get('/v1/sync', _sync)
      ..put('/v1/records', _push)
      ..delete('/v1/account', _deleteAccount);

    return const Pipeline()
        .addMiddleware(_errorToJson())
        .addHandler(router.call);
  }

  Future<HttpServerLike> start() async {
    final server = await shelf_io.serve(
      handler,
      settings.bindAddress,
      settings.port,
      poweredByHeader: null,
    );
    return HttpServerLike(
      server.address.host,
      server.port,
      () => server.close(force: true),
    );
  }

  // --- Handlers ---

  Future<Response> _register(Request req) async {
    final body = await _readJson(req);
    if (body == null) return _error(400, 'bad_request', 'Malformed JSON');
    final RegisterRequest r;
    try {
      r = RegisterRequest.fromJson(body);
    } catch (_) {
      return _error(400, 'bad_request', 'Invalid register payload');
    }
    if (r.protocolVersion != kProtocolVersion) {
      return _error(
        400,
        'protocol_version',
        'Client protocol v${r.protocolVersion} != server v$kProtocolVersion',
      );
    }
    if (!settings.openRegistration) {
      return _error(403, 'registration_closed', 'Registration is disabled');
    }
    if (await storage.getAccount(r.username) != null) {
      return _error(409, 'account_exists', 'Username already registered');
    }
    final authVerifier = _tryBase64Decode(r.authVerifier);
    if (authVerifier == null) {
      return _error(400, 'bad_request', 'Invalid register payload');
    }
    final verifierSalt = secureRandomBytes(16);
    final hash = VaultCrypto.hashAuthVerifier(authVerifier, verifierSalt);
    await storage.createAccount(
      Account(
        username: r.username,
        authVerifierHash: hash,
        verifierSalt: base64.encode(verifierSalt),
        argonSalt: r.argonSalt,
        argonParams: r.argonParams,
      ),
    );
    final token = await storage.createToken(r.username);
    return _json(LoginResponse(token: token).toJson());
  }

  Future<Response> _prelogin(Request req) async {
    final body = await _readJson(req);
    final username = body?['username'] as String?;
    if (username == null) return _error(400, 'bad_request', 'Missing username');
    final account = await storage.getAccount(username);
    if (account == null) {
      return _error(404, 'no_account', 'No such account');
    }
    return _json(
      PreloginResponse(
        argonSalt: account.argonSalt,
        argonParams: account.argonParams,
      ).toJson(),
    );
  }

  Future<Response> _login(Request req) async {
    final body = await _readJson(req);
    if (body == null) return _error(400, 'bad_request', 'Malformed JSON');
    final LoginRequest r;
    try {
      r = LoginRequest.fromJson(body);
    } catch (_) {
      return _error(400, 'bad_request', 'Invalid login payload');
    }
    if (r.protocolVersion != kProtocolVersion) {
      return _error(400, 'protocol_version', 'Protocol version mismatch');
    }
    if (!loginLimiter.allow('login:${r.username}')) {
      return _error(429, 'rate_limited', 'Too many login attempts');
    }
    final account = await storage.getAccount(r.username);
    // Always compute against *some* stored hash to keep timing uniform.
    final expected = account?.authVerifierHash ?? '';
    final authVerifier = _tryBase64Decode(r.authVerifier);
    if (authVerifier == null) {
      return _error(400, 'bad_request', 'Invalid login payload');
    }
    final verifierSalt = account == null
        ? null
        : _tryBase64Decode(account.verifierSalt);
    if (account != null && verifierSalt == null) {
      throw StateError(
        'Stored verifier salt is invalid for ${account.username}',
      );
    }
    final provided = account == null
        ? ''
        : VaultCrypto.hashAuthVerifier(authVerifier, verifierSalt!);
    if (account == null || !_constantTimeEquals(provided, expected)) {
      return _error(401, 'invalid_credentials', 'Invalid credentials');
    }
    final token = await storage.createToken(r.username);
    loginLimiter.reset('login:${r.username}');
    return _json(LoginResponse(token: token).toJson());
  }

  Future<Response> _sync(Request req) => _withAuth(req, (username) async {
    final since = int.tryParse(req.url.queryParameters['since'] ?? '0') ?? 0;
    final records = await storage.recordsSince(username, since);
    final latest = await storage.latestSeq(username);
    return _json(PullResponse(records: records, latestSeq: latest).toJson());
  });

  Future<Response> _push(Request req) => _withAuth(req, (username) async {
    final body = await _readJson(req);
    if (body == null) return _error(400, 'bad_request', 'Malformed JSON');
    final PushRequest r;
    try {
      r = PushRequest.fromJson(body);
    } catch (_) {
      return _error(400, 'bad_request', 'Invalid push payload');
    }
    if (r.protocolVersion != kProtocolVersion) {
      return _error(400, 'protocol_version', 'Protocol version mismatch');
    }
    final results = <PushResult>[];
    for (final incoming in r.records) {
      final existing = await storage.getRecord(username, incoming.id);
      // Server applies the same LWW rule as the client.
      final incomingWins =
          existing == null ||
          identical(Lww.resolve(existing, incoming), incoming);
      if (incomingWins) {
        final seq = await storage.nextSeq(username);
        await storage.putRecord(username, incoming.withSeq(seq));
        results.add(PushResult(id: incoming.id, seq: seq, accepted: true));
      } else {
        results.add(
          PushResult(id: incoming.id, seq: existing.seq ?? 0, accepted: false),
        );
      }
    }
    final latest = await storage.latestSeq(username);
    return _json(PushResponse(results: results, latestSeq: latest).toJson());
  });

  Future<Response> _deleteAccount(Request req) =>
      _withAuth(req, (username) async {
        await storage.deleteAccount(username);
        return _json({'ok': true});
      });

  // --- Helpers ---

  Future<Response> _withAuth(
    Request req,
    Future<Response> Function(String username) fn,
  ) async {
    final auth = req.headers['authorization'];
    if (auth == null || !auth.startsWith('Bearer ')) {
      return _error(401, 'unauthorized', 'Missing bearer token');
    }
    final username = await storage.usernameForToken(auth.substring(7));
    if (username == null) {
      return _error(401, 'unauthorized', 'Invalid token');
    }
    return fn(username);
  }

  Future<Map<String, dynamic>?> _readJson(Request req) async {
    try {
      final text = await req.readAsString();
      if (text.isEmpty) return null;
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  List<int>? _tryBase64Decode(String value) {
    try {
      return base64.decode(value);
    } on FormatException {
      return null;
    }
  }

  Middleware _errorToJson() => (Handler inner) {
    return (Request req) async {
      try {
        return await inner(req);
      } on FormatException {
        return _error(400, 'bad_request', 'Invalid request payload');
      } catch (e) {
        return _error(500, 'internal_error', 'Internal server error');
      }
    };
  };

  Response _json(Object body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );

  Response _error(int status, String code, String message) => _json(
    ApiError(code: code, message: message).toJson(),
    status: status,
  );

  static const _landingPage = '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Séance sync server</title>
<link rel="icon" type="image/png" href="/favicon.ico">
</head>
<body style="font-family: system-ui, sans-serif; margin: 3em auto; max-width: 34em;">
<h1>Séance sync server</h1>
<p>A breach-tolerant blob store for the <strong>Séance</strong> SSH client:
it holds only end-to-end encrypted records and can decrypt nothing.
Configure this server's URL in the app's sync settings.</p>
</body>
</html>
''';

  static bool _constantTimeEquals(String a, String b) {
    final ab = utf8.encode(a);
    final bb = utf8.encode(b);
    if (ab.length != bb.length) return false;
    var diff = 0;
    for (var i = 0; i < ab.length; i++) {
      diff |= ab[i] ^ bb[i];
    }
    return diff == 0;
  }
}

/// Minimal handle to a running server so callers can read the bound port and
/// stop it, without leaking the shelf `HttpServer` type through the API.
class HttpServerLike {
  final String host;
  final int port;
  final Future<void> Function() _close;
  HttpServerLike(this.host, this.port, this._close);
  Future<void> close() => _close();
}
