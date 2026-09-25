import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

import '../theme/app_appearance.dart';
import '../theme/theme_palette.dart';
import '../ui/sync_enrollment_validation.dart';
import '../ui/terminal_appearance.dart';
import 'app_settings.dart';
import 'external_file_opener.dart';

/// The Settings screen's tabs, in the order the screen shows them. Here
/// rather than beside the screen because the settings window's opener names
/// one across the isolate boundary.
enum SettingsTab { general, appearance, assistant, files, sync }

/// Everything the Settings screen reads and does, apart from where it runs.
///
/// On a phone or tablet the screen is a route in the app's own isolate and
/// talks to [LocalSettingsBackend] directly. On desktop it is a window of its
/// own, which Flutter runs on a second engine — a second isolate that shares
/// no memory with the app — so there it talks to a proxy that forwards each
/// call to the app's isolate and waits for the answer. Both sides run the
/// same logic, the one in `local_settings_backend.dart`: the proxy only
/// carries the arguments and the result.
///
/// That is why every write is a method rather than an edit to [settings]:
/// the object the window holds is a copy, and the rules each write has to
/// keep (the assistant's adoption guards, the sync switches' rollbacks) need
/// the app's live state to be kept against.
///
/// Notifies whenever [settings], [llmConfigVersion] or [syncStatus] change.
abstract class SettingsBackend implements Listenable {
  /// The settings as of the last change. Read-only: the screen loads its
  /// fields from here and writes through the methods below.
  AppSettings get settings;

  /// [AppState.llmConfigVersion]: bumped by every rebuild of the assistant's
  /// provider, including one caused by a sync round adopting another
  /// device's configuration. The assistant save compares against it.
  int get llmConfigVersion;

  /// The app-wide sync status, which background rounds move too.
  SyncStatus get syncStatus;

  Future<void> setCheckForUpdates(bool enabled);

  /// Persists and applies the Android keep-alive switch. Throws when the
  /// write fails, after putting the in-memory setting back — unless a newer
  /// call has set it meanwhile, which then stands.
  Future<void> setKeepSessionsAlive(bool enabled);

  Future<void> setCommandSuggestions(bool enabled);

  /// Persists the terminal appearance and repaints every live session. A
  /// no-op when nothing changed.
  Future<void> setTerminalAppearance({
    required double fontSize,
    required String fontFamily,
    required TerminalPalette palette,
  });

  /// Persists the theme and re-themes the app — and an open settings
  /// window, through its next snapshot. A no-op when nothing changed.
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode);

  Future<void> setEditorRegistry(EditorRegistry registry);

  /// The platform's application picker, for adding an external editor. Null
  /// when the user cancels.
  Future<ExternalEditorDefinition?> pickEditor();

  /// Asks the endpoint in [query] which models it offers. Uses the key typed
  /// into the form if there is one, otherwise the stored one.
  Future<List<String>> fetchModels(ModelQuery query);

  Future<AssistantSaveResult> saveAssistant(AssistantDraft draft);

  Future<SyncPrefsResult> setSyncPrefs({
    required bool autoSync,
    required bool syncSecrets,
    required bool syncAssistant,
  });

  /// Registers or logs in to a sync account and schedules periodic sync.
  /// Does not run a round: the screen follows it with [syncNow] so it can
  /// say which step it is on.
  Future<void> enrollSync(SyncEnrollment enrollment);

  Future<SyncCounts> syncNow();
}

/// Thrown by a backend whose work failed in the app's isolate, carrying the
/// message the original error printed. Its [toString] is that message, so a
/// screen that shows `'Failed: $e'` reads the same through either backend.
class SettingsBackendException implements Exception {
  const SettingsBackendException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The sync status line's inputs.
@immutable
class SyncStatus {
  const SyncStatus({this.syncing = false, this.lastSyncAt, this.lastSyncError});

  final bool syncing;
  final DateTime? lastSyncAt;
  final String? lastSyncError;

  factory SyncStatus.fromJson(Map<String, dynamic> json) => SyncStatus(
    syncing: json['syncing'] == true,
    lastSyncAt: json['lastSyncAt'] is int
        ? DateTime.fromMillisecondsSinceEpoch(json['lastSyncAt'] as int)
        : null,
    lastSyncError: json['lastSyncError'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'syncing': syncing,
    if (lastSyncAt != null) 'lastSyncAt': lastSyncAt!.millisecondsSinceEpoch,
    if (lastSyncError != null) 'lastSyncError': lastSyncError,
  };
}

/// The assistant half of the settings, as the screen's fields show it.
@immutable
class AssistantFields {
  const AssistantFields({
    required this.kind,
    required this.baseUrl,
    required this.model,
    required this.searxngUrl,
    required this.zaiEnabled,
    required this.redactionEnabled,
  });

