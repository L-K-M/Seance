import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../services/external_file_opener.dart';
import '../services/settings_backend.dart';
import '../services/system_fonts.dart';
import 'font_picker.dart';
import 'sync_enrollment_validation.dart';
import 'terminal_appearance.dart';
import 'top_toast.dart';

export '../services/settings_backend.dart' show SettingsTab;

/// Where the screen is shown, which decides its chrome.
enum SettingsPresentation {
  /// A route over the app: an app bar with the title and a back button.
  route,

  /// The desktop settings window, whose own title bar names it and closes
  /// it: the tabs alone.
  window,
}

/// Settings: LLM provider (the assistant is always on — this only picks which
/// model), the web-search backend, secret redaction, and sync enrolment.
///
/// Reads and writes through [backend] only, so the same screen runs as a
/// route in the app and in the desktop settings window's own isolate.
class SettingsScreen extends StatefulWidget {
  final SettingsBackend backend;
  final SettingsTab initialTab;
  final SettingsPresentation presentation;

  /// Tabs to switch to while open: the settings window receives these when
  /// Settings is chosen again with a different tab.
  final Stream<SettingsTab>? tabRequests;

  /// Test seam: the source of installed font families behind the terminal
  /// font picker. Defaults to the host's own collection, which a widget test
  /// must not depend on.
  @visibleForTesting
  final SystemFonts? systemFonts;

