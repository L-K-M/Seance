/// Server settings, sourced from environment variables (with CLI overrides
/// applied in `bin/`). TLS is intentionally not handled here — run behind a
/// reverse proxy, the same shape as Atuin's deployment guidance.
class ServerSettings {
  final String bindAddress;
  final int port;

  /// When false, `/v1/register` is refused — lock this down after enrolling
  /// your own devices.
  final bool openRegistration;

  /// Path to the SQLite database, or null for an ephemeral in-memory store.
  final String? dbPath;

  final int loginMaxAttempts;
  final Duration loginWindow;

  const ServerSettings({
    this.bindAddress = '0.0.0.0',
    this.port = 8787,
    this.openRegistration = false,
    this.dbPath,
    this.loginMaxAttempts = 10,
    this.loginWindow = const Duration(minutes: 1),
  });

  factory ServerSettings.fromEnvironment(Map<String, String> env) {
    bool flag(String key, bool fallback) {
      final v = env[key]?.toLowerCase();
      if (v == null) return fallback;
      return v == '1' || v == 'true' || v == 'yes' || v == 'on';
    }

    return ServerSettings(
      bindAddress: env['SEANCE_BIND'] ?? '0.0.0.0',
      port: int.tryParse(env['SEANCE_PORT'] ?? '') ?? 8787,
      openRegistration: flag('SEANCE_OPEN_REGISTRATION', false),
      dbPath: env['SEANCE_DB_PATH'],
      loginMaxAttempts:
          int.tryParse(env['SEANCE_LOGIN_MAX_ATTEMPTS'] ?? '') ?? 10,
      loginWindow: Duration(
          seconds: int.tryParse(env['SEANCE_LOGIN_WINDOW_SECONDS'] ?? '') ?? 60),
    );
  }

  ServerSettings copyWith({
    String? bindAddress,
    int? port,
    bool? openRegistration,
    String? dbPath,
  }) =>
      ServerSettings(
        bindAddress: bindAddress ?? this.bindAddress,
        port: port ?? this.port,
        openRegistration: openRegistration ?? this.openRegistration,
        dbPath: dbPath ?? this.dbPath,
        loginMaxAttempts: loginMaxAttempts,
        loginWindow: loginWindow,
      );
}
