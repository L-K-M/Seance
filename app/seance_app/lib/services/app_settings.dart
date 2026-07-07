import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';

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

  /// Stable per-device id used in synced records' conflict resolution.
  String deviceId;

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
    this.deviceId = '',
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
        'deviceId': deviceId,
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
        deviceId: json['deviceId'] as String? ?? '',
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
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}
