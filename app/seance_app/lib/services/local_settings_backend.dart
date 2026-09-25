import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../ui/sync_enrollment_validation.dart';
import '../ui/terminal_appearance.dart';
import 'app_settings.dart';
import 'assistant_settings_sync.dart';
import 'external_file_opener.dart';
import 'settings_backend.dart';

/// Keystore entry name for the Z.AI search key. A constant rather than a typed
/// value: settings hold key *names*, never keys.
const String _zaiKeyRef = 'zai';

/// [SettingsBackend] over the app's own [AppState], in the app's isolate.
///
/// The Settings route uses it directly; the settings window's host uses it to
/// answer what the window forwards. It holds no state of its own — listeners
/// are the state's — so it needs no disposal and any number can exist.
class LocalSettingsBackend implements SettingsBackend {
  LocalSettingsBackend(this._state);

  final AppState _state;

  AppSettings get _s => _state.services.settings;

  @override
  AppSettings get settings => _s;

  @override
  int get llmConfigVersion => _state.llmConfigVersion;

  @override
  SyncStatus get syncStatus => SyncStatus(
    syncing: _state.syncing,
    lastSyncAt: _state.lastSyncAt,
    lastSyncError: _state.lastSyncError,
  );

  @override
  void addListener(VoidCallback listener) => _state.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _state.removeListener(listener);

  /// Turning the update check off also clears any banner already showing
  /// this session.
  @override
  Future<void> setCheckForUpdates(bool enabled) async {
    _s.checkForUpdates = enabled;
    await _state.services.saveSettings();
    if (!enabled) _state.dismissUpdateNotice();
  }

  @override
  Future<void> setKeepSessionsAlive(bool enabled) async {
    _s.keepSessionsAliveInBackground = enabled;
    try {
      await _state.services.saveSettings();
      // A newer call may have landed while this save was in flight; its own
      // write owns the apply, and this stale one must not clobber it.
      if (_s.keepSessionsAliveInBackground != enabled) return;
      _state.setKeepSessionsAliveEnabled(enabled);
    } catch (_) {
      // The newer choice is authoritative and stands; only this call's own
      // value is put back.
      if (_s.keepSessionsAliveInBackground != enabled) return;
      _s.keepSessionsAliveInBackground = !enabled;
      rethrow;
    }
  }

  /// Refreshes the suggestion list, which empties when the switch goes off.
  @override
  Future<void> setCommandSuggestions(bool enabled) async {
    _s.commandSuggestions = enabled;
    await _state.services.saveSettings();
    _state.refreshSuggestions();
  }

  @override
  Future<void> setTerminalAppearance({
    required double fontSize,
    required String fontFamily,
    required TerminalPalette palette,
  }) async {
    if (_s.terminalFontSize == fontSize &&
        _s.terminalPalette == palette &&
        _s.terminalFontFamily == fontFamily) {
      return;
    }
    _s.terminalFontSize = fontSize;
    _s.terminalPalette = palette;
    _s.terminalFontFamily = fontFamily;
    // Terminals read the settings during build, so they need a nudge.
    _state.terminalAppearanceChanged();
    await _state.services.saveSettings();
  }

  /// Stored as a copy: the caller keeps editing its own registry, and those
  /// edits must reach the settings through here, not by aliasing.
  @override
  Future<void> setEditorRegistry(EditorRegistry registry) async {
    _s.editorRegistry = EditorRegistry.fromJson(registry.toJson());
    await _state.services.saveSettings();
  }

  @override
  Future<ExternalEditorDefinition?> pickEditor() =>
      const ExternalFileOpener().pickEditor();

