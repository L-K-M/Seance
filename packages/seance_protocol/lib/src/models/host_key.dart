import 'dart:convert';

import 'package:crypto/crypto.dart' as classic;

/// A pinned SSH host key (trust-on-first-use), stored per host:port and synced,
/// so a second device does not re-verify a server the user already trusted.
///
/// The identity we compare on is the SHA-256 [fingerprintSha256] (the
/// `SHA256:…` form OpenSSH shows), because that is exactly what the SSH library
/// surfaces at connection time. The raw [publicKeyBase64] is only available
/// when we learned the key from a `known_hosts` import; when present it lets us
/// round-trip an interoperable `known_hosts` line.
class HostKey {
  final String host;
  final int port;

  /// Key algorithm, e.g. `ssh-ed25519`.
  final String type;

  /// `SHA256:...` fingerprint in OpenSSH's presentation format.
  final String fingerprintSha256;

  /// Base64 of the wire-format public key blob, when known (else null).
  final String? publicKeyBase64;

  final int pinnedAt;

  const HostKey({
    required this.host,
    this.port = 22,
    required this.type,
    required this.fingerprintSha256,
    this.publicKeyBase64,
    required this.pinnedAt,
  });

  /// Build from a raw public key blob (e.g. a `known_hosts` entry), computing
  /// the fingerprint the same way OpenSSH does.
  factory HostKey.fromPublicKey({
    required String host,
    int port = 22,
    required String type,
    required String publicKeyBase64,
    required int pinnedAt,
  }) {
    final raw = base64.decode(publicKeyBase64);
    final digest = classic.sha256.convert(raw).bytes;
    final fp = 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
    return HostKey(
      host: host,
      port: port,
      type: type,
      fingerprintSha256: fp,
      publicKeyBase64: publicKeyBase64,
      pinnedAt: pinnedAt,
    );
  }

  /// Natural key used for storage and record ids.
  String get locator => '$host:$port';

  /// True if [other] is the same host but a different key — the dangerous case.
  bool conflictsWith(HostKey other) =>
      host == other.host &&
      port == other.port &&
      fingerprintSha256 != other.fingerprintSha256;

  /// An OpenSSH `known_hosts` line, or null if the raw key is unknown (we only
  /// hold the fingerprint, which cannot be expanded back to a key).
  String? toKnownHostsLine() {
    if (publicKeyBase64 == null) return null;
    final hostField = port == 22 ? host : '[$host]:$port';
    return '$hostField $type $publicKeyBase64';
  }

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'type': type,
        'fingerprintSha256': fingerprintSha256,
        if (publicKeyBase64 != null) 'publicKeyBase64': publicKeyBase64,
        'pinnedAt': pinnedAt,
      };

  factory HostKey.fromJson(Map<String, dynamic> json) => HostKey(
        host: json['host'] as String,
        port: (json['port'] as num?)?.toInt() ?? 22,
        type: json['type'] as String,
        fingerprintSha256: json['fingerprintSha256'] as String,
        publicKeyBase64: json['publicKeyBase64'] as String?,
        pinnedAt: (json['pinnedAt'] as num?)?.toInt() ?? 0,
      );
}
