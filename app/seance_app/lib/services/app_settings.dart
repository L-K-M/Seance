import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

import '../ui/terminal_appearance.dart';
import 'atomic_file.dart';
import 'external_file_opener.dart';

/// A macOS security-scoped bookmark for a Browse…-picked identity file,
/// together with the identity-file [path] it was minted for. The path pins
/// the grant to the config it belongs to: when a server's identityFilePath
/// changes without going through this device's editor (a synced edit — e.g.
/// a key rotation on another device), the mismatch disqualifies the bookmark
/// so the configured path wins over the stale grant.
class IdentityFileBookmark {
  final String path;
  final String bookmark; // base64 security-scoped bookmark data
  const IdentityFileBookmark({required this.path, required this.bookmark});

  Map<String, dynamic> toJson() => {'path': path, 'bookmark': bookmark};

  static IdentityFileBookmark? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    final bookmark = json['bookmark'];
    if (path is! String || bookmark is! String || bookmark.isEmpty) {
      return null;
    }
    return IdentityFileBookmark(path: path, bookmark: bookmark);
  }

  @override
  bool operator ==(Object other) =>
      other is IdentityFileBookmark &&
      other.path == path &&
      other.bookmark == bookmark;

  @override
  int get hashCode => Object.hash(path, bookmark);
}

/// User-configurable settings. The LLM assistant is always on (this is a
/// personal tool), so there is no enable flag — only which provider it uses.
/// Secret redaction defaults on and is a single global toggle.
class AppSettings {
  // LLM provider.
  LlmProviderKind llmKind;
  String llmBaseUrl;
  String llmModel;
  String llmApiKeyRef; // keystore entry name; empty for keyless local Ollama

  // Web-search backends for the chat tool (local providers have no native
  // one). Every configured backend is used and their results merged, so
  // leaving one blank is how you get "instead of" and filling both is how you
  // get "in addition to" — see `CompositeSearch`.
  String? searxngUrl;
  String? braveApiKeyRef;

  /// Keystore entry name for the Z.AI key, or null when Z.AI web search is
  /// off. Like every other key reference this holds the *name*, never the key.
  String? zaiApiKeyRef;

  bool redactionEnabled;

  /// When the assistant's configuration was last edited on any device, or 0
  /// while it has never been published.
  ///
  /// It is the synced record's `updatedAt`, so it must move only on a real
  /// edit: sync re-collects every round, and a "now" timestamp would make each
  /// one a fresh winning write with two devices trading the record forever.
  /// Zero also serves as "nothing to publish", which keeps two fresh installs
  /// from pushing rival defaults before either has configured anything.
  int assistantUpdatedAt;

  // Sync (optional).
  String? syncBaseUrl;
  String? syncUsername;

  /// Sync stored passwords / private keys too (opt-in — they're end-to-end
  /// encrypted, but syncing them widens their blast radius). Only servers whose
  /// own [ServerConfig.syncSecret] flag is set are included.
  bool syncSecrets;

  /// Sync the assistant's configuration — provider, model, endpoint, web
  /// search and redaction — together with its API keys. Opt-in and off by
  /// default, like [syncSecrets] and for the same reason: the record is
  /// end-to-end encrypted, but keys that exist on one device are a smaller
  /// blast radius than keys that exist on all of them.
  ///
  /// The keys travel with the settings rather than behind a second switch. A
  /// provider and model without the key to use them leaves the other device
  /// looking configured and answering nothing, which is a worse place to be
  /// than either syncing or not.
  bool syncAssistant;

  /// Whether sync runs automatically (on startup, after edits, and on a timer).
  /// On by default once sync is set up; the manual "Sync now" button always works.
  bool autoSync;

  /// Track submitted commands locally to suggest frequently-run ones as
  /// snippets. Off by default: capture is keystroke-based and can't tell a
  /// shell command from text typed at a no-echo prompt, so the user opts in.
  bool commandSuggestions;

  /// On launch, check GitHub for a newer release and show a notification if
  /// one exists. On by default; only ever offers a link to the releases page —
  /// never downloads or installs anything.
  bool checkForUpdates;

  /// Keep SSH sessions alive while the app is backgrounded (Android: a
  /// foreground-service anchor). On by default — without it, Android freezes
  /// the cached process and every connection drops within moments of leaving
  /// the screen. Device-local by design: it is a battery-life trade-off, not
  /// an account property.
  bool keepSessionsAliveInBackground;

