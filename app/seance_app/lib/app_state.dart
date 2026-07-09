import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart' show TerminalController;

import 'services/app_services.dart';
import 'services/default_snippets.dart';
import 'services/xterm_engine.dart';

/// Connection state of a server's terminal, mirrored by the status dot in the
/// server list (green / grey / red, with a spinner while connecting).
enum TerminalStatus { connecting, connected, disconnected, error }

/// One terminal session, bound one-to-one to a server. The server list is the
/// tab list: each server has at most one [TerminalSession].
class TerminalSession {
  final String serverId;
  final ServerConfig config;
  XtermTerminalEngine engine;
  SshSession? session;
  bool connecting;
  String? error;

  /// Live transcript of the current/last connection attempt, shown in the
  /// "connection log" details when a connection fails.
  SshConnectionLog log;

  /// The xterm selection controller for this session's terminal. Set by the
  /// live [_SessionView] widget while it's mounted (and cleared on dispose), so
  /// the native macOS Edit menu can copy from the active session.
  TerminalController? controller;

  TerminalSession({
    required this.serverId,
    required this.config,
    required this.engine,
    required this.log,
    this.connecting = true,
    this.error,
  });

  bool get isConnected => session != null && !session!.isClosed;

  TerminalStatus get status {
    if (connecting) return TerminalStatus.connecting;
    if (error != null) return TerminalStatus.error;
    if (isConnected) return TerminalStatus.connected;
    return TerminalStatus.disconnected;
  }
}

/// Top-level app state: the server list, live reachability, and the open
/// terminal sessions (one per server). The UI is a thin `ListenableBuilder`
/// over this.
class AppState extends ChangeNotifier {
  final AppServices services;
  late final SshSessionManager _sessionManager;

  List<ServerConfig> servers = [];
  List<Snippet> snippets = [];
  Map<String, ProbeStatus> statuses = {};

  /// Open terminal sessions keyed by server id — one per server.
  final Map<String, TerminalSession> sessions = {};

  /// The server whose terminal is shown in the right pane.
  String? activeServerId;

  /// Whether the assistant is configured enough to be usable (drives whether
  /// the LLM sidebar is shown). Refreshed at load and after settings change.
  bool llmConfigured = false;

  /// Bumped whenever the LLM provider settings change (key, model, base URL),
  /// so the chat sidebar rebuilds its provider instead of reusing a stale one.
  int llmConfigVersion = 0;

  StreamSubscription<Map<String, ProbeStatus>>? _probeSub;

  // --- Sync status / automatic sync ---

  /// True while a sync round is running (drives the header sync indicator).
  bool syncing = false;

  /// When the last sync round completed successfully, and the last error (if
  /// the most recent attempt failed). Surfaced in the sync UI.
  DateTime? lastSyncAt;
  String? lastSyncError;

  bool _syncQueued = false;
  Timer? _autoSyncTimer;
  Timer? _syncDebounce;
  static const Duration _autoSyncInterval = Duration(minutes: 5);
  static const Duration _syncDebounceDelay = Duration(seconds: 2);

  // --- Command suggestions (opt-in) ---

  /// Frequently-run commands worth saving as snippets, most-used first. Empty
  /// unless the feature is enabled in settings. Local only.
  List<String> commandSuggestions = [];
  final SecretRedactor _redactor = SecretRedactor();
  Timer? _statsSaveDebounce;

  /// UI-supplied interaction hooks (wired by the root widget so dialogs can be
  /// shown). Default to a safe "deny" if the UI hasn't set them yet.
  HostKeyPrompter? hostKeyPrompter;
  KeyboardInteractiveResponder? keyboardInteractiveResponder;

  AppState(this.services) {
    _sessionManager = SshSessionManager(
      tofu: services.tofu,
      onHostKey: (decision) async {
        final prompt = hostKeyPrompter;
        return prompt == null ? false : prompt(decision);
      },
      onKeyboardInteractive: (prompts, name, instruction) async {
        final responder = keyboardInteractiveResponder;
        return responder == null
            ? const <String>[]
            : responder(prompts, name, instruction);
      },
    );
  }

