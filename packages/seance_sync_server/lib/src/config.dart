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

  /// Hard cap on a single request body, to blunt unauthenticated
  /// memory-exhaustion. Default 8 MiB.
  final int maxBodyBytes;

  /// Cap on records accepted in one push, and on a single record's encrypted
  /// blob, to bound authenticated abuse. Defaults: 1000 records, 1 MiB blob.
  final int maxRecordsPerPush;
  final int maxBlobBytes;

  const ServerSettings({
    this.bindAddress = '0.0.0.0',
    this.port = 8787,
    this.openRegistration = false,
    this.dbPath,
    this.loginMaxAttempts = 10,
    this.loginWindow = const Duration(minutes: 1),
    this.maxBodyBytes = 8 * 1024 * 1024,
    this.maxRecordsPerPush = 1000,
    this.maxBlobBytes = 1024 * 1024,
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
      maxBodyBytes:
          int.tryParse(env['SEANCE_MAX_BODY_BYTES'] ?? '') ?? 8 * 1024 * 1024,
      maxRecordsPerPush:
          int.tryParse(env['SEANCE_MAX_RECORDS_PER_PUSH'] ?? '') ?? 1000,
      maxBlobBytes:
          int.tryParse(env['SEANCE_MAX_BLOB_BYTES'] ?? '') ?? 1024 * 1024,
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
        maxBodyBytes: maxBodyBytes,
        maxRecordsPerPush: maxRecordsPerPush,
        maxBlobBytes: maxBlobBytes,
      );
}