  const SettingsScreen({
    super.key,
    required this.backend,
    this.initialTab = SettingsTab.general,
    this.presentation = SettingsPresentation.route,
    this.tabRequests,
    this.systemFonts,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  /// Shown by both of Save's refusals, which are one message about one
  /// situation: written twice, a wording fix or a translation reaches one of
  /// them and the drift is invisible in review.
  static const String _adoptedMidSave =
      'The assistant settings changed on another device while this screen '
      'was open. They have been reloaded — review them and save again.';

  late final _baseUrl = TextEditingController();
  late final _model = TextEditingController();
  late final _apiKey = TextEditingController();
  late final _searxng = TextEditingController();
  final _zaiApiKey = TextEditingController();
  late final _syncUrl = TextEditingController();
  late final _syncUser = TextEditingController();
  final _syncPassword = TextEditingController();
  final _syncEncryptionPassphrase = TextEditingController();
  final _syncEncryptionPassphraseConfirm = TextEditingController();

  late final TabController _tabs = TabController(
    length: SettingsTab.values.length,
    initialIndex: widget.initialTab.index,
    vsync: this,
  );
  StreamSubscription<SettingsTab>? _tabRequests;

  late LlmProviderKind _kind;
  late bool _zai;
  late bool _syncAssistant;
  late bool _redaction;
  late bool _autoSync;
  late bool _syncSecrets;
  late bool _commandSuggestions;
  late bool _checkForUpdates;
  late bool _keepSessionsAlive;

  /// This screen's own copy, edited here and handed to the backend whole:
  /// the settings window's [SettingsBackend.settings] is itself a copy, and
  /// editing the route's in place would change the live settings before the
  /// write that is supposed to carry the change.
  late EditorRegistry _editorRegistry;

  /// A getter, not a `late final` field: the service caches its directory
  /// walk, so reading this per build is free, and a field initialized once
  /// would pin the test seam to whatever the first widget instance carried.
  SystemFonts get _systemFonts => widget.systemFonts ?? hostSystemFonts();

  late double _terminalFontSize;
  late TerminalPalette _terminalPalette;
  final _terminalFont = TextEditingController();
  SyncEnrollmentMode _syncMode = SyncEnrollmentMode.login;
  bool _saving = false;
  String? _syncStatus;

  // Model discovery.
  List<String> _models = [];
  bool _loadingModels = false;
  String? _modelsError;

  /// Load the assistant half of the settings into this screen's fields.
  ///
  /// Separate from the rest of the load because it is the one half another
  /// device can rewrite while the screen is open: turning assistant sync on
  /// adopts the account's configuration into `settings`, and a Save made
  /// afterwards would otherwise write these stale values back over it — and
  /// stamp them, so the revert would win everywhere.
  void _loadAssistantFields(AssistantFields f) {
    _kind = f.kind;
    _baseUrl.text = f.baseUrl;
    _model.text = f.model;
    _searxng.text = f.searxngUrl;
    _zai = f.zaiEnabled;
    _redaction = f.redactionEnabled;
  }

  /// [SettingsBackend.llmConfigVersion] as of the last [_loadAssistantFields]:
  /// a sync round that adopts another device's configuration bumps it, and
  /// that is how Save tells that the fields it holds are stale.
  int _assistantVersionSeen = 0;

  /// [_loadAssistantFields], and remember which configuration it loaded.
  void _syncAssistantFields(AssistantFields fields, int version) {
    _loadAssistantFields(fields);
    _assistantVersionSeen = version;
  }

  SettingsBackend get _backend => widget.backend;

  @override
  void initState() {
    super.initState();
    final s = _backend.settings;
    _syncAssistantFields(AssistantFields.of(s), _backend.llmConfigVersion);
    _autoSync = s.autoSync;
    _syncSecrets = s.syncSecrets;
    _syncAssistant = s.syncAssistant;
    _commandSuggestions = s.commandSuggestions;
    _checkForUpdates = s.checkForUpdates;
    _keepSessionsAlive = s.keepSessionsAliveInBackground;
    _editorRegistry = EditorRegistry.fromJson(s.editorRegistry.toJson());
    _terminalFontSize = clampTerminalFontSize(s.terminalFontSize);
    _terminalPalette = s.terminalPalette;
    _terminalFont.text = s.terminalFontFamily;
    _syncUrl.text = s.syncBaseUrl ?? '';
    _syncUser.text = s.syncUsername ?? '';
    _listenForTabRequests();
  }

  void _listenForTabRequests() {
    _tabRequests = widget.tabRequests?.listen(
      (tab) => _tabs.animateTo(tab.index),
    );
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tabRequests == oldWidget.tabRequests) return;
    unawaited(_tabRequests?.cancel());
    _listenForTabRequests();
  }

  @override
  void dispose() {
    unawaited(_tabRequests?.cancel());
    _tabs.dispose();
    for (final c in [
      _baseUrl,
      _model,
      _apiKey,
      _searxng,
      _zaiApiKey,
      _syncUrl,
      _syncUser,
      _syncPassword,
      _syncEncryptionPassphrase,
      _syncEncryptionPassphraseConfirm,
      _terminalFont,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabBar = TabBar(
      controller: _tabs,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      tabs: const [
        Tab(icon: Icon(Icons.tune_outlined), text: 'General'),
        Tab(icon: Icon(Icons.auto_awesome_outlined), text: 'Assistant'),
        Tab(icon: Icon(Icons.folder_open_outlined), text: 'Files'),
        Tab(icon: Icon(Icons.cloud_sync_outlined), text: 'Sync'),
      ],
    );
    return Scaffold(
      appBar: switch (widget.presentation) {
        SettingsPresentation.route => AppBar(
          title: const Text('Settings'),
          bottom: tabBar,
        ),
        SettingsPresentation.window => AppBar(
          automaticallyImplyLeading: false,
          toolbarHeight: 0,
          bottom: tabBar,
        ),
      },
      body: TabBarView(
        controller: _tabs,
        children: [_generalTab(), _assistantTab(), _filesTab(), _syncTab()],
      ),
    );
  }

  Widget _assistantTab() => _settingsPage(
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
                  onPressed: _fetchModels,
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
          // Not "never synced" any more, which is what this said before the
          // record below existed and carried these keys. It is the sentence a
          // user reads before deciding to paste a credential in, so it has to
          // describe what the switch further down actually does.
          labelText: 'API key (OS keystore; synced if assistant sync is on)',
          hintText: 'leave blank to keep the existing key / keyless local',
        ),
      ),
      const SizedBox(height: 16),
      _section(
        'Web search (chat tool)',
        helpTitle: 'Web search backends',
        help:
            'Every backend you configure is used, and their results are '
            'merged — so filling in more than one uses them all, and '
            'clearing one leaves the others. With none configured, the '
            'assistant '
            'has no search tool at all.',
      ),
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
        title: const Text('Z.AI Web Search Prime'),
        subtitle: const Text('Needs a Z.AI key with a GLM Coding Plan.'),
        value: _zai,
        // Frozen while a save runs, like the Save button and the sync
        // switches. This used to be the invariant: `_save` read `_zai` twice,
        // before the awaits to decide whether to write the key and after them
        // to set the reference, so a toggle in between made one save act on
        // two different answers — off-to-on persisting a reference with
        // nothing stored behind it, on-to-off storing a key the settings it
        // just wrote call unused. `_saveInner` snapshots `_zai` once now,
        // before any await, so the two writes can no longer disagree and this
        // gate is defense in depth rather than the thing holding it up.
        onChanged: _saving ? null : (v) => setState(() => _zai = v),
      ),
      if (_zai)
        TextField(
          controller: _zaiApiKey,
          obscureText: true,
          decoration: const InputDecoration(
            // Same correction as the LLM key's above: this one rides the
            // assistant record too.
            labelText:
                'Z.AI API key (OS keystore; synced if assistant sync is on)',
            hintText: 'leave blank to keep the existing key',
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
        onPressed: _saving ? null : () => _save(),
        child: const Text('Save assistant settings'),
      ),
    ],
  );

