import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';

/// Settings: LLM provider (the assistant is always on — this only picks which
/// model), the web-search backend, secret redaction, and sync enrolment.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _baseUrl = TextEditingController();
  late final _model = TextEditingController();
  late final _apiKey = TextEditingController();
  late final _searxng = TextEditingController();
  late final _syncUrl = TextEditingController();
  late final _syncUser = TextEditingController();
  final _syncPass = TextEditingController();

  late LlmProviderKind _kind;
  late bool _redaction;
  bool _saving = false;
  String? _syncStatus;

  // Model discovery.
  List<String> _models = [];
  bool _loadingModels = false;
  String? _modelsError;

  @override
  void initState() {
    super.initState();
    // Deferred to didChangeDependencies to read AppScope.
  }

  bool _initialized = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final s = AppScope.of(context).services.settings;
    _kind = s.llmKind;
    _baseUrl.text = s.llmBaseUrl;
    _model.text = s.llmModel;
    _searxng.text = s.searxngUrl ?? '';
    _redaction = s.redactionEnabled;
    _syncUrl.text = s.syncBaseUrl ?? '';
    _syncUser.text = s.syncUsername ?? '';
  }

  @override
  void dispose() {
    for (final c in [
      _baseUrl,
      _model,
      _apiKey,
      _searxng,
      _syncUrl,
      _syncUser,
      _syncPass
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('Assistant'),
          DropdownButtonFormField<LlmProviderKind>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: const [
              DropdownMenuItem(
                  value: LlmProviderKind.anthropic,
                  child: Text('Anthropic (Claude)')),
              DropdownMenuItem(
                  value: LlmProviderKind.openaiCompatible,
                  child: Text('OpenAI-compatible (OpenAI, Ollama, …)')),
            ],
            onChanged: (v) => setState(() {
              _kind = v ?? LlmProviderKind.anthropic;
              // Helpful defaults per provider.
              if (_kind == LlmProviderKind.anthropic) {
                _baseUrl.text = 'https://api.anthropic.com';
                _model.text = 'claude-haiku-4-5-20251001';
              } else {
                _baseUrl.text = 'http://localhost:11434/v1';
                _model.text = 'llama3.1';
              }
            }),
          ),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(labelText: 'Base URL'),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: 'Model',
                    helperText: 'Pick from the list, or type any model id',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _loadingModels
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : OutlinedButton.icon(
                        onPressed: () => _fetchModels(state),
                        icon: const Icon(Icons.playlist_add_check, size: 18),
                        label: const Text('Suggest'),
                      ),
              ),
            ],
          ),
          if (_models.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _models.contains(_model.text) ? _model.text : null,
                decoration:
                    const InputDecoration(labelText: 'Available models'),
                items: [
                  for (final m in _models)
                    DropdownMenuItem(
                        value: m,
                        child: Text(m, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _model.text = v);
                },
              ),
            ),
          if (_modelsError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_modelsError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API key (stored in OS keystore, never synced)',
              hintText: 'leave blank to keep the existing key / keyless local',
            ),
          ),
          const SizedBox(height: 16),
          _section('Web search (chat tool)'),
          TextField(
            controller: _searxng,
            decoration: const InputDecoration(
              labelText: 'SearXNG URL (optional)',
              hintText: 'https://searx.example.com',
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Redact secrets before sending'),
            subtitle: const Text(
                'Masks keys, tokens, and private keys in outbound context.'),
            value: _redaction,
            onChanged: (v) => setState(() => _redaction = v),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _saving ? null : () => _save(state),
            child: const Text('Save assistant settings'),
          ),
          const Divider(height: 40),
          _section('Sync (optional)'),
          const Text(
            'Sync server configs across devices via your self-hosted server. '
            'The passphrase derives the end-to-end key — set it up before '
            'storing secrets you want synced.',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _syncUrl,
            decoration: const InputDecoration(
                labelText: 'Server URL', hintText: 'https://sync.example.com'),
          ),
          TextField(
            controller: _syncUser,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          TextField(
            controller: _syncPass,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Vault passphrase'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                onPressed: _saving ? null : () => _sync(state, register: true),
                child: const Text('Register'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _saving ? null : () => _sync(state, register: false),
                child: const Text('Log in on this device'),
              ),
              const Spacer(),
              FilledButton.tonal(
                onPressed: _saving ? null : () => _syncNow(state),
                child: const Text('Sync now'),
              ),
            ],
          ),
          if (_syncStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_syncStatus!),
            ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  /// Ask the configured endpoint which models it offers. Uses the key typed in
  /// the form if present, otherwise the stored one; keyless local endpoints
  /// (Ollama) need none. The manual field remains the fallback if this fails or
  /// the list omits the model the user wants.
  Future<void> _fetchModels(AppState state) async {
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final ref = _kind == LlmProviderKind.anthropic ? 'anthropic' : 'openai';
      final key = _apiKey.text.isNotEmpty
          ? _apiKey.text
          : (await state.services.masterKeys.getApiKey(ref) ?? '');
      final baseUrl = _baseUrl.text.trim();
      final LlmProvider provider = _kind == LlmProviderKind.anthropic
          ? AnthropicProvider(
              apiKey: key, baseUrl: baseUrl, model: _model.text.trim())
          : OpenAiCompatibleProvider(
              baseUrl: baseUrl, apiKey: key, model: _model.text.trim());
      final models = await provider.listModels();
      models.sort();
      setState(() {
        _models = models;
        if (models.isEmpty) {
          _modelsError = 'The endpoint returned no models.';
        }
      });
    } catch (e) {
      setState(() => _modelsError = 'Could not fetch models: $e');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _save(AppState state) async {
    setState(() => _saving = true);
    final s = state.services.settings;
    s.llmKind = _kind;
    s.llmBaseUrl = _baseUrl.text.trim();
    s.llmModel = _model.text.trim();
    s.redactionEnabled = _redaction;
    s.searxngUrl = _searxng.text.trim().isEmpty ? null : _searxng.text.trim();
    // Store the API key under a per-provider name.
    final ref = _kind == LlmProviderKind.anthropic ? 'anthropic' : 'openai';
    s.llmApiKeyRef = ref;
    if (_apiKey.text.isNotEmpty) {
      await state.services.masterKeys.putApiKey(ref, _apiKey.text);
    }
    await state.services.saveSettings();
    // Rebuild the chat provider (new key/model) and refresh sidebar visibility.
    await state.reloadLlmProvider();
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  Future<void> _sync(AppState state, {required bool register}) async {
    setState(() {
      _saving = true;
      _syncStatus = register ? 'Registering…' : 'Logging in…';
    });
    try {
      if (register) {
        await state.services.registerSync(
          baseUrl: _syncUrl.text.trim(),
          username: _syncUser.text.trim(),
          passphrase: _syncPass.text,
        );
      } else {
        await state.services.loginSync(
          baseUrl: _syncUrl.text.trim(),
          username: _syncUser.text.trim(),
          passphrase: _syncPass.text,
        );
      }
      setState(() => _syncStatus = 'Connected. Use "Sync now" to synchronize.');
    } catch (e) {
      setState(() => _syncStatus = 'Failed: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _syncNow(AppState state) async {
    setState(() {
      _saving = true;
      _syncStatus = 'Syncing…';
    });
    try {
      final outcome = await state.syncNow();
      setState(() => _syncStatus =
          'Synced: pulled ${outcome.pulled}, pushed ${outcome.pushed}.');
    } catch (e) {
      setState(() => _syncStatus = 'Failed: $e');
    } finally {
      setState(() => _saving = false);
    }
  }
}