  /// Keyless local endpoints (Ollama) need no key. The manual model field
  /// remains the fallback if this fails or the list omits the model wanted.
  @override
  Future<List<String>> fetchModels(ModelQuery query) async {
    final ref = query.kind == LlmProviderKind.anthropic
        ? 'anthropic'
        : 'openai';
    final key = query.typedApiKey.isNotEmpty
        ? query.typedApiKey
        : (await _state.services.masterKeys.getApiKey(ref) ?? '');
    final baseUrl = query.baseUrl.trim();
    final LlmProvider provider = query.kind == LlmProviderKind.anthropic
        ? AnthropicProvider(
            apiKey: key,
            baseUrl: baseUrl,
            model: query.model.trim(),
          )
        : OpenAiCompatibleProvider(
            baseUrl: baseUrl,
            apiKey: key,
            model: query.model.trim(),
          );
    final models = await provider.listModels();
    models.sort();
    return models;
  }

  AssistantSaveResult _result(
    AssistantSaveStatus status, {
    AssistantKey? failedKey,
    String? error,
  }) => AssistantSaveResult(
    status: status,
    current: AssistantFields.of(_s),
    version: _state.llmConfigVersion,
    failedKey: failedKey,
    error: error,
  );

  /// Save the assistant half of the settings from [draft].
  ///
  /// Throws only for a failure after the keystore writes (the settings write
  /// itself); everything the screen has to tell apart comes back as a
  /// [AssistantSaveResult].
  @override
  Future<AssistantSaveResult> saveAssistant(AssistantDraft draft) async {
    final state = _state;
    // The screen reloads its fields after an adoption it causes, but a
    // periodic round adopts too, and the screen may be open while it does.
    // Saving the fields it loaded earlier would write the pre-adoption values
    // back over the adopted ones — and stamp them, so the revert would win on
    // every device. Refused before anything is written: the adopted values
    // are loaded instead, and the user saves again from what is actually
    // configured. Typed keys are left in their fields; only the assistant
    // half is reloaded.
    if (state.llmConfigVersion != draft.versionSeen) {
      return _result(AssistantSaveStatus.adoptedBeforeSave);
    }
    // For the re-check below: the guard above sees an adoption that landed
    // before this Save, not one that lands during its awaits.
    final versionAtEntry = state.llmConfigVersion;
    final s = _s;
    final fields = draft.fields;
    // Store the API key under a per-provider name, taken from the draft once:
    // a provider read again after the keystore writes could disagree with
    // the one the key was stored under, and `openaiCompatible` holding
    // `'anthropic'` authenticates against nothing.
    final kind = fields.kind;
    final ref = kind == LlmProviderKind.anthropic ? 'anthropic' : 'openai';
    final zaiEnabled = fields.zaiEnabled;
    final enteredZaiKey = draft.zaiApiKey.trim();
    final enteredLlmKey = draft.llmApiKey.trim();

    // Keys first, settings after. A keystore failure returns without saving,
    // and the settings object is the one the running app reads — leaving it
    // mutated to say "Z.AI is on" behind a key that never landed would make
    // the failed save take effect anyway, until the next launch.
    if (zaiEnabled && enteredZaiKey.isNotEmpty) {
      try {
        // Trimmed like every other field here: a key pasted from a password
        // manager carries a trailing newline more often than not, and it
        // authenticates as garbage that CompositeSearch swallows into a log
        // line.
        await state.services.masterKeys.putApiKey(_zaiKeyRef, enteredZaiKey);
      } catch (e) {
        return _result(
          AssistantSaveStatus.keystoreFailed,
          failedKey: AssistantKey.zai,
          error: '$e',
        );
      }
    }
    // Trimmed and tested trimmed, for the same reason as the Z.AI key above —
    // and it matters more here: a search backend that authenticates as
    // garbage leaves the others working, while this key is the assistant's
    // only one. A whitespace-only paste is no key at all, so it does not
    // overwrite the stored one.
    if (enteredLlmKey.isNotEmpty) {
      try {
        await state.services.masterKeys.putApiKey(ref, enteredLlmKey);
      } catch (e) {
        // KeystoreException: the OS keyring is unavailable — don't report
        // "Saved" for a key that never landed.
        return _result(
          AssistantSaveStatus.keystoreFailed,
          failedKey: AssistantKey.llm,
          error: '$e',
        );
      }
    }

    // Read before the guard and the assignments below, never between them:
    // an adoption landing inside this await would otherwise land after the
    // guard had passed, which is the race the guard exists for. `getApiKey`
    // answers null on a locked keyring rather than throwing.
    final zaiWithoutKey =
        zaiEnabled &&
        (await state.services.masterKeys.getApiKey(_zaiKeyRef)) == null;

    // The guard at the top cannot see an adoption that landed during the
    // keystore writes above. Assigning over it would put the pre-adoption
    // fields back and republish them stamped `now` — the revert that wins on
    // every device. Refused here too, before anything is assigned to `s`; a
    // key stored above stays stored, since refs are per provider and
    // adoption keeps them.
    if (state.llmConfigVersion != versionAtEntry) {
      return _result(AssistantSaveStatus.adoptedBeforeSave);
    }
    // Taken before the assignments, so a Save that changes nothing does not
    // stamp: see [assistantSyncFingerprint].
    final before = assistantSyncFingerprint(s);
    s.llmKind = kind;
    s.llmBaseUrl = fields.baseUrl.trim();
    s.llmModel = fields.model.trim();
    s.llmApiKeyRef = ref;
    s.redactionEnabled = fields.redactionEnabled;
    final searxng = fields.searxngUrl.trim();
    s.searxngUrl = searxng.isEmpty ? null : searxng;
    // The reference is what switches the backend on; turning it off leaves the
    // key in the keystore rather than deleting it, like every other key here.
    s.zaiApiKeyRef = zaiEnabled ? _zaiKeyRef : null;
    await state.services.saveSettings();
    // Stamp and publish: this is the edit the synced record's timestamp is
    // supposed to move for. A no-op when assistant sync is off.
    //
    // Re-checked against `versionAtEntry`: `saveSettings` is a plain disk
    // write, not queued behind the mutation lock, so a periodic round can
    // adopt during that await, and publishing then would stamp `now` on this
    // Save's pre-adoption values — which beats the adopted record on every
    // device. Skipping the publish loses nothing the arithmetic below does not
    // already handle: `assistantSettingsEdited` never touches the counter, so
    // `adoptedMeanwhile` still reads true and the fields are reloaded.
    String? publishError;
    if (state.llmConfigVersion == versionAtEntry &&
        (draft.keyEntered || assistantSyncFingerprint(s) != before)) {
      try {
        await state.assistantSettingsEdited();
      } catch (e) {
        // The settings are already on disk. A failed publish must not skip
        // the provider rebuild below or read like Save itself broke.
        publishError = '$e';
      }
    }
    // Rebuild the chat provider (new key/model) and refresh sidebar
    // visibility.
    //
    // Caught rather than thrown: everything above is past the point of no
    // return — the keystores, `settings.json` and the published record are
    // all written — so throwing would report "Settings not saved" for a save
    // that succeeded and tell the user to re-enter secrets that are on disk.
    // `reloadLlmProvider` does `llmConfigVersion++` as its first statement,
    // before any await, so the one bump counted below has landed even when a
    // later step throws.
    String? reloadError;
    try {
      await state.reloadLlmProvider();
    } catch (e) {
      reloadError = '$e';
    }
    // This Save is the configuration now in effect — unless a periodic round
    // adopted another device's configuration during the awaits above. The
    // reload just made is this Save's own bump, and the only one it makes:
    // `assistantSettingsEdited` does not touch the counter. Anything else is
    // an adoption, and blessing this version would let the next Save revert
    // it silently, with a fresh stamp.
    const bumpsThisSaveMakes = 1; // reloadLlmProvider
    return AssistantSaveResult(
      status: AssistantSaveStatus.saved,
      current: AssistantFields.of(s),
      version: state.llmConfigVersion,
      keysStored: draft.keyEntered,
      publishError: publishError,
      reloadError: reloadError,
      adoptedMeanwhile:
          state.llmConfigVersion != versionAtEntry + bumpsThisSaveMakes,
      zaiWithoutKey: zaiWithoutKey,
    );
  }