  factory AssistantFields.of(AppSettings s) => AssistantFields(
    kind: s.llmKind,
    baseUrl: s.llmBaseUrl,
    model: s.llmModel,
    searxngUrl: s.searxngUrl ?? '',
    // Only whether it is on — never the key itself, which stays in the OS
    // keystore and is not something a settings screen should be able to show.
    // Trimmed, like `buildSearchProvider` reads it: a hand-edited or synced
    // `settings.json` holding `"   "` would otherwise show the switch on for
    // a backend every search silently skips.
    zaiEnabled: (s.zaiApiKeyRef ?? '').trim().isNotEmpty,
    redactionEnabled: s.redactionEnabled,
  );

  final LlmProviderKind kind;
  final String baseUrl;
  final String model;
  final String searxngUrl;
  final bool zaiEnabled;
  final bool redactionEnabled;

  factory AssistantFields.fromJson(Map<String, dynamic> json) =>
      AssistantFields(
        kind: LlmProviderKind.values.byName(json['kind'] as String),
        baseUrl: json['baseUrl'] as String,
        model: json['model'] as String,
        searxngUrl: json['searxngUrl'] as String,
        zaiEnabled: json['zaiEnabled'] as bool,
        redactionEnabled: json['redactionEnabled'] as bool,
      );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'baseUrl': baseUrl,
    'model': model,
    'searxngUrl': searxngUrl,
    'zaiEnabled': zaiEnabled,
    'redactionEnabled': redactionEnabled,
  };
}

/// What Save sends: the assistant fields as typed, the two write-only key
/// fields, and the configuration version the fields were loaded at.
///
/// Every value is read from the form once, when Save is pressed. The form
/// stays editable while a save is in flight, and each read taken later —
/// the key fields, the provider, the endpoint, the Z.AI switch — was at one
/// point a way for text typed during a slow keystore write to be folded into
/// the save already running, or for two writes of one save to disagree.
@immutable
class AssistantDraft {
  const AssistantDraft({
    required this.fields,
    required this.llmApiKey,
    required this.zaiApiKey,
    required this.versionSeen,
  });

  final AssistantFields fields;

  /// As typed; blank keeps the stored key. The backend trims.
  final String llmApiKey;
  final String zaiApiKey;

  /// [SettingsBackend.llmConfigVersion] when the fields were last loaded.
  final int versionSeen;

  /// Whether either key field holds a key. A key typed into *any* of them
  /// counts even when every other field matched: the keys travel in the
  /// synced record too, under refs that do not change when the value behind
  /// them is rotated, so nothing about a re-entered key moves the
  /// fingerprint. Trimmed, because whitespace is not a key and treating it
  /// as one stamps a write with no edit behind it.
  bool get keyEntered =>
      llmApiKey.trim().isNotEmpty || zaiApiKey.trim().isNotEmpty;

  factory AssistantDraft.fromJson(Map<String, dynamic> json) => AssistantDraft(
    fields: AssistantFields.fromJson(
      (json['fields'] as Map).cast<String, dynamic>(),
    ),
    llmApiKey: json['llmApiKey'] as String,
    zaiApiKey: json['zaiApiKey'] as String,
    versionSeen: json['versionSeen'] as int,
  );

  Map<String, dynamic> toJson() => {
    'fields': fields.toJson(),
    'llmApiKey': llmApiKey,
    'zaiApiKey': zaiApiKey,
    'versionSeen': versionSeen,
  };
}

/// Which key a failed keystore write was for.
enum AssistantKey { llm, zai }

enum AssistantSaveStatus {
  /// Written. The flags on the result say what else happened.
  saved,

  /// Refused before anything was written: another device's configuration was
  /// adopted after the fields were loaded, or during the keystore writes.
  /// The fields must be reloaded from [AssistantSaveResult.current] and the
  /// user asked to save again.
  adoptedBeforeSave,

  /// A key could not be stored, so nothing else was written.
  keystoreFailed,
}

@immutable
class AssistantSaveResult {
  const AssistantSaveResult({
    required this.status,
    required this.current,
    required this.version,
    this.failedKey,
    this.error,
    this.keysStored = false,
    this.publishError,
    this.reloadError,
    this.adoptedMeanwhile = false,
    this.zaiWithoutKey = false,
  });

  final AssistantSaveStatus status;

  /// The assistant settings as configured when the save finished, and the
  /// version they are at. The screen reloads its fields from these rather
  /// than from [SettingsBackend.settings], which in the settings window
  /// arrives separately and may not have caught up yet.
  final AssistantFields current;
  final int version;

  /// For [AssistantSaveStatus.keystoreFailed]: which key, and why.
  final AssistantKey? failedKey;
  final String? error;

  /// The keys in the draft reached the keystore, so the fields holding them
  /// can be cleared — if they still hold what was sent.
  final bool keysStored;

  /// Saved, but publishing to the synced record failed.
  final String? publishError;

  /// Saved, but the chat provider could not be rebuilt, so the assistant in
  /// this process is still the old one.
  final String? reloadError;

  /// Saved, but a sync round adopted another device's configuration during
  /// the save: [current] is that configuration, not this save's.
  final bool adoptedMeanwhile;

  /// Saved with Z.AI on, but no Z.AI key could be read afterwards.
  final bool zaiWithoutKey;

