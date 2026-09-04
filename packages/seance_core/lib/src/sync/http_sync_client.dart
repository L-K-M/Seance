import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:seance_protocol/seance_protocol.dart';

import 'sync_engine.dart';

/// HTTP client for the Séance sync server. Handles account setup and auth, then
/// serves as the [SyncApi] the [SyncEngine] drives. All record payloads are
/// already end-to-end encrypted before they reach this layer.
class HttpSyncClient implements SyncApi {
  final String baseUrl;
  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false;

  /// Per-request timeout. Without one, a hung connection would leave
  /// `AppState.syncing` stuck true forever (spinner frozen, auto-sync wedged
  /// because it early-returns while a round is "in progress").
  final Duration timeout;

  /// The session bearer token, set by [register]/[login]. Public so the app can
  /// persist and restore it across launches.
  String? token;

  HttpSyncClient({
    required String baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  })  : baseUrl = _normalizeBaseUrl(baseUrl),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Release owned connections. Injected clients remain caller-owned.
  /// Repeated calls are harmless; this wrapper cannot be reused afterwards.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  /// Paths are appended verbatim, so a pasted "https://host/" would produce
  /// "https://host//v1/..." and 404.
  static String _normalizeBaseUrl(String url) {
    var normalized = url.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  Map<String, String> get _authHeaders => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Uri _uri(String path, [Map<String, String>? query]) {
    if (_closed) throw StateError('Sync client is closed');
    return Uri.parse('$baseUrl$path').replace(queryParameters: query);
  }

  Never _fail(http.Response res) {
    // The server's own errors are JSON with an `error` code. Anything else —
    // an HTML error page, a CDN's plain-text body, a JSON scalar — came from
    // whatever sits in front of the server (or from a URL that is not a
    // Séance server), so describe the failure instead of echoing the body.
    Object? decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      decoded = null;
    }
    if (decoded is Map<String, dynamic> && decoded['error'] is String) {
      throw ApiError.fromJson(decoded);
    }
    throw ApiError(
      code: 'http_${res.statusCode}',
      message: _describeHttpFailure(res.statusCode, res.body),
    );
  }

  static String _describeHttpFailure(int status, String body) {
    switch (status) {
      case 502:
        return 'The reverse proxy could not reach the sync server — it looks '
            'stopped, crashed, or unreachable on its published port.';
      case 503:
        return 'The sync server is unavailable — it may be restarting or '
            'overloaded.';
      case 504:
        return 'The reverse proxy timed out waiting for the sync server.';
      default:
        final snippet = _sanitizeBody(body);
        return snippet.isEmpty
            ? 'Unexpected response with an empty body.'
            : 'Unexpected response: $snippet';
    }
  }

  /// Strip markup and collapse whitespace so a proxy's HTML error page renders
  /// as one short readable line in the app, not tag soup.
  static String _sanitizeBody(String body) {
    var text = body
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const cap = 160;
    if (text.length > cap) text = '${text.substring(0, cap)}…';
    return text;
  }

  /// Create an account and receive a session token.
  Future<void> register(RegisterRequest request) async {
    final res = await _client
        .post(_uri('/v1/register'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(request.toJson()))
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    token = LoginResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>)
        .token;
  }

  /// Fetch the KDF salt/params for a username so a new device can derive keys.
  Future<PreloginResponse> prelogin(String username) async {
    final res = await _client
        .post(_uri('/v1/prelogin'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'username': username}))
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    return PreloginResponse.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Exchange the auth verifier for a session token.
  Future<void> login(LoginRequest request) async {
    final res = await _client
        .post(_uri('/v1/login'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(request.toJson()))
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    token = LoginResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>)
        .token;
  }

  Future<void> deleteAccount() async {
    final res = await _client
        .delete(_uri('/v1/account'), headers: _authHeaders)
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    token = null;
  }

  @override
  Future<PullResponse> pull({required int since}) async {
    final res = await _client
        .get(_uri('/v1/sync', {'since': '$since'}), headers: _authHeaders)
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    return PullResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    final res = await _client
        .put(_uri('/v1/records'),
            headers: _authHeaders,
            body: jsonEncode(PushRequest(records: records).toJson()))
        .timeout(timeout);
    if (res.statusCode >= 400) _fail(res);
    return PushResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }
}
