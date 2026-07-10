import 'dart:io';

import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import '../services/external_file_opener.dart';
import 'sync_enrollment_validation.dart';

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
  final _syncPassword = TextEditingController();
  final _syncEncryptionPassphrase = TextEditingController();
  final _syncEncryptionPassphraseConfirm = TextEditingController();

  late LlmProviderKind _kind;
  late bool _redaction;
  late bool _autoSync;
  late bool _syncSecrets;
  late bool _commandSuggestions;
  late bool _checkForUpdates;
  late RemoteFileEditor _remoteFileEditor;
  SyncEnrollmentMode _syncMode = SyncEnrollmentMode.login;
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
    _autoSync = s.autoSync;
    _syncSecrets = s.syncSecrets;
    _commandSuggestions = s.commandSuggestions;
    _checkForUpdates = s.checkForUpdates;
    _remoteFileEditor = s.remoteFileEditor;
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
      _syncPassword,
      _syncEncryptionPassphrase,
      _syncEncryptionPassphraseConfirm,
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
                child: Text('Anthropic (Claude)'),
              ),
              DropdownMenuItem(
                value: LlmProviderKind.openaiCompatible,
                child: Text('OpenAI-compatible (OpenAI, Ollama, …)'),
              ),
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
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
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
                initialValue: _models.contains(_model.text)
                    ? _model.text
                    : null,
                decoration: const InputDecoration(
                  labelText: 'Available models',
                ),
                items: [
                  for (final m in _models)
                    DropdownMenuItem(
                      value: m,
                      child: Text(m, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _model.text = v);
                },
              ),
            ),
          if (_modelsError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _modelsError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
              'Masks keys, tokens, and private keys in outbound context.',
            ),
            value: _redaction,
            onChanged: (v) => setState(() => _redaction = v),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<RemoteFileEditor>(
            initialValue: _remoteFileEditor,
            decoration: const InputDecoration(labelText: 'Remote file editor'),
            items: [
              const DropdownMenuItem(
                value: RemoteFileEditor.systemDefault,
                child: Text('System default'),
              ),
              if (Platform.isMacOS)
                const DropdownMenuItem(
                  value: RemoteFileEditor.bbedit,
                  child: Text('BBEdit'),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _remoteFileEditor = value);
              _persistFileEditor(state);
            },
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _saving ? null : () => _save(state),
            child: const Text('Save assistant settings'),
          ),
          const Divider(height: 40),
          _section('General'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Check for updates'),
            subtitle: const Text(
              'On launch, check GitHub for a newer release and show a '
              'notification. Only ever links to the releases page — never '
              'downloads or installs anything.',
            ),
            isThreeLine: true,
            value: _checkForUpdates,
            onChanged: (v) {
              setState(() => _checkForUpdates = v);
              _persistCheckForUpdates(state);
            },
          ),
          const Divider(height: 40),
          _section('Snippets'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Suggest frequently-used commands'),
            subtitle: const Text(
              'Tracks commands you run (on this device only) and offers the '
              'ones you repeat as snippets. Off by default — capture is '
              "keystroke-based and can't distinguish a command from a "
              'password typed at a prompt.',
            ),
            isThreeLine: true,
            value: _commandSuggestions,
            onChanged: (v) {
              setState(() => _commandSuggestions = v);
              _persistCommandSuggestions(state);
            },
          ),
          const Divider(height: 40),
          _section('Sync (optional)'),
          const Text(
            'Sync server configs across devices via your self-hosted server. '
            'Your account password signs in to the server. A separate vault '
            'encryption passphrase protects synced credentials end to end.',
          ),
          const SizedBox(height: 4),
          Text(
            'Existing account? Enter your old vault passphrase in both fields.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'The vault encryption passphrase cannot be recovered '
                    'through the sync server. Store it safely and use the same '
                    'one on every device.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sync automatically'),
            subtitle: const Text(
              'On startup, after you add/edit/remove a server, and every few '
              'minutes.',
            ),
            value: _autoSync,
            onChanged: (v) {
              setState(() => _autoSync = v);
              _persistSyncPrefs(state);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sync saved passwords & keys'),
            subtitle: const Text(
              'End-to-end encrypted. Only servers where you enable '
              '"Allow this credential to sync" are included.',
            ),
            isThreeLine: true,
            value: _syncSecrets,
            onChanged: (v) {
              setState(() => _syncSecrets = v);
              _persistSyncPrefs(state);
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _syncUrl,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://sync.example.com',
            ),
          ),
          TextField(
            controller: _syncUser,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<SyncEnrollmentMode>(
              segments: const [
                ButtonSegment(
                  value: SyncEnrollmentMode.login,
                  icon: Icon(Icons.login),
                  label: Text('Log in'),
                ),
                ButtonSegment(
                  value: SyncEnrollmentMode.register,
                  icon: Icon(Icons.person_add_alt_1),
                  label: Text('Register'),
                ),
              ],
              selected: {_syncMode},
              showSelectedIcon: false,
              onSelectionChanged: _saving
                  ? null
                  : (selection) => setState(() {
                      _syncMode = selection.first;
                      _syncStatus = null;
                    }),
            ),
          ),
          const SizedBox(height: 4),
          SyncEnrollmentFields(
            mode: _syncMode,
            passwordController: _syncPassword,
            encryptionPassphraseController: _syncEncryptionPassphrase,
            confirmationController: _syncEncryptionPassphraseConfirm,
          ),
          const SizedBox(height: 8),
          // Wrap (not Row) so the buttons flow onto multiple lines on narrow
          // phone screens instead of overflowing off the edge.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _saving ? null : () => _sync(state, mode: _syncMode),
                child: Text(
                  _syncMode == SyncEnrollmentMode.register
                      ? 'Create sync account'
                      : 'Log in on this device',
                ),
              ),
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
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) => _SyncStatusLine(state: state),
            ),
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
              apiKey: key,
              baseUrl: baseUrl,
              model: _model.text.trim(),
            )
          : OpenAiCompatibleProvider(
              baseUrl: baseUrl,
              apiKey: key,
              model: _model.text.trim(),
            );
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  /// Persist the sync preference toggles and (re)start the auto-sync timer.
  Future<void> _persistSyncPrefs(AppState state) async {
    final s = state.services.settings;
    s.autoSync = _autoSync;
    s.syncSecrets = _syncSecrets;
    await state.services.saveSettings();
    state.ensureAutoSyncTimer();
  }

  /// Persist the command-suggestions toggle and refresh the current list.
  Future<void> _persistCommandSuggestions(AppState state) async {
    state.services.settings.commandSuggestions = _commandSuggestions;
    await state.services.saveSettings();
    state.refreshSuggestions();
  }

  /// Persist the update-check toggle; turning it off also clears any banner
  /// already showing this session.
  Future<void> _persistCheckForUpdates(AppState state) async {
    state.services.settings.checkForUpdates = _checkForUpdates;
    await state.services.saveSettings();
    if (!_checkForUpdates) state.dismissUpdateNotice();
  }

  Future<void> _persistFileEditor(AppState state) async {
    state.services.settings.remoteFileEditor = _remoteFileEditor;
    await state.services.saveSettings();
  }

  Future<void> _sync(AppState state, {required SyncEnrollmentMode mode}) async {
    final register = mode == SyncEnrollmentMode.register;
    final validationError = validateSyncEnrollment(
      mode: mode,
      baseUrl: _syncUrl.text,
      username: _syncUser.text,
      password: _syncPassword.text,
      encryptionPassphrase: _syncEncryptionPassphrase.text,
      confirmationPassphrase: _syncEncryptionPassphraseConfirm.text,
    );
    if (validationError != null) {
      setState(() => _syncStatus = validationError);
      return;
    }

    setState(() {
      _saving = true;
      _syncStatus = register ? 'Registering…' : 'Logging in…';
    });
    try {
      if (register) {
        await state.services.registerSync(
          baseUrl: _syncUrl.text.trim(),
          username: _syncUser.text.trim(),
          password: _syncPassword.text,
          encryptionPassphrase: _syncEncryptionPassphrase.text,
        );
      } else {
        await state.services.loginSync(
          baseUrl: _syncUrl.text.trim(),
          username: _syncUser.text.trim(),
          password: _syncPassword.text,
          encryptionPassphrase: _syncEncryptionPassphrase.text,
        );
      }
      // Schedule periodic sync if enabled, then always verify enrollment with
      // one immediate round.
      state.ensureAutoSyncTimer();
      if (mounted) {
        setState(() => _syncStatus = 'Connected. Synchronizing…');
      }
      await state.syncNow();
      if (mounted) setState(() => _syncStatus = 'Connected and synced.');
    } catch (e) {
      if (mounted) setState(() => _syncStatus = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _syncNow(AppState state) async {
    setState(() {
      _saving = true;
      _syncStatus = 'Syncing…';
    });
    try {
      final outcome = await state.syncNow();
      if (mounted) {
        setState(
          () => _syncStatus =
              'Synced: pulled ${outcome.pulled}, pushed ${outcome.pushed}.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _syncStatus = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// The mode-specific secret fields for sync enrollment.
@visibleForTesting
class SyncEnrollmentFields extends StatelessWidget {
  const SyncEnrollmentFields({
    super.key,
    required this.mode,
    required this.passwordController,
    required this.encryptionPassphraseController,
    required this.confirmationController,
  });

  final SyncEnrollmentMode mode;
  final TextEditingController passwordController;
  final TextEditingController encryptionPassphraseController;
  final TextEditingController confirmationController;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextField(
        key: const ValueKey('sync-account-password'),
        controller: passwordController,
        obscureText: true,
        autofillHints: [
          mode == SyncEnrollmentMode.register
              ? AutofillHints.newPassword
              : AutofillHints.password,
        ],
        decoration: const InputDecoration(
          labelText: 'Account password',
          helperText: 'Authenticates with the sync server.',
        ),
      ),
      TextField(
        key: const ValueKey('sync-encryption-passphrase'),
        controller: encryptionPassphraseController,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Vault encryption passphrase',
          helperText: 'Encrypts synced credentials; use it on every device.',
        ),
      ),
      if (mode == SyncEnrollmentMode.register)
        TextField(
          key: const ValueKey('sync-encryption-passphrase-confirmation'),
          controller: confirmationController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Confirm vault encryption passphrase',
          ),
        ),
    ],
  );
}

/// A live, one-line reflection of the app-wide sync state (also updated by
/// automatic background syncs, not just the buttons above).
class _SyncStatusLine extends StatelessWidget {
  final AppState state;
  const _SyncStatusLine({required this.state});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    if (state.syncing) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('Syncing…', style: style),
        ],
      );
    }
    if (state.lastSyncError != null) {
      return Text(
        'Last sync failed: ${state.lastSyncError}',
        style: style?.copyWith(color: scheme.error),
      );
    }
    if (state.lastSyncAt != null) {
      return Text('Last synced ${_ago(state.lastSyncAt!)}.', style: style);
    }
    return const SizedBox.shrink();
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}
