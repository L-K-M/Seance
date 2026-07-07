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

  /// The session bearer token, set by [register]/[login]. Public so the app can
  /// persist and restore it across launches.
  String? token;

  HttpSyncClient({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _authHeaders => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Never _fail(http.Response res) {
    try {
      throw ApiError.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    } on FormatException {
      throw ApiError(code: 'http_${res.statusCode}', message: res.body);
    }
  }

  /// Create an account and receive a session token.
  Future<void> register(RegisterRequest request) async {
    final res = await _client.post(_uri('/v1/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(request.toJson()));
    if (res.statusCode >= 400) _fail(res);
    token = LoginResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>)
        .token;
  }

  /// Fetch the KDF salt/params for a username so a new device can derive keys.
  Future<PreloginResponse> prelogin(String username) async {
    final res = await _client.post(_uri('/v1/prelogin'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'username': username}));
    if (res.statusCode >= 400) _fail(res);
    return PreloginResponse.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Exchange the auth verifier for a session token.
  Future<void> login(LoginRequest request) async {
    final res = await _client.post(_uri('/v1/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(request.toJson()));
    if (res.statusCode >= 400) _fail(res);
    token = LoginResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>)
        .token;
  }

  Future<void> deleteAccount() async {
    final res =
        await _client.delete(_uri('/v1/account'), headers: _authHeaders);
    if (res.statusCode >= 400) _fail(res);
    token = null;
  }

  @override
  Future<PullResponse> pull({required int since}) async {
    final res = await _client.get(
        _uri('/v1/sync', {'since': '$since'}),
        headers: _authHeaders);
    if (res.statusCode >= 400) _fail(res);
    return PullResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    final res = await _client.put(_uri('/v1/records'),
        headers: _authHeaders,
        body: jsonEncode(PushRequest(records: records).toJson()));
    if (res.statusCode >= 400) _fail(res);
    return PushResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }
}