  /// Built-in/system/custom editors for managed remote-file checkouts. Local
  /// only: installed applications and executable paths are never synced.
  EditorRegistry editorRegistry;

  /// Canonical SFTP paths bookmarked per server. Local navigation preference;
  /// credentials and remote contents are never stored here.
  Map<String, List<String>> remotePathBookmarks;
  Map<String, bool> remoteShowHidden;

  /// macOS security-scoped bookmarks for Browse…-picked identity files, keyed
  /// by server id. Deliberately device-local (settings never sync): a bookmark
  /// only means anything to the app + machine that minted it — other devices
  /// fall back to the server's identity file *path*.
  Map<String, IdentityFileBookmark> identityFileBookmarks;

  /// Server-list group sections the user has folded away, by
  /// [serverGroupKey]. Device-local for the same reason the pane widths are:
  /// which sections are folded is a property of the window in front of you,
  /// not of the account. The *grouping* itself lives on the server configs and
  /// does sync.
  Set<String> collapsedServerGroups;

  /// Terminal appearance. Device-local by design: the right font size depends
  /// on the screen in front of you, not on the account, so these never sync.
  double terminalFontSize;

  /// Preferred monospace family for the terminal grid. Empty means "use the
  /// app's own stack" ([SeanceTheme.monoFallback]).
  String terminalFontFamily;
  TerminalPalette terminalPalette;

  /// Stable per-device id used in synced records' conflict resolution.
  String deviceId;

  /// Whether the built-in default snippets have been seeded (one-time, so
  /// deleting them all doesn't bring them back).
  bool snippetsSeeded;

  AppSettings({
    this.llmKind = LlmProviderKind.anthropic,
    this.llmBaseUrl = 'https://api.anthropic.com',
    this.llmModel = 'claude-haiku-4-5-20251001',
    this.llmApiKeyRef = 'anthropic',
    this.searxngUrl,
    this.braveApiKeyRef,
    this.zaiApiKeyRef,
    this.redactionEnabled = true,
    this.assistantUpdatedAt = 0,
    this.syncBaseUrl,
    this.syncUsername,
    this.syncSecrets = false,
    this.syncAssistant = false,
    this.autoSync = true,
    this.commandSuggestions = false,
    this.checkForUpdates = true,
    this.keepSessionsAliveInBackground = true,
    EditorRegistry? editorRegistry,
    Map<String, List<String>>? remotePathBookmarks,
    Map<String, bool>? remoteShowHidden,
    Map<String, IdentityFileBookmark>? identityFileBookmarks,
    Set<String>? collapsedServerGroups,
    this.terminalFontSize = kDefaultTerminalFontSize,
    this.terminalFontFamily = '',
    this.terminalPalette = TerminalPalette.followApp,
    this.deviceId = '',
    this.snippetsSeeded = false,
  }) : editorRegistry = editorRegistry ?? EditorRegistry(),
       remotePathBookmarks = remotePathBookmarks ?? {},
       remoteShowHidden = remoteShowHidden ?? {},
       identityFileBookmarks = identityFileBookmarks ?? {},
       collapsedServerGroups = collapsedServerGroups ?? {};