  Widget _generalTab() => _settingsPage(
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
          _persistCheckForUpdates();
        },
      ),
      // Android freezes cached processes, killing every live SSH connection
      // moments after the app leaves the screen; only this platform needs (and
      // has) a mechanism to opt out of that. dart:io's Platform would crash on
      // a web build; foundation's target detection compiles everywhere.
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep sessions alive in the background'),
          subtitle: const Text(
            'Keeps connections open while Séance is backgrounded, via an '
            'ongoing Android notification. Uses some battery.',
          ),
          value: _keepSessionsAlive,
          onChanged: (value) {
            setState(() => _keepSessionsAlive = value);
            _persistKeepSessionsAlive();
          },
        ),
      ],
      const Divider(height: 40),
      _section(
        'Terminal',
        helpTitle: 'Terminal appearance',
        help:
            'Font size, family, and colors apply to every session on this '
            'device. With the terminal focused you can zoom without opening '
            'Settings: ⌘ with +, − or 0 on macOS and iPadOS, Ctrl+Shift with '
            'the same keys elsewhere (plain Ctrl chords belong to the shell). '
            'Leave the font family blank to use Séance’s own monospace '
            'stack. On desktop the button in the field lists the fonts '
            'installed here, previewed in their own face; you can also type '
            'any family name the system knows.',
      ),
      Row(
        children: [
          Expanded(
            child: Slider(
              min: kMinTerminalFontSize,
              max: kMaxTerminalFontSize,
              divisions:
                  ((kMaxTerminalFontSize - kMinTerminalFontSize) /
                          kTerminalFontSizeStep)
                      .round(),
              value: _terminalFontSize,
              label: '${_terminalFontSize.round()} pt',
              onChanged: (value) => setState(
                () => _terminalFontSize = clampTerminalFontSize(value),
              ),
              onChangeEnd: (_) => _persistTerminalAppearance(),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${_terminalFontSize.round()} pt',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
      TextField(
        controller: _terminalFont,
        decoration: InputDecoration(
          labelText: 'Font family (optional)',
          hintText: 'e.g. JetBrains Mono — blank uses the built-in stack',
          // Only where there is an installed collection to read: on mobile an
          // app sees the system faces it is given rather than a user-managed
          // library, so a picker there would list the fallback stack back at
          // the user. The field itself stays typeable everywhere.
          suffixIcon: _systemFonts.isSupported
              ? IconButton(
                  tooltip: 'Choose an installed font',
                  icon: const Icon(Icons.font_download_outlined),
                  onPressed: _pickTerminalFont,
                )
              : null,
        ),
        onSubmitted: (_) => _persistTerminalAppearance(),
        onTapOutside: (_) {
          // Overriding onTapOutside replaces TextField's default handler, so
          // the dismissal it would have done has to be done here — otherwise
          // the soft keyboard stays up after tapping away on mobile.
          FocusManager.instance.primaryFocus?.unfocus();
          _persistTerminalAppearance();
        },
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<TerminalPalette>(
        initialValue: _terminalPalette,
        decoration: const InputDecoration(labelText: 'Colors'),
        items: const [
          DropdownMenuItem(
            value: TerminalPalette.followApp,
            child: Text('Follow the app theme'),
          ),
          DropdownMenuItem(
            value: TerminalPalette.alwaysDark,
            child: Text('Always dark'),
          ),
          DropdownMenuItem(
            value: TerminalPalette.alwaysLight,
            child: Text('Always light'),
          ),
        ],
        onChanged: (value) {
          if (value == null) return;
          setState(() => _terminalPalette = value);
          _persistTerminalAppearance();
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
          _persistCommandSuggestions();
        },
      ),
    ],
  );

  Widget _filesTab() {
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
            _persistEditorRegistry();
          },
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(child: _section('External editors')),
            if (currentEditorHostPlatform != null)
              OutlinedButton.icon(
                onPressed: _addEditor,
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
              onTap: () => _editEditor(editor),
              trailing: PopupMenuButton<String>(
                tooltip: 'Editor actions',
                onSelected: (action) {
                  if (action == 'edit') _editEditor(editor);
                  if (action == 'remove') _removeEditor(editor);
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

  Widget _syncTab() => _settingsPage(
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
        onChanged: _saving
            ? null
            : (value) {
                setState(() => _autoSync = value);
                _persistSyncPrefs();
              },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Sync saved passwords & keys'),
        subtitle: const Text(
          'Only includes servers where credential sync is also enabled.',
        ),
        value: _syncSecrets,
        onChanged: _saving
            ? null
            : (value) {
                setState(() => _syncSecrets = value);
                _persistSyncPrefs();
              },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Sync assistant settings'),
        subtitle: const Text(
          'Provider, model, endpoint, web search and redaction — with their '
          'API keys, so the assistant works on the other device. '
          'End-to-end encrypted. A localhost endpoint will not resolve '
          'elsewhere. Turning this on adopts the settings already on the '
          'account, replacing the assistant setup on this device. '
          'Turning this off stops this device sharing further '
          'changes; it does not remove what was already shared, which the '
          'other devices are still using.',
        ),
        value: _syncAssistant,
        onChanged: _saving
            ? null
            : (value) {
                setState(() => _syncAssistant = value);
                _persistSyncPrefs();
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
            onPressed: _saving ? null : () => _sync(mode: _syncMode),
            child: Text(
              _syncMode == SyncEnrollmentMode.register
                  ? 'Create sync account'
                  : 'Log in on this device',
            ),
          ),
          FilledButton.tonal(
            onPressed: _saving ? null : () => _syncNow(),
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
          listenable: _backend,
          builder: (context, _) => _SyncStatusLine(status: _backend.syncStatus),
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
  Future<void> _fetchModels() async {
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final models = await _backend.fetchModels(
        ModelQuery(
          kind: _kind,
          baseUrl: _baseUrl.text,
          model: _model.text,
          typedApiKey: _apiKey.text,
        ),
      );
      if (!mounted) return;
      setState(() {
        _models = models;
        if (models.isEmpty) {
          _modelsError = 'The endpoint returned no models.';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _modelsError = 'Could not fetch models: $e');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _save() async {
    // A draft loaded before another device's configuration was adopted is
    // refused by the backend, against the app's live version — not here,
    // against [SettingsBackend.llmConfigVersion]: in the settings window that
    // arrives with a snapshot, which can trail the version a save result has
    // just handed this screen, and a check against it would read the lag as
    // an adoption and reload the fields from the older settings.
    //
    // Everything the save uses is read here, once, before the `setState`
    // that disables the form: the fields stay editable while a save is in
    // flight, and the keystore writes it waits on are exactly where it
    // stalls, since an OS keyring can put a prompt in front of one. Anything
    // read later would fold text typed during that stall into the save
    // already running — and the key fields would then be cleared as if text
    // the store never saw had been stored.
    final draft = AssistantDraft(
      fields: AssistantFields(
        kind: _kind,
        baseUrl: _baseUrl.text,
        model: _model.text,
        searxngUrl: _searxng.text,
        zaiEnabled: _zai,
        redactionEnabled: _redaction,
      ),
      llmApiKey: _apiKey.text,
      zaiApiKey: _zaiApiKey.text,
      versionSeen: _assistantVersionSeen,
    );
    setState(() => _saving = true);
    // What `_saving` disables — Save, all three sync switches, the Z.AI
    // switch, the mode selector and both sync buttons — must come back
    // whatever the save does, or a transient disk failure would lock the
    // whole assistant section until the screen is closed and reopened.
    try {
      final result = await _backend.saveAssistant(draft);
      if (mounted) _applySaveResult(draft, result);
    } catch (e) {
      // The settings write itself failed (or the settings window lost the
      // app). The settings may well not be on disk, which is the one outcome
      // silence must not cover.
      if (mounted) {
        showTopToastIn(context, message: 'Settings not saved — $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _applySaveResult(AssistantDraft draft, AssistantSaveResult result) {
    switch (result.status) {
      case AssistantSaveStatus.adoptedBeforeSave:
        setState(() => _syncAssistantFields(result.current, result.version));
        showTopToastIn(context, message: _adoptedMidSave);
        return;
      case AssistantSaveStatus.keystoreFailed:
        // Named per key: the same class of error otherwise produced a bare
        // `KeystoreException` string with nothing saying which of the two
        // keys failed to save.
        final which = result.failedKey == AssistantKey.zai
            ? 'the Z.AI key'
            : 'the API key';
        showTopToastIn(
          context,
          message:
              'Settings not saved — could not store $which: '
              '${result.error}',
        );
        return;
      case AssistantSaveStatus.saved:
        break;
    }
    if (result.publishError != null) {
      showTopToastIn(
        context,
        message: 'Assistant sync: ${result.publishError}',
      );
    }
    if (result.keysStored) {
      // Cleared once stored, or the text left in the field makes every later
      // Save on this screen look like a key change: it would stamp `now` and
      // republish, and on last-write-wins that beats a genuinely newer edit
      // from another device with content that did not change. The field is
      // write-only anyway — it is never populated from the keystore.
      //
      // Only what this Save stored, though: text typed into a field while
      // the save ran was never persisted, and clearing it would discard it
      // without a trace. The Z.AI key is stored only with its switch on, so
      // its clear follows the switch position the draft carried.
      if (_apiKey.text == draft.llmApiKey) _apiKey.clear();
      if (draft.fields.zaiEnabled && _zaiApiKey.text == draft.zaiApiKey) {
        _zaiApiKey.clear();
      }
    }
    // An adoption during the save means these fields are not what is
    // configured any more; blessing the version would let the next Save
    // revert it silently, with a fresh stamp. Reloaded instead, as the
    // refusal does, and the user saves again from what is configured.
    if (result.adoptedMeanwhile) {
      setState(() => _syncAssistantFields(result.current, result.version));
    } else {
      _assistantVersionSeen = result.version;
    }
    showTopToastIn(
      context,
      // Ordered by what the user has to act on. An adoption means this Save's
      // values are not what is configured any more and it has to be made
      // again — nothing else matters until that is done. A reload failure is
      // next: the assistant in this process is still the old one. The Z.AI
      // notice is last, about a key the next search reads.
      message: result.adoptedMeanwhile
          ? 'Saved — but the assistant settings changed on another device '
                'meanwhile. The fields show what is configured now; review '
                'them and save again.'
          : result.reloadError != null
          ? 'Saved — but the assistant could not be reloaded, so it is '
                'still running the previous configuration: '
                '${result.reloadError}'
          : result.zaiWithoutKey
          ? 'Saved — but no Z.AI key could be read (none stored, or '
                'the keyring is locked), so Z.AI search will be '
                'skipped.'
          : 'Saved',
    );
  }

  /// Persist the sync preference toggles and (re)start the auto-sync timer.
  Future<void> _persistSyncPrefs() async {
    // The same flag Save sets, for the same reason it exists: this awaits a
    // disk write and, on switch-on, a whole sync round, and the switches are
    // only disabled while it is set. Without it the user can press Save — or
    // flip a second toggle — while adoption is rewriting the very settings
    // this write assigns to and rolls back.
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final result = await _backend.setSyncPrefs(
        autoSync: _autoSync,
        syncSecrets: _syncSecrets,
        syncAssistant: _syncAssistant,
      );
      if (!mounted) return;
      setState(() {
        _autoSync = result.autoSync;
        _syncSecrets = result.syncSecrets;
        _syncAssistant = result.syncAssistant;
        // Adoption rewrites the assistant half of the settings, and this
        // screen loaded its fields once; without this the next Save writes
        // the pre-adoption values back — with a fresh stamp, so the revert
        // wins on every device. Only when adoption actually ran: otherwise
        // this would overwrite what the user had typed but not yet saved.
        if (result.adopted) {
          _syncAssistantFields(result.current, result.version);
        }
      });
      if (result.saveError != null) {
        showTopToastIn(
          context,
          message: 'Sync preferences: ${result.saveError}',
        );
      } else if (result.assistantSyncError != null) {
        showTopToastIn(
          context,
          message: 'Assistant sync: ${result.assistantSyncError}',
        );
      }
    } catch (e) {
      // Only the settings window gets here, when it lost the app: the local
      // backend reports every failure in the result. What is persisted is
      // unknown, so show what this screen last knew.
      if (mounted) {
        final s = _backend.settings;
        setState(() {
          _autoSync = s.autoSync;
          _syncSecrets = s.syncSecrets;
          _syncAssistant = s.syncAssistant;
        });
        showTopToastIn(context, message: 'Sync preferences: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// A write the General and Files tabs make on each change, which reports
  /// its own failure: these are fired from `onChanged` without an awaiter, so
  /// an escaping error would be an unhandled async error behind a control
  /// that looks saved.
  Future<void> _persist(String what, Future<void> Function() write) async {
    try {
      await write();
    } catch (e) {
      if (mounted) showTopToastIn(context, message: '$what not saved — $e');
    }
  }

  /// Persist the command-suggestions toggle and refresh the current list.
  Future<void> _persistCommandSuggestions() => _persist(
    'Command suggestions',
    () => _backend.setCommandSuggestions(_commandSuggestions),
  );

  /// Persist the update-check toggle; turning it off also clears any banner
  /// already showing this session.
  Future<void> _persistCheckForUpdates() => _persist(
    'Update check',
    () => _backend.setCheckForUpdates(_checkForUpdates),
  );

  /// Persist the background keep-alive toggle and apply it to live sessions.
  /// A failed save reverts the switch — unless the user toggled again while
  /// the save was in flight, in which case the newer choice is authoritative
  /// and stands.
  Future<void> _persistKeepSessionsAlive() async {
    final requested = _keepSessionsAlive;
    try {
      await _backend.setKeepSessionsAlive(requested);
    } catch (e) {
      // A newer toggle governs the switch now, and reports for itself.
      if (_keepSessionsAlive != requested) return;
      _keepSessionsAlive = !requested;
      if (!mounted) return;
      setState(() {});
      showTopToastIn(context, message: 'Keep sessions alive not saved — $e');
    }
  }

  /// Persist terminal appearance and repaint every live session. Called on
  /// slider release and on each discrete choice, so the General tab keeps its
  /// "saves immediately" contract.
  Future<void> _persistTerminalAppearance() => _persist(
    'Terminal appearance',
    () => _backend.setTerminalAppearance(
      fontSize: _terminalFontSize,
      fontFamily: _terminalFont.text.trim(),
      palette: _terminalPalette,
    ),
  );

  /// Opens the installed-font picker and applies what it returns.
  ///
  /// A dismissal leaves the field alone; the built-in-stack choice clears it,
  /// which is what a blank family already means to [TerminalAppearance].
  Future<void> _pickTerminalFont() async {
    final chosen = await showFontPicker(
      context,
      fonts: _systemFonts,
      current: _terminalFont.text.trim(),
    );
    if (chosen == null || !mounted) return;
    _terminalFont.text = chosen;
    await _persistTerminalAppearance();
  }

  Future<void> _persistEditorRegistry() => _persist(
    'Editor settings',
    () => _backend.setEditorRegistry(_editorRegistry),
  );

  Future<void> _addEditor() async {
    try {
      final picked = await _backend.pickEditor();
      if (picked == null || !mounted) return;
      await _editEditor(picked, adding: true);
    } catch (error) {
      if (!mounted) return;
      showTopToastIn(context, message: error.toString());
    }
  }

  Future<void> _editEditor(
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
    await _persistEditorRegistry();
  }

  Future<void> _removeEditor(ExternalEditorDefinition editor) async {
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
    await _persistEditorRegistry();
  }

  Future<void> _sync({required SyncEnrollmentMode mode}) async {
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
      await _backend.enrollSync(
        SyncEnrollment(
          mode: mode,
          baseUrl: _syncUrl.text.trim(),
          username: _syncUser.text.trim(),
          password: _syncPassword.text,
          encryptionPassphrase: _syncEncryptionPassphrase.text,
        ),
      );
      // Always verify enrollment with one immediate round.
      if (mounted) {
        setState(() => _syncStatus = 'Connected. Synchronizing…');
      }
      await _backend.syncNow();
      if (mounted) setState(() => _syncStatus = 'Connected and synced.');
    } catch (e) {
      if (mounted) setState(() => _syncStatus = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _saving = true;
      _syncStatus = 'Syncing…';
    });
    try {
      final outcome = await _backend.syncNow();
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
  final SyncStatus status;
  const _SyncStatusLine({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    if (status.syncing) {
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
    if (status.lastSyncError != null) {
      return Text(
        'Last sync failed: ${status.lastSyncError}',
        style: style?.copyWith(color: scheme.error),
      );
    }
    if (status.lastSyncAt != null) {
      return Text('Last synced ${_ago(status.lastSyncAt!)}.', style: style);
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
