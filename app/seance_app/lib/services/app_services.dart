import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:seance_core/seance_core.dart';

import 'app_settings.dart';
import 'file_stores.dart';
import 'secure_master_key.dart';

/// Wires together the seance_core services with the app's file-backed stores
/// and the OS keystore. Created once at startup.
class AppServices {
  final ConfigStore configStore;
  // Mutable so sync enrolment can re-key the vault to the shared passphrase key.
  SecretVault vault;
  final HostKeyStore hostKeyStore;
  final TofuVerifier tofu;
  final ProbeService probe;
  final MasterKeyManager masterKeys;
  final SettingsStore settingsStore;
  List<int> vaultKey;
  AppSettings settings;

  AppServices._({
    required this.configStore,
    required this.vault,
    required this.hostKeyStore,
    required this.tofu,
    required this.probe,
    required this.masterKeys,
    required this.settingsStore,
    required this.vaultKey,
    required this.settings,
  });

  static Future<AppServices> initialize() async {
    final dir = await getApplicationSupportDirectory();
    String p(String name) => '${dir.path}/$name';

    final masterKeys = MasterKeyManager();
    final vaultKey = await masterKeys.loadOrCreateFromKeystore();

    final configStore = FileConfigStore(File(p('servers.json')));
    final vaultStore = FileVaultStore(File(p('vault.json')));
    final hostKeyStore = FileHostKeyStore(File(p('known_hosts.json')));
    final settingsStore = SettingsStore(File(p('settings.json')));
    final settings = await settingsStore.load();
    if (settings.deviceId.isEmpty) {
      settings.deviceId = uuidV4();
      await settingsStore.save(settings);
    }

    return AppServices._(
      configStore: configStore,
      vault: SecretVault(vaultStore, vaultKey),
      hostKeyStore: hostKeyStore,
      tofu: TofuVerifier(hostKeyStore),
      probe: ProbeService(),
      masterKeys: masterKeys,
      settingsStore: settingsStore,
      vaultKey: vaultKey,
      settings: settings,
    );
  }

  Future<void> saveSettings() => settingsStore.save(settings);

  /// Re-key the vault to [newKey], re-encrypting secrets referenced by current
  /// configs so nothing is lost. Used by sync enrolment to adopt the shared,
  /// passphrase-derived key.
  Future<void> _rekeyVault(List<int> newKey) async {
    final newVault = SecretVault(vault.store, newKey);
    for (final cfg in await configStore.listServers()) {
      if (cfg.secretRef != null) {
        final secret = await vault.getSecret(cfg.secretRef!);
        if (secret != null) await newVault.putSecret(secret);
      }
    }
    vault = newVault;
    vaultKey = newKey;
    await masterKeys.setKeystoreKey(newKey);
  }

  /// Create a sync account and adopt its passphrase-derived vault key.
  Future<void> registerSync({
    required String baseUrl,
    required String username,
    required String passphrase,
  }) async {
    final salt = secureRandomBytes(16);
    final keys = await VaultCrypto.deriveKeys(passphrase: passphrase, salt: salt);
    final client = HttpSyncClient(baseUrl: baseUrl);
    await client.register(RegisterRequest(
      username: username,
      authVerifier: base64.encode(keys.authVerifier),
      argonSalt: base64.encode(salt),
      argonParams: const Argon2Params(),
    ));
    settings.syncBaseUrl = baseUrl;
    settings.syncUsername = username;
    await saveSettings();
    await masterKeys.putApiKey('sync.token', client.token!);
    await _rekeyVault(keys.vaultKey);
  }

  /// Enrol this device against an existing account (prelogin -> derive -> login)
  /// and adopt the shared vault key.
  Future<void> loginSync({
    required String baseUrl,
    required String username,
    required String passphrase,
  }) async {
    final client = HttpSyncClient(baseUrl: baseUrl);
    final pre = await client.prelogin(username);
    final keys = await VaultCrypto.deriveKeys(
      passphrase: passphrase,
      salt: base64.decode(pre.argonSalt),
      params: pre.argonParams,
    );
    await client.login(LoginRequest(
        username: username, authVerifier: base64.encode(keys.authVerifier)));
    settings.syncBaseUrl = baseUrl;
    settings.syncUsername = username;
    await saveSettings();
    await masterKeys.putApiKey('sync.token', client.token!);
    await _rekeyVault(keys.vaultKey);
  }

  /// Run one synchronization round against the configured server.
  Future<SyncOutcome> runSync() async {
    final baseUrl = settings.syncBaseUrl;
    final token = await masterKeys.getApiKey('sync.token');
    if (baseUrl == null || token == null) {
      throw StateError('Sync is not set up');
    }
    final client = HttpSyncClient(baseUrl: baseUrl)..token = token;
    final coordinator = SyncCoordinator(
      configStore: configStore,
      hostKeyStore: hostKeyStore,
      codec: RecordCodec(vaultKey),
      local: InMemoryLocalRecordStore(),
      deviceId: settings.deviceId,
    );
    return coordinator.run(client);
  }

  /// Resolve connection credentials for [config] from the vault / on-disk key.
  Future<SshCredentials> resolveCredentials(ServerConfig config) async {
    switch (config.authMethod) {
      case AuthMethod.agent:
        return const SshCredentials.agent();
      case AuthMethod.password:
        final secret = config.secretRef == null
            ? null
            : await vault.getSecret(config.secretRef!);
        return SshCredentials.password(secret?.value ?? '');
      case AuthMethod.privateKey:
        // "Reference, don't store": read the key from disk at connect time.
        if (config.identityFilePath != null) {
          final pem = await File(config.identityFilePath!).readAsString();
          final storedPass = config.secretRef == null
              ? null
              : (await vault.getSecret(config.secretRef!))?.keyPassphrase;
          return SshCredentials.privateKey(pem, keyPassphrase: storedPass);
        }
        final secret = config.secretRef == null
            ? null
            : await vault.getSecret(config.secretRef!);
        return SshCredentials.privateKey(secret?.value ?? '',
            keyPassphrase: secret?.keyPassphrase);
    }
  }

  /// Build the configured LLM provider, resolving its API key from the keystore.
  Future<LlmProvider> buildLlmProvider() async {
    final apiKey = settings.llmApiKeyRef.isEmpty
        ? ''
        : (await masterKeys.getApiKey(settings.llmApiKeyRef) ?? '');
    switch (settings.llmKind) {
      case LlmProviderKind.anthropic:
        return AnthropicProvider(
            apiKey: apiKey,
            model: settings.llmModel,
            baseUrl: settings.llmBaseUrl);
      case LlmProviderKind.openaiCompatible:
        return OpenAiCompatibleProvider(
            baseUrl: settings.llmBaseUrl,
            apiKey: apiKey,
            model: settings.llmModel);
    }
  }

  /// Build the web-search backend for the chat tool, if one is configured.
  Future<SearchProvider?> buildSearchProvider() async {
    if (settings.searxngUrl != null && settings.searxngUrl!.isNotEmpty) {
      return SearxngSearch(baseUrl: settings.searxngUrl!);
    }
    if (settings.braveApiKeyRef != null && settings.braveApiKeyRef!.isNotEmpty) {
      final key = await masterKeys.getApiKey(settings.braveApiKeyRef!);
      if (key != null) return BraveSearch(apiKey: key);
    }
    return null;
  }

  /// A sync client for the configured server, or null if sync isn't set up.
  HttpSyncClient? buildSyncClient() {
    final url = settings.syncBaseUrl;
    if (url == null || url.isEmpty) return null;
    return HttpSyncClient(baseUrl: url);
  }
}