  Map<String, dynamic> toJson() => {
    'llmKind': llmKind.name,
    'llmBaseUrl': llmBaseUrl,
    'llmModel': llmModel,
    'llmApiKeyRef': llmApiKeyRef,
    if (searxngUrl != null) 'searxngUrl': searxngUrl,
    if (braveApiKeyRef != null) 'braveApiKeyRef': braveApiKeyRef,
    if (zaiApiKeyRef != null) 'zaiApiKeyRef': zaiApiKeyRef,
    'redactionEnabled': redactionEnabled,
    'assistantUpdatedAt': assistantUpdatedAt,
    if (syncBaseUrl != null) 'syncBaseUrl': syncBaseUrl,
    if (syncUsername != null) 'syncUsername': syncUsername,
    'syncSecrets': syncSecrets,
    'syncAssistant': syncAssistant,
    'autoSync': autoSync,
    'commandSuggestions': commandSuggestions,
    'checkForUpdates': checkForUpdates,
    'keepSessionsAliveInBackground': keepSessionsAliveInBackground,
    'editorRegistry': editorRegistry.toJson(),
    // Keep old versions on a safe supported default if settings are downgraded.
    'remoteFileEditor':
        editorRegistry.defaultEditorId == EditorRegistry.migratedBbeditId
        ? 'bbedit'
        : 'systemDefault',
    'remotePathBookmarks': remotePathBookmarks,
    'remoteShowHidden': remoteShowHidden,
    'identityFileBookmarks': identityFileBookmarks
        .map((id, entry) => MapEntry(id, entry.toJson())),
    // Sorted so an unchanged set writes byte-identical JSON — the settings
    // file is rewritten on every save, and a set's iteration order would
    // otherwise make each one look like a change.
    'collapsedServerGroups': collapsedServerGroups.toList()..sort(),
    'terminalFontSize': terminalFontSize,
    'terminalFontFamily': terminalFontFamily,
    'terminalPalette': terminalPalette.name,
    'deviceId': deviceId,
    'snippetsSeeded': snippetsSeeded,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    llmKind: LlmProviderKind.values.firstWhere(
      (k) => k.name == json['llmKind'],
      orElse: () => LlmProviderKind.anthropic,
    ),
    llmBaseUrl: json['llmBaseUrl'] as String? ?? 'https://api.anthropic.com',
    llmModel: json['llmModel'] as String? ?? 'claude-haiku-4-5-20251001',
    llmApiKeyRef: json['llmApiKeyRef'] as String? ?? 'anthropic',
    searxngUrl: json['searxngUrl'] as String?,
    braveApiKeyRef: json['braveApiKeyRef'] as String?,
    zaiApiKeyRef: json['zaiApiKeyRef'] as String?,
    redactionEnabled: json['redactionEnabled'] as bool? ?? true,
    assistantUpdatedAt: (json['assistantUpdatedAt'] as num?)?.toInt() ?? 0,
    syncBaseUrl: json['syncBaseUrl'] as String?,
    syncUsername: json['syncUsername'] as String?,
    syncSecrets: json['syncSecrets'] as bool? ?? false,
    syncAssistant: json['syncAssistant'] as bool? ?? false,
    autoSync: json['autoSync'] as bool? ?? true,
    commandSuggestions: json['commandSuggestions'] as bool? ?? false,
    checkForUpdates: json['checkForUpdates'] as bool? ?? true,
    keepSessionsAliveInBackground:
        json['keepSessionsAliveInBackground'] as bool? ?? true,
    editorRegistry: EditorRegistry.fromJson(
      json['editorRegistry'],
      legacyEditor: json['remoteFileEditor'],
    ),
    remotePathBookmarks: _bookmarkMap(json['remotePathBookmarks']),
    remoteShowHidden: _boolMap(json['remoteShowHidden']),
    identityFileBookmarks: _identityBookmarkMap(json['identityFileBookmarks']),
    collapsedServerGroups: _stringSet(json['collapsedServerGroups']),
    // Clamped on read: a hand-edited or downgraded settings file must never be
    // able to render the terminal at an unusable size.
    terminalFontSize: clampTerminalFontSize(
      (json['terminalFontSize'] as num?)?.toDouble() ??
          kDefaultTerminalFontSize,
    ),
    terminalFontFamily: json['terminalFontFamily'] as String? ?? '',
    terminalPalette: TerminalPalette.values.firstWhere(
      (p) => p.name == json['terminalPalette'],
      orElse: () => TerminalPalette.followApp,
    ),
    deviceId: json['deviceId'] as String? ?? '',
    snippetsSeeded: json['snippetsSeeded'] as bool? ?? false,
  );
}

