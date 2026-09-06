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

  /// Keystore entries this device adopted a *reference* to but could not
  /// store, because the keyring was locked when the record arrived.
  ///
  /// The adoption deliberately keeps the configuration and its stamp in that
  /// case, retrying the key on a later round. What that leaves behind is a
  /// device whose refs name entries it does not hold — and once the keyring
  /// comes back, `collectLocal` runs before `applyToStores`, so this device
  /// would republish the *same* stamp minus the missing key before the retry
  /// ever happens. Equal stamps are broken by device id, so that keyless copy
  /// can evict the keyed one from the account.
  ///
  /// Naming them is what makes the two nulls distinguishable. A reference to
  /// a key that was simply never stored is a supported state — the Z.AI
  /// switch can be on with the field left blank — and must not stop this
  /// device publishing forever. A reference this device *knows* it failed to
  /// write is the one that must.
  ///
  /// Held in [AppSettings] rather than in this object, because the app can be
  /// stopped between the failed write and the round that retries it, and a
  /// set that starts empty on the next launch answers "never stored" for a
  /// key it knows it dropped.
  Set<String> get _unwritten => settings.unwrittenAssistantKeyRefs;

  AssistantSettingsSync({
    required this.settings,
    required this.masterKeys,
    required this.saveSettings,
  });

  /// The keystore entry names this configuration refers to.
  ///
  /// Built from the references themselves, never by enumerating the keystore:
  /// the sync token shares this API-key namespace, and the vault key sits
  /// beside it in the same keystore under a prefix of its own (out of
  /// `getApiKey`'s reach, so no reference can name it). A sweep would put the
  /// token into a synced record, handing the account's own protection to the
  /// account.
  Iterable<String> get _referencedKeys => <String>{
    if (settings.llmApiKeyRef.isNotEmpty) settings.llmApiKeyRef,
    if (settings.braveApiKeyRef != null &&
        settings.braveApiKeyRef!.isNotEmpty)
      settings.braveApiKeyRef!,
    if (settings.zaiApiKeyRef != null && settings.zaiApiKeyRef!.isNotEmpty)
      settings.zaiApiKeyRef!,
  }..removeAll(reservedKeyNames);

  /// Keystore entries that share the API-key namespace but are the account's
  /// own protection, never an assistant key: a record naming one as a ref
  /// would otherwise publish this device's sync token, or overwrite it on
  /// adoption. Held out here rather than trusted to the record, since a
  /// record is exactly as careful as the device that wrote it. The vault key
  /// is not listed because it is not in this namespace: [MasterKeyManager]
  /// stores it under its own prefix, which no key reference resolves to.
  static const Set<String> reservedKeyNames = {'sync.token'};

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
      // A key this device adopted a reference to and failed to store. Until
      // the retry lands, publishing would put a keyless record on the account
      // under a stamp that can evict the keyed one it came from.
      if (value == null && _unwritten.contains(name)) return null;
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
    // A record whose configuration *names* a reserved entry is refused whole,
    // not adopted minus the key: the filter below keeps the entry from being
    // overwritten, but an adopted `llmApiKeyRef` of `sync.token` would have
    // the chat provider resolve this device's sync token as its API key and
    // send it, as a bearer credential, to whatever endpoint the record
    // carried. The refs are the record's allow-list; this is the device's.
    if (reservedKeyNames.contains(value.llmApiKeyRef) ||
        reservedKeyNames.contains(value.braveApiKeyRef) ||
        reservedKeyNames.contains(value.zaiApiKeyRef)) {
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
    // A name this configuration no longer references is never read again, so
    // carrying it would grow a persisted set for the life of the install.
    final unwrittenBefore = _unwritten.length;
    _unwritten.retainWhere(referenced.contains);
    var unwrittenChanged = _unwritten.length != unwrittenBefore;
    var keysChanged = false;
    for (final entry in value.apiKeys.entries) {
      if (!referenced.contains(entry.key)) continue;
      try {
        // Read first: the record is pulled and re-applied every round, so
        // writing unconditionally would rewrite the keystore — and rebuild the
        // chat provider — every five minutes for a configuration that has not
        // moved.
        if (await masterKeys.getApiKey(entry.key) == entry.value) {
          // The key is demonstrably there — whatever put it there. Leaving the
          // name listed would go on blocking this device from publishing on
          // evidence the keystore has just contradicted.
          if (_unwritten.remove(entry.key)) unwrittenChanged = true;
          continue;
        }
        await masterKeys.putApiKey(entry.key, entry.value);
        if (_unwritten.remove(entry.key)) unwrittenChanged = true;
        keysChanged = true;
      } on KeystoreException {
        // The keyring is locked or missing. The configuration is still worth
        // keeping — the key is re-applied on the next round once the keystore
        // is back, because the record is pulled again every time. Remembered
        // so this device does not publish over the keyed record in the
        // meantime; see [_unwritten].
        if (_unwritten.add(entry.key)) unwrittenChanged = true;
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
    // `unwrittenChanged` joins the save condition and not `applied`: it is a
    // fact about this keystore that has to survive a restart, and nothing
    // about it changes what the chat provider would be built from.
    if (contentChanged ||
        unwrittenChanged ||
        settings.assistantUpdatedAt != stampBefore) {
      await saveSettings();
    }
    applied = contentChanged;
  }
}
