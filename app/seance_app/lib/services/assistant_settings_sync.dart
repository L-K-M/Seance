import 'package:seance_core/seance_core.dart';

import 'app_settings.dart';
import 'secure_master_key.dart';

/// The account-shaped half of the assistant configuration as one comparable
/// value.
///
/// Only these fields ride the synced record, so only a change to one of them
/// is an edit its timestamp should move for. Pressing Save with nothing
/// changed would otherwise mint a stamp later than a configuration another
/// device published in the meantime, and republish this device's copy over it
/// — a write with no edit behind it beating one with an edit behind it.
///
/// A string rather than an equality override: [AppSettings] is a mutable
/// device-local bag, and comparing two of them field-by-field is not something
/// the rest of the app has any use for.
String assistantSyncFingerprint(AppSettings settings) => [
  settings.llmKind.name,
  settings.llmBaseUrl,
  settings.llmModel,
  settings.llmApiKeyRef,
  settings.searxngUrl ?? '',
  settings.braveApiKeyRef ?? '',
  settings.zaiApiKeyRef ?? '',
  '${settings.redactionEnabled}',
].join('\u0000');

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
      // getApiKey answers null on a locked keyring rather than throwing, and
      // null for a name that was never stored. keystoreStatus is what tells
      // the two apart, and the difference matters: publishing a configuration
      // whose keys were merely unreadable would put a keyless record on the
      // account with a *newer* timestamp than the keyed one it replaces, so
      // the next device to join would adopt a provider and model with nothing
      // to authenticate them — and nothing would republish the keys, because
      // by then the stamps agree. A round skipped costs five minutes.
      final value = await masterKeys.getApiKey(name);
      if (value == null &&
          masterKeys.keystoreStatus == KeystoreStatus.unavailable) {
        return null;
      }
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
    // Endpoint, model and key reference travel *with* the provider: bolting
    // an unknown provider's endpoint onto the one already configured makes a
    // combination neither build can use — an Anthropic client pointed at an
    // OpenAI-compatible URL, holding a key stored under the other provider's
    // name. Keeping the provider means keeping all of it.
    if (kind != null) {
      settings.llmKind = kind;
      settings.llmBaseUrl = value.baseUrl;
      settings.llmModel = value.model;
      settings.llmApiKeyRef = value.llmApiKeyRef;
    }
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
