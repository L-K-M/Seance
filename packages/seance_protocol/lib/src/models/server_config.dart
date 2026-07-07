/// How a server authenticates. `agent` means "don't store anything — sign via
/// an ssh-agent", which is the lowest-risk mode and the encouraged default.
enum AuthMethod { password, privateKey, agent }

AuthMethod _authFromName(String name) =>
    AuthMethod.values.firstWhere((m) => m.name == name,
        orElse: () => AuthMethod.password);

/// A configured SSH server. This is non-secret metadata: the actual password or
/// private key lives in the encrypted vault and is referenced here by [secretRef].
class ServerConfig {
  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;

  /// Vault entry id holding the password or private key, when [authMethod]
  /// stores a secret. Null for `agent` or for [identityFilePath] references.
  final String? secretRef;

  /// "Reference, don't store": path to an on-disk OpenSSH private key. The
  /// passphrase (if any) is prompted at connect time or cached in the vault.
  final String? identityFilePath;

  /// Optional ProxyJump: the id of another [ServerConfig] to tunnel through.
  final String? jumpHostId;

  /// Whether the referenced secret is allowed to sync (opt-in per item).
  final bool syncSecret;

  final int createdAt;
  final int updatedAt;

  const ServerConfig({
    required this.id,
    required this.label,
    required this.host,
    this.port = 22,
    required this.username,
    this.authMethod = AuthMethod.agent,
    this.secretRef,
    this.identityFilePath,
    this.jumpHostId,
    this.syncSecret = false,
    required this.createdAt,
    required this.updatedAt,
  });

  ServerConfig copyWith({
    String? label,
    String? host,
    int? port,
    String? username,
    AuthMethod? authMethod,
    String? secretRef,
    bool clearSecretRef = false,
    String? identityFilePath,
    bool clearIdentityFilePath = false,
    String? jumpHostId,
    bool clearJumpHostId = false,
    bool? syncSecret,
    int? updatedAt,
  }) {
    return ServerConfig(
      id: id,
      label: label ?? this.label,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      secretRef: clearSecretRef ? null : (secretRef ?? this.secretRef),
      identityFilePath: clearIdentityFilePath
          ? null
          : (identityFilePath ?? this.identityFilePath),
      jumpHostId: clearJumpHostId ? null : (jumpHostId ?? this.jumpHostId),
      syncSecret: syncSecret ?? this.syncSecret,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        if (secretRef != null) 'secretRef': secretRef,
        if (identityFilePath != null) 'identityFilePath': identityFilePath,
        if (jumpHostId != null) 'jumpHostId': jumpHostId,
        'syncSecret': syncSecret,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        id: json['id'] as String,
        label: json['label'] as String,
        host: json['host'] as String,
        port: (json['port'] as num?)?.toInt() ?? 22,
        username: json['username'] as String,
        authMethod: _authFromName(json['authMethod'] as String? ?? 'agent'),
        secretRef: json['secretRef'] as String?,
        identityFilePath: json['identityFilePath'] as String?,
        jumpHostId: json['jumpHostId'] as String?,
        syncSecret: json['syncSecret'] as bool? ?? false,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}
