import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';

import 'atomic_file.dart';

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
    this.deviceId = '',
    this.snippetsSeeded = false,
  });

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
        'deviceId': deviceId,
        'snippetsSeeded': snippetsSeeded,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        llmKind: LlmProviderKind.values.firstWhere(
            (k) => k.name == json['llmKind'],
            orElse: () => LlmProviderKind.anthropic),
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
        deviceId: json['deviceId'] as String? ?? '',
        snippetsSeeded: json['snippetsSeeded'] as bool? ?? false,
      );
}

class SettingsStore {
  final File file;
  SettingsStore(this.file);

  Future<AppSettings> load() async {
    if (!await file.exists()) return AppSettings();
    try {
      return AppSettings.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    await writeStringAtomically(file, jsonEncode(settings.toJson()));
  }
}
