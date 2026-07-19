import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';

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

  // Web-search backend for the chat tool (local providers have no native one).
  String? searxngUrl;
  String? braveApiKeyRef;

  bool redactionEnabled;

  // Sync (optional).
  String? syncBaseUrl;
  String? syncUsername;

  /// Sync stored passwords / private keys too (opt-in — they're end-to-end
  /// encrypted, but syncing them widens their blast radius). Only servers whose
  /// own [ServerConfig.syncSecret] flag is set are included.
  bool syncSecrets;

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
    this.redactionEnabled = true,
    this.syncBaseUrl,
    this.syncUsername,
    this.syncSecrets = false,
    this.autoSync = true,
    this.commandSuggestions = false,
    this.checkForUpdates = true,
    EditorRegistry? editorRegistry,
    Map<String, List<String>>? remotePathBookmarks,
    Map<String, bool>? remoteShowHidden,
    Map<String, IdentityFileBookmark>? identityFileBookmarks,
    this.deviceId = '',
    this.snippetsSeeded = false,
  }) : editorRegistry = editorRegistry ?? EditorRegistry(),
       remotePathBookmarks = remotePathBookmarks ?? {},
       remoteShowHidden = remoteShowHidden ?? {},
       identityFileBookmarks = identityFileBookmarks ?? {};

  Map<String, dynamic> toJson() => {
    'llmKind': llmKind.name,
    'llmBaseUrl': llmBaseUrl,
    'llmModel': llmModel,
    'llmApiKeyRef': llmApiKeyRef,
    if (searxngUrl != null) 'searxngUrl': searxngUrl,
    if (braveApiKeyRef != null) 'braveApiKeyRef': braveApiKeyRef,
    'redactionEnabled': redactionEnabled,
    if (syncBaseUrl != null) 'syncBaseUrl': syncBaseUrl,
    if (syncUsername != null) 'syncUsername': syncUsername,
    'syncSecrets': syncSecrets,
    'autoSync': autoSync,
    'commandSuggestions': commandSuggestions,
    'checkForUpdates': checkForUpdates,
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
    redactionEnabled: json['redactionEnabled'] as bool? ?? true,
    syncBaseUrl: json['syncBaseUrl'] as String?,
    syncUsername: json['syncUsername'] as String?,
    syncSecrets: json['syncSecrets'] as bool? ?? false,
    autoSync: json['autoSync'] as bool? ?? true,
    commandSuggestions: json['commandSuggestions'] as bool? ?? false,
    checkForUpdates: json['checkForUpdates'] as bool? ?? true,
    editorRegistry: EditorRegistry.fromJson(
      json['editorRegistry'],
      legacyEditor: json['remoteFileEditor'],
    ),
    remotePathBookmarks: _bookmarkMap(json['remotePathBookmarks']),
    remoteShowHidden: _boolMap(json['remoteShowHidden']),
    identityFileBookmarks: _identityBookmarkMap(json['identityFileBookmarks']),
    deviceId: json['deviceId'] as String? ?? '',
    snippetsSeeded: json['snippetsSeeded'] as bool? ?? false,
  );
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
  SettingsStore(this.file);

  Future<AppSettings> load() async {
    if (!await file.exists()) return AppSettings();
    try {
      return AppSettings.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return AppSettings();
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
