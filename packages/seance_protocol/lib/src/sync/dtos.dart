import '../crypto/vault.dart';
import '../json_size.dart';
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

/// The shipped server's cap on one push body. Doubles as the client's fallback
/// when a server does not advertise its limits, so an unadvertised batch still
/// fits a default deployment.
const int kDefaultMaxPushBodyBytes = 8 * 1024 * 1024;

/// The shipped server's cap on records in one push. Fallback, as above.
const int kDefaultMaxRecordsPerPush = 1000;

/// What a single push may contain. Both caps are enforced server-side and both
/// are env-tunable per deployment, so the server advertises its own values in
/// every [PullResponse] and the client sizes its batches to them. The defaults
/// only apply to a server too old to advertise, which is why they are the
/// values that server shipped with.
class PushLimits {
  /// Largest accepted request body, in bytes. Exceeding it is refused before
  /// any record is read, so the whole push fails — batching is what keeps a
  /// large dirty set from failing identically every round.
  final int maxBodyBytes;

  /// Most records accepted in one push.
  final int maxRecordsPerPush;

  const PushLimits({
    this.maxBodyBytes = kDefaultMaxPushBodyBytes,
    this.maxRecordsPerPush = kDefaultMaxRecordsPerPush,
  });

  Map<String, dynamic> toJson() => {
        'maxBodyBytes': maxBodyBytes,
        'maxRecordsPerPush': maxRecordsPerPush,
      };

  factory PushLimits.fromJson(Map<String, dynamic> json) => PushLimits(
        maxBodyBytes:
            (json['maxBodyBytes'] as num?)?.toInt() ?? kDefaultMaxPushBodyBytes,
        maxRecordsPerPush: (json['maxRecordsPerPush'] as num?)?.toInt() ??
            kDefaultMaxRecordsPerPush,
      );

  @override
  bool operator ==(Object other) =>
      other is PushLimits &&
      other.maxBodyBytes == maxBodyBytes &&
      other.maxRecordsPerPush == maxRecordsPerPush;

  @override
  int get hashCode => Object.hash(maxBodyBytes, maxRecordsPerPush);

  @override
  String toString() =>
      'PushLimits(maxBodyBytes: $maxBodyBytes, '
      'maxRecordsPerPush: $maxRecordsPerPush)';
}

/// `GET /v1/sync?since=<seq>` — pull records newer than the client's
/// high-water mark. [latestSeq] is the account's current maximum sequence
/// number.
class PullResponse {
  final List<EncryptedRecord> records;
  final int latestSeq;

  /// The limits the next push must respect, or null from a server that does
  /// not advertise them. Carried here rather than on an endpoint of its own
  /// because every sync round pulls before it pushes: the client learns the
  /// limits of the deployment it is about to push to, on the request it was
  /// making anyway.
  final PushLimits? limits;

  const PullResponse({
    required this.records,
    required this.latestSeq,
    this.limits,
  });

  Map<String, dynamic> toJson() => {
        'records': records.map((r) => r.toJson()).toList(),
        'latestSeq': latestSeq,
        if (limits != null) 'limits': limits!.toJson(),
      };

  factory PullResponse.fromJson(Map<String, dynamic> json) => PullResponse(
        records: (json['records'] as List)
            .map((e) => EncryptedRecord.fromJson((e as Map).cast()))
            .toList(),
        latestSeq: (json['latestSeq'] as num).toInt(),
        limits: json['limits'] == null
            ? null
            : PushLimits.fromJson((json['limits'] as Map).cast()),
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

  /// Keep [bodyBytesFor] in step with this map — see
  /// [EncryptedRecord.toJson] for why.
  Map<String, dynamic> toJson() => {
        'protocolVersion': protocolVersion,
        'records': records.map((r) => r.toJson()).toList(),
      };

  /// Byte length of the body [toJson] encodes to, without building it.
  int encodedSizeBytes() => bodyBytesFor(
        recordCount: records.length,
        recordBytes: records.fold(0, (sum, r) => sum + r.encodedJsonBytes()),
        protocolVersion: protocolVersion,
      );

  /// Byte length of a push body holding [recordCount] records whose encoded
  /// sizes sum to [recordBytes].
  ///
  /// Split out from [encodedSizeBytes] so a client filling a batch can test
  /// the next candidate in constant time, instead of re-measuring every record
  /// it has already accepted each time it adds one.
  static int bodyBytesFor({
    required int recordCount,
    required int recordBytes,
    int protocolVersion = kProtocolVersion,
  }) =>
      jsonObjectFramingBytes(2) +
      jsonKeyBytes('protocolVersion') +
      jsonIntBytes(protocolVersion) +
      jsonKeyBytes('records') +
      jsonArrayFramingBytes(recordCount) +
      recordBytes;

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