  factory AssistantSaveResult.fromJson(Map<String, dynamic> json) =>
      AssistantSaveResult(
        status: AssistantSaveStatus.values.byName(json['status'] as String),
        current: AssistantFields.fromJson(
          (json['current'] as Map).cast<String, dynamic>(),
        ),
        version: json['version'] as int,
        failedKey: json['failedKey'] == null
            ? null
            : AssistantKey.values.byName(json['failedKey'] as String),
        error: json['error'] as String?,
        keysStored: json['keysStored'] == true,
        publishError: json['publishError'] as String?,
        reloadError: json['reloadError'] as String?,
        adoptedMeanwhile: json['adoptedMeanwhile'] == true,
        zaiWithoutKey: json['zaiWithoutKey'] == true,
      );

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'current': current.toJson(),
    'version': version,
    if (failedKey != null) 'failedKey': failedKey!.name,
    if (error != null) 'error': error,
    'keysStored': keysStored,
    if (publishError != null) 'publishError': publishError,
    if (reloadError != null) 'reloadError': reloadError,
    'adoptedMeanwhile': adoptedMeanwhile,
    'zaiWithoutKey': zaiWithoutKey,
  };
}

/// The three sync switches after a write, which may have rolled some back.
@immutable
class SyncPrefsResult {
  const SyncPrefsResult({
    required this.autoSync,
    required this.syncSecrets,
    required this.syncAssistant,
    required this.current,
    required this.version,
    this.saveError,
    this.assistantSyncError,
    this.adopted = false,
  });

  /// What the switches are now: the values asked for, or the previous ones
  /// where a failure put them back.
  final bool autoSync;
  final bool syncSecrets;
  final bool syncAssistant;

  /// The assistant settings after the write, for [adopted].
  final AssistantFields current;
  final int version;

  /// The write itself failed; all three switches were put back.
  final String? saveError;

  /// Turning assistant sync on could not complete its first round; that
  /// switch was put back.
  final String? assistantSyncError;

  /// Turning assistant sync on adopted the account's configuration, which
  /// replaced this device's: the assistant fields must be reloaded.
  final bool adopted;

  factory SyncPrefsResult.fromJson(Map<String, dynamic> json) =>
      SyncPrefsResult(
        autoSync: json['autoSync'] as bool,
        syncSecrets: json['syncSecrets'] as bool,
        syncAssistant: json['syncAssistant'] as bool,
        current: AssistantFields.fromJson(
          (json['current'] as Map).cast<String, dynamic>(),
        ),
        version: json['version'] as int,
        saveError: json['saveError'] as String?,
        assistantSyncError: json['assistantSyncError'] as String?,
        adopted: json['adopted'] == true,
      );

  Map<String, dynamic> toJson() => {
    'autoSync': autoSync,
    'syncSecrets': syncSecrets,
    'syncAssistant': syncAssistant,
    'current': current.toJson(),
    'version': version,
    if (saveError != null) 'saveError': saveError,
    if (assistantSyncError != null) 'assistantSyncError': assistantSyncError,
    'adopted': adopted,
  };
}

/// "Fetch models": the endpoint as the form has it, and a typed key if any.
@immutable
class ModelQuery {
  const ModelQuery({
    required this.kind,
    required this.baseUrl,
    required this.model,
    required this.typedApiKey,
  });

  final LlmProviderKind kind;
  final String baseUrl;
  final String model;
  final String typedApiKey;

  factory ModelQuery.fromJson(Map<String, dynamic> json) => ModelQuery(
    kind: LlmProviderKind.values.byName(json['kind'] as String),
    baseUrl: json['baseUrl'] as String,
    model: json['model'] as String,
    typedApiKey: json['typedApiKey'] as String,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'baseUrl': baseUrl,
    'model': model,
    'typedApiKey': typedApiKey,
  };
}

/// A validated sync enrolment. The password and passphrase cross to the
/// app's isolate in memory only; neither is persisted by the transfer.
@immutable
class SyncEnrollment {
  const SyncEnrollment({
    required this.mode,
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.encryptionPassphrase,
  });

  final SyncEnrollmentMode mode;
  final String baseUrl;
  final String username;
  final String password;
  final String encryptionPassphrase;

  factory SyncEnrollment.fromJson(Map<String, dynamic> json) => SyncEnrollment(
    mode: SyncEnrollmentMode.values.byName(json['mode'] as String),
    baseUrl: json['baseUrl'] as String,
    username: json['username'] as String,
    password: json['password'] as String,
    encryptionPassphrase: json['encryptionPassphrase'] as String,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'baseUrl': baseUrl,
    'username': username,
    'password': password,
    'encryptionPassphrase': encryptionPassphrase,
  };
}

/// What a sync round moved.
@immutable
class SyncCounts {
  const SyncCounts({required this.pulled, required this.pushed});

  final int pulled;
  final int pushed;

  factory SyncCounts.fromJson(Map<String, dynamic> json) =>
      SyncCounts(pulled: json['pulled'] as int, pushed: json['pushed'] as int);

  Map<String, dynamic> toJson() => {'pulled': pulled, 'pushed': pushed};
}
