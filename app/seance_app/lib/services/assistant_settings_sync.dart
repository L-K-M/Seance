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
/// the rest of the app has any use for. Length-prefixed rather than joined on
/// a separator: these are free text that can arrive from another device, so
/// any character a separator could be is one a field could contain.
String assistantSyncFingerprint(AppSettings settings) => [
  settings.llmKind.name,
  settings.llmBaseUrl,
  settings.llmModel,
  settings.llmApiKeyRef,
  settings.searxngUrl ?? '',
  settings.braveApiKeyRef ?? '',
  settings.zaiApiKeyRef ?? '',
  '${settings.redactionEnabled}',
].map((field) => '${field.length}:$field').join();

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
      // Anything but a positively readable keystore: `unknown` and any state
      // added later mean the same thing here — this null is not evidence the
      // key is gone.
      if (value == null &&
          masterKeys.keystoreStatus != KeystoreStatus.available) {
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
  Future<int> assistantSettingsUpdatedAt() async => settings.assistantUpdatedAt;

  @override
  Future<void> putAssistantSettings(AssistantSettings value) async {
    final before = assistantSyncFingerprint(settings);
    final stampBefore = settings.assistantUpdatedAt;
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
    if (kind == null) {
      // Nothing of this record is adopted, and the stamp stays where it is.
      // Taking the half this build understands would leave the account with
      // two disagreeing configurations and matching timestamps to hide it —
      // and this device's next edit would publish the hybrid over the newer
      // build's record everywhere. An older build not participating is the
      // smaller failure, and it self-heals when the build catches up.
      //
      // `applied` is a per-round answer, so it has to be cleared here too:
      // the coordinator hands a record over every round, and leaving the
      // previous round's `true` standing would rebuild the chat provider for
      // a record this one deliberately did not adopt.
      applied = false;
      return;
    }
    settings.llmKind = kind;
    settings.llmBaseUrl = value.baseUrl;
    settings.llmModel = value.model;
    settings.llmApiKeyRef = value.llmApiKeyRef;
    settings.searxngUrl = value.searxngUrl;
    settings.braveApiKeyRef = value.braveApiKeyRef;
    settings.zaiApiKeyRef = value.zaiApiKeyRef;
    settings.redactionEnabled = value.redactSecrets;
    settings.assistantUpdatedAt = value.updatedAt;

    // Only the names this configuration now references, mirroring the filter
    // on the way out. Publishing is careful never to sweep the keystore; an
    // import that writes whatever names a record happens to carry gives that
    // care back, since a record is exactly as trustworthy as the device that
    // wrote it.
    //
    // Removals are deliberately not propagated: the record says which keys a
    // configuration uses, never which ones a device should forget, and a name
    // dropped here may still be referenced by settings this record does not
    // describe. A key that stops being referenced stops being read.
    final referenced = _referencedKeys.toSet();
    var keysChanged = false;
    for (final entry in value.apiKeys.entries) {
      if (!referenced.contains(entry.key)) continue;
      try {
        // Read first: the record is pulled and re-applied every round, so
        // writing unconditionally would rewrite the keystore — and rebuild the
        // chat provider — every five minutes for a configuration that has not
        // moved.
        if (await masterKeys.getApiKey(entry.key) == entry.value) continue;
        await masterKeys.putApiKey(entry.key, entry.value);
        keysChanged = true;
      } on KeystoreException {
        // The keyring is locked or missing. The configuration is still worth
        // keeping — the key is re-applied on the next round once the keystore
        // is back, because the record is pulled again every time.
      }
    }

    // Two different questions, deliberately separated. `saveSettings` has to
    // run for a stamp that moved on its own — two devices making the same
    // edit, or a revert — because the local stamp must catch up or the
    // coordinator keeps re-delivering the record. But `applied` rebuilds the
    // chat provider, and a record whose every field matches what is already
    // configured gives that provider nothing new: rebuilding would interrupt
    // a live session to arrive at the same client.
    final contentChanged =
        keysChanged || assistantSyncFingerprint(settings) != before;
    if (contentChanged || settings.assistantUpdatedAt != stampBefore) {
      await saveSettings();
    }
    applied = contentChanged;
  }
}