  TerminalSession? get activeSession =>
      activeServerId == null ? null : sessions[activeServerId];

  TerminalSession? sessionForServer(String serverId) => sessions[serverId];

  Future<void> load() async {
    servers = await services.configStore.listServers();
    await _seedDefaultSnippets();
    snippets = await services.snippetStore.listSnippets();
    await refreshLlmConfigured();
    _recomputeSuggestions();
    _probeSub = services.probe.statuses.listen((s) {
      statuses = s;
      notifyListeners();
    });
    services.probe.start(servers);
    notifyListeners();
    // Sync at startup (pull others' changes) and keep a periodic timer going.
    ensureAutoSyncTimer();
    if (services.settings.autoSync && services.isSyncConfigured) {
      unawaited(_autoSync());
    }
  }

  /// Recompute whether the assistant is usable: a key-based provider needs a
  /// stored API key; a local OpenAI-compatible endpoint (Ollama, LM Studio)
  /// works keyless as long as a base URL is set.
  Future<void> refreshLlmConfigured() async {
    final s = services.settings;
    final storedKey = s.llmApiKeyRef.isEmpty
        ? null
        : await services.masterKeys.getApiKey(s.llmApiKeyRef);
    final hasKey = storedKey != null && storedKey.isNotEmpty;
    final configured = switch (s.llmKind) {
      LlmProviderKind.anthropic => hasKey,
      LlmProviderKind.openaiCompatible =>
        hasKey || s.llmBaseUrl.trim().isNotEmpty,
    };
    if (configured != llmConfigured) {
      llmConfigured = configured;
      notifyListeners();
    }
  }

  /// Called after the LLM provider settings change: invalidate any cached chat
  /// provider (so a new API key takes effect) and refresh sidebar visibility.
  Future<void> reloadLlmProvider() async {
    llmConfigVersion++;
    await refreshLlmConfigured();
    notifyListeners();
  }

  Future<void> saveServer(ServerConfig config, {Secret? secret}) async {
    if (secret != null) await services.vault.putSecret(secret);
    await services.configStore.putServer(config);
    servers = await services.configStore.listServers();
    services.probe.updateServers(servers);
    notifyListeners();
    _scheduleAutoSync();
  }

  Future<void> deleteServer(String id) async {
    await closeSession(id);
    final server = await services.configStore.getServer(id);
    if (server?.secretRef != null) {
      await services.vault.deleteSecret(server!.secretRef!);
    }
    await services.configStore.deleteServer(id);
    servers = await services.configStore.listServers();
    services.probe.updateServers(servers);
    if (activeServerId == id) activeServerId = null;
    notifyListeners();
    _scheduleAutoSync();
  }

