import 'package:seance_core/seance_core.dart';

import 'app_settings.dart';
import 'secure_master_key.dart';

/// Bridges the assistant half of [AppSettings] — and the OS keystore entries
/// it references — to the sync layer.
///
/// The assistant configuration has no store of its own: it lives in
/// `settings.json` alongside a pile of deliberately device-local values
/// (terminal font, editor registry, security-scoped bookmarks, the device id
/// that resolves every conflict). This adapter is what lets the sync layer see
/// exactly the account-shaped half of it and nothing else.
class AssistantSettingsSync implements AssistantSettingsStore {
  final AppSettings settings;
  final MasterKeyManager masterKeys;
  final Future<void> Function() saveSettings;

  /// True once a pulled record has been applied, so the caller knows to
  /// rebuild the chat provider — a new model or key is not picked up by an
  /// already-constructed one.
  bool applied = false;

  AssistantSettingsSync({
    required this.settings,
    required this.masterKeys,
    required this.saveSettings,
  });

  /// The keystore entry names this configuration refers to.
  ///
  /// Built from the references themselves, never by enumerating the keystore:
  /// the sync token and the vault key live in that same keystore, and putting
  /// either into a synced record would hand the account's own protection to
  /// the account.
  Iterable<String> get _referencedKeys => <String>{
    if (settings.llmApiKeyRef.isNotEmpty) settings.llmApiKeyRef,
    if (settings.braveApiKeyRef != null &&
        settings.braveApiKeyRef!.isNotEmpty)
      settings.braveApiKeyRef!,
    if (settings.zaiApiKeyRef != null && settings.zaiApiKeyRef!.isNotEmpty)
      settings.zaiApiKeyRef!,
  };

  @override
  Future<AssistantSettings?> getAssistantSettings() async {
    // Nothing has ever been published from this device, so there is nothing to
    // publish. Without this, two fresh installs would push rival defaults at
    // each other and one would overwrite the other before either was touched.
    if (settings.assistantUpdatedAt == 0) return null;

    final keys = <String, String>{};
    for (final name in _referencedKeys) {
      // getApiKey answers null on a locked keyring rather than throwing, so a
      // keystore that is down publishes the configuration without its keys
      // instead of failing the whole sync round.
      final value = await masterKeys.getApiKey(name);
      if (value != null) keys[name] = value;
    }

    return AssistantSettings(
      providerKind: settings.llmKind.name,
      baseUrl: settings.llmBaseUrl,
      model: settings.llmModel,
      llmApiKeyRef: settings.llmApiKeyRef,
      searxngUrl: settings.searxngUrl,
      braveApiKeyRef: settings.braveApiKeyRef,
      zaiApiKeyRef: settings.zaiApiKeyRef,
      redactSecrets: settings.redactionEnabled,
      apiKeys: keys,
      updatedAt: settings.assistantUpdatedAt,
    );
  }

  @override
  Future<void> putAssistantSettings(AssistantSettings value) async {
    // A provider this build has never heard of keeps the one already
    // configured rather than being decoded into a wrong guess — the same
    // choice `ServerConfig.color` makes for a colour, with more at stake.
    final kind = LlmProviderKind.values
        .where((k) => k.name == value.providerKind)
        .firstOrNull;
    if (kind != null) settings.llmKind = kind;
    settings.llmBaseUrl = value.baseUrl;
    settings.llmModel = value.model;
    settings.llmApiKeyRef = value.llmApiKeyRef;
    settings.searxngUrl = value.searxngUrl;
    settings.braveApiKeyRef = value.braveApiKeyRef;
    settings.zaiApiKeyRef = value.zaiApiKeyRef;
    settings.redactionEnabled = value.redactSecrets;
    settings.assistantUpdatedAt = value.updatedAt;

    for (final entry in value.apiKeys.entries) {
      try {
        await masterKeys.putApiKey(entry.key, entry.value);
      } on KeystoreException {
        // The keyring is locked or missing. The configuration is still worth
        // keeping — the key is re-applied on the next round once the keystore
        // is back, because the record is pulled again every time.
      }
    }

    await saveSettings();
    applied = true;
  }
}