/// Recover the few fields that are expensive to lose from the raw text of an
/// unparseable settings file.
///
/// [AppSettings.deviceId] matters most: it is the tiebreaker in `Lww.resolve`,
/// so a device that comes back with a fresh id re-enters sync as a stranger and
/// its existing records lose their authorship for conflict resolution. The sync
/// server and username are recovered too, so re-enrolment does not start from a
/// blank form. Nothing here is trusted beyond its shape — the values are plain
/// strings that go straight back through the normal accessors.
AppSettings salvageSettings(String? raw) {
  final settings = AppSettings();
  if (raw == null) return settings;
  /// Best effort on a document that cannot be parsed. The key must sit where a
  /// key can sit — at the start, or after a `{` or `,` — which keeps the name
  /// from being picked up out of the middle of some other string's contents.
  /// It still cannot tell nesting apart (a `{"editors":{"deviceId":…}}` looks
  /// identical to the real thing), and a wrong salvage stays bounded by being
  /// a string that goes back through the normal accessors.
  String? field(String name) {
    final match = RegExp(
      '(?:^|[,{])\\s*"$name"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"',
    ).firstMatch(raw);
    final value = match?.group(1);
    if (value == null) return null;
    try {
      // The capture is still JSON-escaped. Decode it as a JSON string so an
      // escaped quote or backslash survives rather than truncating the value —
      // a half-salvaged deviceId would defeat the point of salvaging at all.
      return jsonDecode('"$value"') as String;
    } catch (_) {
      return value;
    }
  }

  final deviceId = field('deviceId');
  if (deviceId != null && deviceId.isNotEmpty) settings.deviceId = deviceId;
  final syncBaseUrl = field('syncBaseUrl');
  if (syncBaseUrl != null && syncBaseUrl.isNotEmpty) {
    settings.syncBaseUrl = syncBaseUrl;
  }
  final syncUsername = field('syncUsername');
  if (syncUsername != null && syncUsername.isNotEmpty) {
    settings.syncUsername = syncUsername;
  }
  return settings;
}

Map<String, IdentityFileBookmark> _identityBookmarkMap(Object? value) {
  if (value is! Map) return {};
  final result = <String, IdentityFileBookmark>{};
  for (final entry in value.entries) {
    if (entry.key is! String) continue;
    final bookmark = IdentityFileBookmark.fromJson(entry.value);
    if (bookmark != null) result[entry.key as String] = bookmark;
  }
  return result;
}

/// A tolerant string set: anything that isn't a list of strings reads as empty,
/// like every other collection here. A stale key for a group that no longer
/// exists is harmless — nothing looks it up — so entries are not validated
/// against the current servers.
Set<String> _stringSet(Object? value) {
  if (value is! List) return {};
  return value.whereType<String>().toSet();
}

Map<String, bool> _boolMap(Object? value) {
  if (value is! Map) return {};
  return {
    for (final entry in value.entries)
      if (entry.key is String && entry.value is bool)
        entry.key as String: entry.value as bool,
  };
}

Map<String, List<String>> _bookmarkMap(Object? value) {
  if (value is! Map) return {};
  final result = <String, List<String>>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! List) continue;
    final paths =
        (entry.value as List)
            .whereType<String>()
            .where((path) => path.startsWith('/') && !path.contains('\u0000'))
            .toSet()
            .toList()
          ..sort();
    if (paths.isNotEmpty) result[entry.key as String] = paths;
  }
  return result;
}

class SettingsStore {
  final File file;
  Future<void> _saveTail = Future<void>.value();

  bool _recoveredFromCorruptFile = false;

  /// True when [load] could not parse the settings file and started from
  /// defaults. The bad file is moved aside rather than overwritten, and the app
  /// says so — silently resetting the sync server, the provider configuration
  /// and the editor registry is not something the user should have to discover.
  bool get recoveredFromCorruptFile => _recoveredFromCorruptFile;

  SettingsStore(this.file);

  Future<AppSettings> load() async {
    if (!await file.exists()) return AppSettings();
    String? raw;
    try {
      raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('settings root is not an object');
      }
      return AppSettings.fromJson(decoded);
    } catch (_) {
      // Every other JSON store in the app quarantines an unreadable file; this
      // one used to overwrite it with defaults on the next save, which made the
      // loss permanent and unrecoverable.
      _recoveredFromCorruptFile = true;
      final salvaged = salvageSettings(raw);
      try {
        await quarantineCorruptFile(file);
        // Write the salvage back immediately, through the same atomic path as
        // any other save. Without this it would live only in memory: the bad
        // file has been moved aside, so the next launch would find nothing,
        // fall back to defaults, and mint the fresh deviceId this is here to
        // avoid.
        await save(salvaged);
      } catch (error) {
        // Recovering is best effort. A read-only or full disk must not turn an
        // unreadable settings file into a failed launch — the app runs on the
        // salvaged values and tries again next time. Logged rather than
        // swallowed outright: if it keeps failing, the recovery notice will
        // reappear every launch and this says why.
        debugPrint('Settings recovery could not be written back: $error');
      }
      return salvaged;
    }
  }

  Future<void> save(AppSettings settings) {
    final snapshot = jsonEncode(settings.toJson());
    final result = Completer<void>();
    _saveTail = _saveTail.then((_) async {
      try {
        await writeStringAtomically(file, snapshot);
        result.complete();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}
