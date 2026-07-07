/// What a vault [Secret] holds.
enum SecretKind { password, privateKey }

SecretKind _secretKindFromName(String name) =>
    SecretKind.values.firstWhere((k) => k.name == name,
        orElse: () => SecretKind.password);

/// A secret stored in the encrypted vault. Never present in plaintext config —
/// a [ServerConfig] references one by id. The [value] is the password text or
/// the private-key material (PEM or OpenSSH format).
class Secret {
  final String id;
  final SecretKind kind;
  final String value;

  /// Passphrase for an encrypted private key, if the user chose to store it.
  final String? keyPassphrase;

  const Secret({
    required this.id,
    required this.kind,
    required this.value,
    this.keyPassphrase,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'value': value,
        if (keyPassphrase != null) 'keyPassphrase': keyPassphrase,
      };

  factory Secret.fromJson(Map<String, dynamic> json) => Secret(
        id: json['id'] as String,
        kind: _secretKindFromName(json['kind'] as String? ?? 'password'),
        value: json['value'] as String,
        keyPassphrase: json['keyPassphrase'] as String?,
      );

  @override
  String toString() => 'Secret(id: $id, kind: ${kind.name}, value: <redacted>)';
}
