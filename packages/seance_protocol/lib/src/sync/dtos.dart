import '../crypto/vault.dart';
import '../records/record.dart';
import '../version.dart';

/// POST /v1/register — create an account. The server stores only a salted hash
/// of [authVerifier] plus the (non-secret) Argon2 salt and parameters a new
/// device needs to re-derive keys from the passphrase.
class RegisterRequest {
  final int protocolVersion;
  final String username;
  final String authVerifier; // base64 of the 32-byte HKDF auth verifier
  final String argonSalt; // base64
  final Argon2Params argonParams;

  const RegisterRequest({
    this.protocolVersion = kProtocolVersion,
    required this.username,
    required this.authVerifier,
    required this.argonSalt,
    required this.argonParams,
  });

  Map<String, dynamic> toJson() => {
        'protocolVersion': protocolVersion,
        'username': username,
        'authVerifier': authVerifier,
        'argonSalt': argonSalt,
        'argonParams': argonParams.toJson(),
      };

  factory RegisterRequest.fromJson(Map<String, dynamic> json) =>
      RegisterRequest(
        protocolVersion:
            (json['protocolVersion'] as num?)?.toInt() ?? kProtocolVersion,
        username: json['username'] as String,
        authVerifier: json['authVerifier'] as String,
        argonSalt: json['argonSalt'] as String,
        argonParams:
            Argon2Params.fromJson((json['argonParams'] as Map).cast()),
      );
}

/// POST /v1/prelogin — returns the KDF salt/params for a username so a fresh
/// device can derive keys from the passphrase before it can authenticate.
/// Deliberately unauthenticated; the salt is not a secret.
class PreloginResponse {
  final String argonSalt;
  final Argon2Params argonParams;

  const PreloginResponse({required this.argonSalt, required this.argonParams});

  Map<String, dynamic> toJson() =>
      {'argonSalt': argonSalt, 'argonParams': argonParams.toJson()};

  factory PreloginResponse.fromJson(Map<String, dynamic> json) =>
      PreloginResponse(
        argonSalt: json['argonSalt'] as String,
        argonParams:
            Argon2Params.fromJson((json['argonParams'] as Map).cast()),
      );
}

/// POST /v1/login — exchange the auth verifier for a bearer token.
class LoginRequest {
  final int protocolVersion;
  final String username;
  final String authVerifier;

  const LoginRequest({
    this.protocolVersion = kProtocolVersion,
    required this.username,
    required this.authVerifier,
  });

  Map<String, dynamic> toJson() => {
        'protocolVersion': protocolVersion,
        'username': username,
        'authVerifier': authVerifier,
      };

  factory LoginRequest.fromJson(Map<String, dynamic> json) => LoginRequest(
        protocolVersion:
            (json['protocolVersion'] as num?)?.toInt() ?? kProtocolVersion,
        username: json['username'] as String,
        authVerifier: json['authVerifier'] as String,
      );
}

class LoginResponse {
  final String token;
  const LoginResponse({required this.token});

  Map<String, dynamic> toJson() => {'token': token};
  factory LoginResponse.fromJson(Map<String, dynamic> json) =>
      LoginResponse(token: json['token'] as String);
}

/// `GET /v1/sync?since=<seq>` — pull records newer than the client's
/// high-water mark. [latestSeq] is the account's current maximum sequence
/// number.
class PullResponse {
  final List<EncryptedRecord> records;
  final int latestSeq;

  const PullResponse({required this.records, required this.latestSeq});

  Map<String, dynamic> toJson() => {
        'records': records.map((r) => r.toJson()).toList(),
        'latestSeq': latestSeq,
      };

  factory PullResponse.fromJson(Map<String, dynamic> json) => PullResponse(
        records: (json['records'] as List)
            .map((e) => EncryptedRecord.fromJson((e as Map).cast()))
            .toList(),
        latestSeq: (json['latestSeq'] as num).toInt(),
      );
}

/// PUT /v1/records — push a batch of locally-changed records.
class PushRequest {
  final int protocolVersion;
  final List<EncryptedRecord> records;

  const PushRequest({
    this.protocolVersion = kProtocolVersion,
    required this.records,
  });

  Map<String, dynamic> toJson() => {
        'protocolVersion': protocolVersion,
        'records': records.map((r) => r.toJson()).toList(),
      };

  factory PushRequest.fromJson(Map<String, dynamic> json) => PushRequest(
        protocolVersion:
            (json['protocolVersion'] as num?)?.toInt() ?? kProtocolVersion,
        records: (json['records'] as List)
            .map((e) => EncryptedRecord.fromJson((e as Map).cast()))
            .toList(),
      );
}

/// Result of a push: the sequence number the server assigned each accepted
/// record (a record rejected because the server already held a newer version
/// is reported with `accepted == false`).
class PushResult {
  final String id;
  final int seq;
  final bool accepted;

  const PushResult({
    required this.id,
    required this.seq,
    required this.accepted,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'seq': seq, 'accepted': accepted};

  factory PushResult.fromJson(Map<String, dynamic> json) => PushResult(
        id: json['id'] as String,
        seq: (json['seq'] as num).toInt(),
        accepted: json['accepted'] as bool? ?? true,
      );
}

class PushResponse {
  final List<PushResult> results;
  final int latestSeq;

  const PushResponse({required this.results, required this.latestSeq});

  Map<String, dynamic> toJson() => {
        'results': results.map((r) => r.toJson()).toList(),
        'latestSeq': latestSeq,
      };

  factory PushResponse.fromJson(Map<String, dynamic> json) => PushResponse(
        results: (json['results'] as List)
            .map((e) => PushResult.fromJson((e as Map).cast()))
            .toList(),
        latestSeq: (json['latestSeq'] as num).toInt(),
      );
}

/// Uniform error body returned by the server for non-2xx responses.
class ApiError implements Exception {
  final String code;
  final String message;

  const ApiError({required this.code, required this.message});

  Map<String, dynamic> toJson() => {'error': code, 'message': message};

  factory ApiError.fromJson(Map<String, dynamic> json) => ApiError(
        code: json['error'] as String? ?? 'unknown',
        message: json['message'] as String? ?? '',
      );

  @override
  String toString() => 'ApiError($code): $message';
}
