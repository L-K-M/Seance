import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import '../services/external_file_opener.dart';
import 'sync_enrollment_validation.dart';

/// Settings: LLM provider (the assistant is always on — this only picks which
/// model), the web-search backend, secret redaction, and sync enrolment.
enum SettingsTab { general, assistant, files, sync }

class SettingsScreen extends StatefulWidget {
  final SettingsTab initialTab;

  const SettingsScreen({super.key, this.initialTab = SettingsTab.general});

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
  late EditorRegistry _editorRegistry;
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
    _editorRegistry = s.editorRegistry;
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
    return DefaultTabController(
      length: SettingsTab.values.length,
      initialIndex: widget.initialTab.index,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(icon: Icon(Icons.tune_outlined), text: 'General'),
              Tab(icon: Icon(Icons.auto_awesome_outlined), text: 'Assistant'),
              Tab(icon: Icon(Icons.folder_open_outlined), text: 'Files'),
              Tab(icon: Icon(Icons.cloud_sync_outlined), text: 'Sync'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _generalTab(state),
            _assistantTab(state),
            _filesTab(state),
            _syncTab(state),
          ],
        ),
      ),
    );
  }

  Widget _assistantTab(AppState state) => _settingsPage(
    key: const PageStorageKey('assistant-settings'),
    children: [
      _section(
        'Assistant',
        helpTitle: 'Assistant privacy and providers',
        help:
            'Terminal context is treated as untrusted and secret redaction '
            'is enabled by default. Generated commands are inserted for '
            'review and are never executed automatically.',
      ),
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
      LayoutBuilder(
        builder: (context, constraints) {
          final field = TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: 'Model',
              helperText: 'Pick from the list, or type any model id',
            ),
          );
          final action = _loadingModels
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : OutlinedButton.icon(
                  onPressed: () => _fetchModels(state),
                  icon: const Icon(Icons.playlist_add_check, size: 18),
                  label: const Text('Fetch models'),
                );
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field,
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: action),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: field),
              const SizedBox(width: 8),
              Padding(padding: const EdgeInsets.only(bottom: 4), child: action),
            ],
          );
        },
      ),
      if (_models.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _models.contains(_model.text) ? _model.text : null,
            decoration: const InputDecoration(labelText: 'Available models'),
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
      FilledButton(
        onPressed: _saving ? null : () => _save(state),
        child: const Text('Save assistant settings'),
      ),
    ],
  );

  Widget _generalTab(AppState state) => _settingsPage(
    key: const PageStorageKey('general-settings'),
    children: [
      _section(
        'General',
        helpTitle: 'General preferences',
        help:
            'These preferences are local to this device and save immediately.',
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Check for updates'),
        subtitle: const Text(
          'Checks GitHub on launch and only links to the release page.',
        ),
        value: _checkForUpdates,
        onChanged: (value) {
          setState(() => _checkForUpdates = value);
          _persistCheckForUpdates(state);
        },
      ),
      const Divider(height: 40),
      _section(
        'Snippets',
        helpTitle: 'Command suggestions',
        help:
            'Command capture is keystroke-based and local. It cannot always '
            'distinguish a shell command from text entered at a hidden prompt.',
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Suggest frequently-used commands'),
        subtitle: const Text(
          'Tracks commands on this device and offers repeated ones as snippets.',
        ),
        value: _commandSuggestions,
        onChanged: (value) {
          setState(() => _commandSuggestions = value);
          _persistCommandSuggestions(state);
        },
      ),
    ],
  );

  Widget _filesTab(AppState state) {
    final defaultItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: EditorRegistry.builtInId,
        child: Text('Built-in text editor'),
      ),
      if (currentEditorHostPlatform != null)
        const DropdownMenuItem(
          value: EditorRegistry.systemDefaultId,
          child: Text('System default'),
        ),
      for (final editor in _editorRegistry.editors)
        DropdownMenuItem(
          value: editor.id,
          enabled: editor.isAvailableOnCurrentPlatform,
          child: Text(
            editor.isAvailableOnCurrentPlatform
                ? editor.displayName
                : '${editor.displayName} (another platform)',
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
    return _settingsPage(
      key: const PageStorageKey('files-settings'),
      children: [
        _section(
          'Remote file editing',
          helpTitle: 'How remote editing works',
          help:
              'Séance downloads a private managed copy, watches it for saves, '
              'and checks the remote SHA-256 before upload. Saving never silently '
              'overwrites the server. The built-in editor supports UTF-8 text up '
              'to 4 MB and is available on mobile and desktop.',
        ),
        DropdownButtonFormField<String>(
          initialValue: _editorRegistry.defaultEditorId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Default editor'),
          items: defaultItems,
          onChanged: (value) {
            if (value == null) return;
            setState(() => _editorRegistry.defaultEditorId = value);
            _persistEditorRegistry(state);
          },
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(child: _section('External editors')),
            if (currentEditorHostPlatform != null)
              OutlinedButton.icon(
                onPressed: () => _addEditor(state),
                icon: const Icon(Icons.add),
                label: const Text('Add editor'),
              ),
          ],
        ),
        if (currentEditorHostPlatform == null)
          Text(
            'The built-in editor is used on mobile. External in-place editing '
            'is available on desktop.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else if (_editorRegistry.editors.isEmpty)
          Text(
            'No external applications configured. Add one to make it available '
            'in each file’s Open with menu.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          for (final editor in _editorRegistry.editors)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                editor.isAvailableOnCurrentPlatform
                    ? Icons.open_in_new
                    : Icons.devices_other,
              ),
              title: Text(editor.displayName),
              subtitle: Text(
                editor.acceptedExtensions.isEmpty
                    ? '${editor.launchTarget}\nAccepts all files'
                    : '${editor.launchTarget}\n${editor.acceptedExtensions.map((value) => '*.$value').join(', ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _editEditor(state, editor),
              trailing: PopupMenuButton<String>(
                tooltip: 'Editor actions',
                onSelected: (action) {
                  if (action == 'edit') _editEditor(state, editor);
                  if (action == 'remove') _removeEditor(state, editor);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit…')),
                  PopupMenuItem(value: 'remove', child: Text('Remove…')),
                ],
              ),
            ),
      ],
    );
  }

  Widget _syncTab(AppState state) => _settingsPage(
    key: const PageStorageKey('sync-settings'),
    children: [
      _section(
        'Sync (optional)',
        helpTitle: 'Account and vault credentials',
        help:
            'The account password authenticates with your self-hosted sync '
            'server. A separate passphrase encrypts synced credentials end '
            'to end and cannot be recovered by the server.',
      ),
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
            Icon(
              Icons.warning_amber_rounded,
              size: 20,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
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
          'Runs on startup, after edits, and every few minutes.',
        ),
        value: _autoSync,
        onChanged: (value) {
          setState(() => _autoSync = value);
          _persistSyncPrefs(state);
        },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Sync saved passwords & keys'),
        subtitle: const Text(
          'Only includes servers where credential sync is also enabled.',
        ),
        value: _syncSecrets,
        onChanged: (value) {
          setState(() => _syncSecrets = value);
          _persistSyncPrefs(state);
        },
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _syncUrl,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'Server URL',
          hintText: 'https://sync.example.com',
        ),
      ),
      TextField(
        controller: _syncUser,
        textInputAction: TextInputAction.next,
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
          child: Semantics(liveRegion: true, child: Text(_syncStatus!)),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) => _SyncStatusLine(state: state),
        ),
      ),
    ],
  );

  Widget _settingsPage({required Key key, required List<Widget> children}) =>
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: FocusTraversalGroup(
            child: ListView(
              key: key,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: children,
            ),
          ),
        ),
      );

  Widget _section(String title, {String? helpTitle, String? help}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        if (help != null)
          IconButton(
            tooltip: 'About $title',
            icon: const Icon(Icons.help_outline, size: 20),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(helpTitle ?? title),
                content: SingleChildScrollView(child: Text(help)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
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

  Future<void> _persistEditorRegistry(AppState state) async {
    state.services.settings.editorRegistry = _editorRegistry;
    await state.services.saveSettings();
  }

  Future<void> _addEditor(AppState state) async {
    try {
      final picked = await const ExternalFileOpener().pickEditor();
      if (picked == null || !mounted) return;
      await _editEditor(state, picked, adding: true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _editEditor(
    AppState state,
    ExternalEditorDefinition editor, {
    bool adding = false,
  }) async {
    final name = TextEditingController(text: editor.displayName);
    final extensions = TextEditingController(
      text: editor.acceptedExtensions.join(', '),
    );
    String? validationError;
    final updated = await showDialog<ExternalEditorDefinition>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(adding ? 'Add external editor' : 'Edit external editor'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: name,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Display name',
                      errorText: validationError,
                    ),
                  ),
                  TextField(
                    controller: extensions,
                    decoration: const InputDecoration(
                      labelText: 'Accepted file extensions (optional)',
                      hintText: 'dart, json, yaml, tar.gz',
                      helperText:
                          'Leave blank to show this editor for every file.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    editor.launchTarget,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final displayName = validateEditorDisplayName(name.text);
                  final accepted = normalizeEditorExtensions(
                    extensions.text.split(','),
                  );
                  Navigator.pop(
                    context,
                    editor.copyWith(
                      displayName: displayName,
                      acceptedExtensions: accepted,
                    ),
                  );
                } on FormatException catch (error) {
                  setDialogState(() => validationError = error.message);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    extensions.dispose();
    if (updated == null || !mounted) return;
    setState(() => _editorRegistry.put(updated));
    await _persistEditorRegistry(state);
  }

  Future<void> _removeEditor(
    AppState state,
    ExternalEditorDefinition editor,
  ) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${editor.displayName}?'),
        content: Text(
          _editorRegistry.defaultEditorId == editor.id
              ? 'This is the current default. Removing it resets the default '
                    'to System default.'
              : 'The application is only removed from Séance settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true || !mounted) return;
    setState(() => _editorRegistry.remove(editor.id));
    await _persistEditorRegistry(state);
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
