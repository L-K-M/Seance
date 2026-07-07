import 'dart:convert';

import 'package:crypto/crypto.dart' as classic;

/// A pinned SSH host key (trust-on-first-use). Stored per host:port and synced,
/// so a second device does not have to re-verify a server the user already
/// trusted. A change to the observed key for an existing entry is treated as a
/// hard error by the client, never a silent update.
class HostKey {
  final String host;
  final int port;

  /// Key algorithm as advertised on the wire, e.g. `ssh-ed25519`.
  final String type;

  /// Base64 of the wire-format public key blob (as in a `known_hosts` line).
  final String publicKeyBase64;

  final int pinnedAt;

  const HostKey({
    required this.host,
    required this.port,
    required this.type,
    required this.publicKeyBase64,
    required this.pinnedAt,
  });

  /// Natural key used for storage and record ids.
  String get locator => '$host:$port';

  /// `SHA256:...` fingerprint in the OpenSSH presentation format (base64, no
  /// padding) — this is what the TOFU dialog shows the user.
  String get fingerprintSha256 {
    final raw = base64.decode(publicKeyBase64);
    final digest = classic.sha256.convert(raw).bytes;
    final b64 = base64.encode(digest).replaceAll('=', '');
    return 'SHA256:$b64';
  }

  /// True if [other] is the same host but a different key — the dangerous case.
  bool conflictsWith(HostKey other) =>
      host == other.host &&
      port == other.port &&
      publicKeyBase64 != other.publicKeyBase64;

  /// Render as an OpenSSH `known_hosts` line for export/interop.
  String toKnownHostsLine() {
    final hostField = port == 22 ? host : '[$host]:$port';
    return '$hostField $type $publicKeyBase64';
  }

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'type': type,
        'publicKeyBase64': publicKeyBase64,
        'pinnedAt': pinnedAt,
      };

  factory HostKey.fromJson(Map<String, dynamic> json) => HostKey(
        host: json['host'] as String,
        port: (json['port'] as num?)?.toInt() ?? 22,
        type: json['type'] as String,
        publicKeyBase64: json['publicKeyBase64'] as String,
        pinnedAt: (json['pinnedAt'] as num?)?.toInt() ?? 0,
      );
}