  /// Import hosts from an OpenSSH config file's text.
  Future<int> importSshConfig(String text) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final hosts = SshConfigImporter.parse(text);
    for (final h in hosts) {
      await services.configStore
          .putServer(h.toServerConfig(id: uuidV4(), now: now));
    }
    servers = await services.configStore.listServers();
    services.probe.updateServers(servers);
    notifyListeners();
    _scheduleAutoSync();
    return hosts.length;
  }

  /// Open [config]'s terminal. If it is already connected (or connecting), just
  /// focus it; if it is disconnected or errored, reconnect. Always makes it the
  /// active session.
  Future<void> openTerminal(ServerConfig config) async {
    final existing = sessions[config.id];
    activeServerId = config.id;
    if (existing != null &&
        (existing.status == TerminalStatus.connected ||
            existing.status == TerminalStatus.connecting)) {
      notifyListeners();
      return;
    }
    await _connect(config);
  }

  /// (Re)establish the SSH session for [config], replacing any prior engine.
  Future<void> _connect(ServerConfig config) async {
    final log = SshConnectionLog(onUpdate: notifyListeners);
    final engine = XtermTerminalEngine(onCommand: _recordCommand);
    final tab = TerminalSession(
      serverId: config.id,
      config: config,
      engine: engine,
      log: log,
    );
    // Drop any previous session for this server before replacing it.
    await sessions[config.id]?.session?.close();
    sessions[config.id] = tab;
    notifyListeners();

    try {
      final credentials = await services.resolveCredentials(config);
      final session = await _sessionManager.connect(
        config: config,
        credentials: credentials,
        engine: engine,
        log: log,
      );
      tab.session = session;
      tab.connecting = false;
      // The connection is up: stop the connection log from capturing dartssh2's
      // per-packet trace, which would otherwise fire notifyListeners (rebuilding
      // the whole app) on every packet for the life of the session.
      log.freeze();
      session.onClosed = () {
        // Remote side ended: flip to disconnected if this is still the tab.
        if (sessions[config.id] == tab) {
          tab.connecting = false;
          notifyListeners();
        }
      };
      // The widget drives resize; forward it to the SSH PTY.
      engine.terminal.onResize = (w, h, pw, ph) {
        if (!session.isClosed) session.resize(TerminalSize(w, h));
      };
    } catch (e) {
      tab.connecting = false;
      tab.error = e is SshConnectException ? e.message : e.toString();
    }
    notifyListeners();
  }

  /// Retry the connection for a server whose session failed or dropped.
  Future<void> reconnect(String serverId) async {
    final config = _configFor(serverId);
    if (config == null) return;
    activeServerId = serverId;
    await _connect(config);
  }

  ServerConfig? _configFor(String serverId) {
    for (final s in servers) {
      if (s.id == serverId) return s;
    }
    return sessions[serverId]?.config;
  }

  /// Seed the built-in snippets on first launch only (guarded by a persisted
  /// flag so clearing them out doesn't bring them back).
  Future<void> _seedDefaultSnippets() async {
    if (services.settings.snippetsSeeded) return;
    for (final snippet in defaultSnippets()) {
      await services.snippetStore.putSnippet(snippet);
    }
    services.settings.snippetsSeeded = true;
    await services.saveSettings();
  }

  /// Save (create or update) a snippet, then refresh the list.
  Future<void> saveSnippet(Snippet snippet) async {
    await services.snippetStore.putSnippet(snippet);
    snippets = await services.snippetStore.listSnippets();
    notifyListeners();
    _scheduleAutoSync();
  }

  Future<void> deleteSnippet(String id) async {
    await services.snippetStore.deleteSnippet(id);
    snippets = await services.snippetStore.listSnippets();
    notifyListeners();
    _scheduleAutoSync();
  }

  /// Run one sync round manually (the "Sync now" button). Surfaces errors to
  /// the caller and updates the shared sync status.
  Future<SyncOutcome> syncNow() async {
    syncing = true;
    notifyListeners();
    try {
      final outcome = await _runSyncAndRefresh();
      lastSyncError = null;
      lastSyncAt = DateTime.now();
      return outcome;
    } catch (e) {
      lastSyncError = _shortError(e);
      rethrow;
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// One sync round + refresh of the domain lists from the (possibly updated)
  /// stores. Shared by manual and automatic sync.
  Future<SyncOutcome> _runSyncAndRefresh() async {
    final outcome = await services.runSync();
    servers = await services.configStore.listServers();
    snippets = await services.snippetStore.listSnippets();
    services.probe.updateServers(servers);
    _recomputeSuggestions();
    return outcome;
  }

  /// Start (or restart) the periodic auto-sync timer. Safe to call repeatedly —
  /// e.g. after enrolling in sync or toggling the setting.
  void ensureAutoSyncTimer() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    if (services.settings.autoSync && services.isSyncConfigured) {
      _autoSyncTimer = Timer.periodic(_autoSyncInterval, (_) => _autoSync());
    }
  }

  /// Queue a debounced background sync after a local edit, so rapid successive
  /// edits coalesce into one round.
  void _scheduleAutoSync() {
    if (!services.settings.autoSync || !services.isSyncConfigured) return;
    _syncDebounce?.cancel();
    _syncDebounce = Timer(_syncDebounceDelay, _autoSync);
  }

  /// Best-effort background sync. Errors are captured into [lastSyncError]
  /// rather than thrown. If a round is already running, one more is queued so a
  /// mid-sync edit is never lost.
  Future<void> _autoSync() async {
    if (!services.isSyncConfigured) return;
    if (syncing) {
      _syncQueued = true;
      return;
    }
    syncing = true;
    notifyListeners();
    try {
      do {
        _syncQueued = false;
        await _runSyncAndRefresh();
        lastSyncError = null;
        lastSyncAt = DateTime.now();
      } while (_syncQueued);
    } catch (e) {
      lastSyncError = _shortError(e);
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  static String _shortError(Object e) {
    final s = e.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  // --- Command suggestions ---

  /// Fold a submitted command into the local frequency stats and refresh the
  /// suggestions if they changed. No-op unless the feature is enabled.
  void _recordCommand(String command) {
    if (!services.settings.commandSuggestions) return;
    if (!services.commandStats.record(command)) return;
    _scheduleStatsSave();
    _recomputeSuggestions();
  }

  void _scheduleStatsSave() {
    _statsSaveDebounce?.cancel();
    _statsSaveDebounce =
        Timer(const Duration(seconds: 3), services.saveCommandStats);
  }

  /// Recompute [commandSuggestions] from the local stats: frequently-run
  /// commands that aren't already snippets and don't look like they contain a
  /// secret (belt-and-suspenders — capture is opt-in and local).
  void _recomputeSuggestions() {
    List<String> next = const [];
    if (services.settings.commandSuggestions) {
      final bodies = {for (final s in snippets) s.body.trim()};
      next = services.commandStats
          .suggestions(isExisting: (c) => bodies.contains(c.trim()), limit: 12)
          .where((c) => !_redactor.wouldRedact(c))
          .take(6)
          .toList();
    }
    if (!listEquals(next, commandSuggestions)) {
      commandSuggestions = next;
      notifyListeners();
    }
  }

  /// Re-evaluate suggestions after a settings change (e.g. the feature toggle).
  void refreshSuggestions() => _recomputeSuggestions();

  /// Promote a suggested command to a real (syncable) snippet.
  Future<void> addSuggestionAsSnippet(String command) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await saveSnippet(Snippet(
      id: uuidV4(),
      title: _snippetTitle(command),
      body: command,
      createdAt: now,
      updatedAt: now,
    ));
    _recomputeSuggestions(); // it's now an existing snippet, so it drops off
  }

  /// Permanently hide a suggestion.
  Future<void> dismissSuggestion(String command) async {
    services.commandStats.dismiss(command);
    await services.saveCommandStats();
    _recomputeSuggestions();
  }

  static String _snippetTitle(String command) {
    final firstLine = command.split('\n').first.trim();
    return firstLine.length <= 40 ? firstLine : '${firstLine.substring(0, 39)}…';
  }

  void focusServer(String serverId) {
    activeServerId = serverId;
    notifyListeners();
  }

  /// Close a server's SSH session but keep viewing it: the tab stays, its dot
  /// goes grey (disconnected), and the pane offers a reconnect.
  Future<void> disconnect(String serverId) async {
    final tab = sessions[serverId];
    if (tab == null) return;
    await tab.session?.close();
    tab.session = null;
    tab.connecting = false;
    tab.error = null;
    notifyListeners();
  }

  /// Close a server's session (if any) and drop it from the open set. Used when
  /// the server itself is deleted.
  Future<void> closeSession(String serverId) async {
    final tab = sessions.remove(serverId);
    if (tab == null) return;
    await tab.session?.close();
    if (activeServerId == serverId) {
      activeServerId =
          sessions.isNotEmpty ? sessions.keys.last : null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _probeSub?.cancel();
    _autoSyncTimer?.cancel();
    _syncDebounce?.cancel();
    _statsSaveDebounce?.cancel();
    services.probe.dispose();
    for (final t in sessions.values) {
      t.session?.close();
    }
    super.dispose();
  }
}