  /// Persist the sync switches and (re)start the auto-sync timer.
  @override
  Future<SyncPrefsResult> setSyncPrefs({
    required bool autoSync,
    required bool syncSecrets,
    required bool syncAssistant,
  }) async {
    final state = _state;
    final s = _s;
    SyncPrefsResult result({
      String? saveError,
      String? assistantSyncError,
      bool adopted = false,
    }) => SyncPrefsResult(
      autoSync: s.autoSync,
      syncSecrets: s.syncSecrets,
      syncAssistant: s.syncAssistant,
      current: AssistantFields.of(s),
      version: state.llmConfigVersion,
      saveError: saveError,
      assistantSyncError: assistantSyncError,
      adopted: adopted,
    );

    final wasAutoSync = s.autoSync;
    final wasSyncSecrets = s.syncSecrets;
    final wasSyncingAssistant = s.syncAssistant;
    s.autoSync = autoSync;
    s.syncSecrets = syncSecrets;
    s.syncAssistant = syncAssistant;
    try {
      await state.services.saveSettings();
    } catch (e) {
      // Roll the flags back: left on in memory, the next successful save of
      // anything would persist them, switching on a sync that carries API
      // keys without the adopt-first step this failure skipped. All three,
      // not only the assistant's: the other two are left in memory by the
      // same failed write, with the same consequence one switch over. And do
      // not go on to adopt for a switch that was not persisted.
      s.syncAssistant = wasSyncingAssistant;
      s.autoSync = wasAutoSync;
      s.syncSecrets = wasSyncSecrets;
      return result(saveError: '$e');
    }
    state.ensureAutoSyncTimer();
    // Switching it on adopts what the account already has, and publishes what
    // this device has only when there was nothing to adopt.
    if (!syncAssistant || wasSyncingAssistant) return result();
    // Taken immediately before the round: only this round's own bump means
    // "adopted". A periodic round that adopted earlier also moved the counter,
    // and on the publish path — where this round itself bumps nothing — a
    // stale baseline would read as an adoption and have the screen reload
    // the fields, discarding whatever the user had typed into them.
    final versionBeforeRound = state.llmConfigVersion;
    try {
      await state.assistantSyncSwitchedOn();
    } catch (e) {
      // Rolled back for the same reason the failed write above is: both mean
      // the adopt-first step did not run, and leaving the switch on lets the
      // next Save stamp `now` and publish this device's configuration over
      // the account's newer record — the clobber adopting first exists to
      // prevent. Turning it on again retries.
      s.syncAssistant = false;
      try {
        await state.services.saveSettings();
      } catch (_) {
        // The original failure is the one worth telling; the in-memory flag
        // and the reported switch still agree with each other.
      }
      return result(assistantSyncError: '$e');
    }
    // Adoption rewrites the assistant half of `settings`. Reported only when
    // it actually ran: the switch publishes when the account holds nothing,
    // which rewrites nothing here, and reloading then would overwrite what
    // the user had typed but not yet saved. `_runSyncAndRefresh` reloads the
    // provider, and so bumps the counter, only when the round adopted.
    return result(adopted: state.llmConfigVersion != versionBeforeRound);
  }

  @override
  Future<void> enrollSync(SyncEnrollment enrollment) async {
    if (enrollment.mode == SyncEnrollmentMode.register) {
      await _state.services.registerSync(
        baseUrl: enrollment.baseUrl,
        username: enrollment.username,
        password: enrollment.password,
        encryptionPassphrase: enrollment.encryptionPassphrase,
      );
    } else {
      await _state.services.loginSync(
        baseUrl: enrollment.baseUrl,
        username: enrollment.username,
        password: enrollment.password,
        encryptionPassphrase: enrollment.encryptionPassphrase,
      );
    }
    // Schedule periodic sync if enabled; the caller verifies enrollment with
    // one immediate round.
    _state.ensureAutoSyncTimer();
  }

  @override
  Future<SyncCounts> syncNow() async {
    final outcome = await _state.syncNow();
    return SyncCounts(pulled: outcome.pulled, pushed: outcome.pushed);
  }
}
