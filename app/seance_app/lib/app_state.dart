import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart' show TerminalController;

import 'services/app_services.dart';
import 'services/default_snippets.dart';
import 'services/managed_remote_file.dart';
import 'services/remote_files_controller.dart';
import 'services/xterm_engine.dart';

/// Connection state of a server's terminal, mirrored by the status dot in the
/// server list (green / grey / red, with a spinner while connecting).
enum TerminalStatus { connecting, connected, disconnected, error }

/// One terminal session — a single SSH connection. A server can have several
/// (shown as tabs inside its terminal pane), so a session has its own [id]
/// distinct from its [serverId]; many sessions can share one [serverId].
class TerminalSession {
  /// Unique per connection (not per server) — the tab identity.
  final String id;

  /// Stable ownership identity for durable local edit checkouts. Unlike [id],
  /// this survives reconnects that replace the terminal engine and widget.
  final String editSessionId;
  final String serverId;
  final ServerConfig config;
  XtermTerminalEngine engine;
  SshSession? session;
  RemoteFilesController? files;
  final Map<String, ManagedRemoteFile> retainedLocalCopies = {};
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
    required this.id,
    String? editSessionId,
    required this.serverId,
    required this.config,
    required this.engine,
    required this.log,
    this.connecting = true,
    this.error,
  }) : editSessionId = editSessionId ?? id;

  bool get isConnected => session != null && !session!.isClosed;

  TerminalStatus get status {
    if (connecting) return TerminalStatus.connecting;
    if (error != null) return TerminalStatus.error;
    if (isConnected) return TerminalStatus.connected;
    return TerminalStatus.disconnected;
  }
}

/// Top-level app state: the server list, live reachability, and the open
/// terminal sessions. A server may have several sessions (tabs); the UI is a
/// thin `ListenableBuilder` over this.
class AppState extends ChangeNotifier {
  final AppServices services;
  late final SshSessionManager _sessionManager;

  List<ServerConfig> servers = [];
  List<Snippet> snippets = [];
  Map<String, ProbeStatus> statuses = {};

  /// All open sessions, in a stable global order. Sessions for the same server
  /// are kept contiguous (enforced on insert), so a per-server tab strip is a
  /// simple order-preserving filter and adjacent tabs are always same-server.
  final List<TerminalSession> sessions = [];

  /// The id of the session shown in the right pane (see [activeServerId],
  /// which is derived from it).
  String? activeSessionId;

  /// The most-recently-focused session per server, so re-selecting a server
  /// row returns to the tab the user last used there.
  final Map<String, String> _lastSessionForServer = {};

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

  // --- Update check ---

  /// Set when a newer release exists on GitHub; drives the "update available"
  /// affordance. The app never downloads or installs — it only links out.
  UpdateInfo? updateInfo;
  final UpdateChecker _updateChecker;

  AppState(this.services, {UpdateChecker? updateChecker})
    : _updateChecker = updateChecker ?? UpdateChecker() {
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

  /// The server whose terminal is shown — derived from the active session, so
  /// there is a single source of truth. Null when nothing is open.
  String? get activeServerId => activeSession?.serverId;

  TerminalSession? get activeSession => sessionById(activeSessionId);

  TerminalSession? sessionById(String? id) {
    if (id == null) return null;
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// This server's sessions in tab order (a stable filter of [sessions]).
  List<TerminalSession> sessionsForServer(String serverId) =>
      sessionsForServerIn(sessions, serverId);

  /// This server's sessions within an arbitrary ordered [list].
  @visibleForTesting
  static List<TerminalSession> sessionsForServerIn(
    List<TerminalSession> list,
    String serverId,
  ) => [
    for (final s in list)
      if (s.serverId == serverId) s,
  ];

  /// Insert index that keeps a server's sessions contiguous: just after that
  /// server's last existing session, or at the end when it has none.
  @visibleForTesting
  static int insertIndexFor(List<TerminalSession> list, String serverId) {
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i].serverId == serverId) return i + 1;
    }
    return list.length;
  }

  Future<void> load() async {
    servers = await services.configStore.listServers();
    await _restoreManagedEditSessions();
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
    await closeAllTabsForServer(id);
    final server = await services.configStore.getServer(id);
    if (server?.secretRef != null) {
      await services.vault.deleteSecret(server!.secretRef!);
    }
    await services.configStore.deleteServer(id);
    servers = await services.configStore.listServers();
    services.probe.updateServers(servers);
    notifyListeners();
    _scheduleAutoSync();
  }

  /// Import hosts from an OpenSSH config file's text.
  Future<int> importSshConfig(String text) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final hosts = SshConfigImporter.parse(text);
    for (final h in hosts) {
      await services.configStore.putServer(
        h.toServerConfig(id: uuidV4(), now: now),
      );
    }
    servers = await services.configStore.listServers();
    services.probe.updateServers(servers);
    notifyListeners();
    _scheduleAutoSync();
    return hosts.length;
  }

  /// Open [config]'s terminal from the server list. If the server already has
  /// tabs, focus the one last used there (reconnecting it in place if it had
  /// dropped); otherwise open a first tab. This keeps the server row's
  /// "focus-or-connect" behavior unchanged for the common single-tab case.
  Future<void> openTerminal(ServerConfig config) async {
    final existing = sessionsForServer(config.id);
    if (existing.isEmpty) {
      await newTab(config);
      return;
    }
    final last = sessionById(_lastSessionForServer[config.id]) ?? existing.last;
    focusSession(last.id);
    if (last.status == TerminalStatus.disconnected ||
        last.status == TerminalStatus.error) {
      await reconnect(last.id);
    }
  }

  /// Open an additional session (tab) for [config], adjacent to that server's
  /// existing tabs, and connect it.
  Future<void> newTab(ServerConfig config) async {
    final id = uuidV4();
    final tab = TerminalSession(
      id: id,
      editSessionId: id,
      serverId: config.id,
      config: config,
      engine: XtermTerminalEngine(onCommand: _recordCommand),
      log: SshConnectionLog(onUpdate: notifyListeners),
    );
    sessions.insert(insertIndexFor(sessions, config.id), tab);
    _setActive(tab.id);
    notifyListeners();
    await _connect(tab);
  }

  /// Establish the SSH session for an already-inserted [tab].
  Future<void> _connect(TerminalSession tab) async {
    final engine = tab.engine;
    final log = tab.log;
    try {
      final credentials = await services.resolveCredentials(tab.config);
      final session = await _sessionManager.connect(
        config: tab.config,
        credentials: credentials,
        engine: engine,
        log: log,
      );
      // The tab may have been closed (or replaced by a reconnect) while we
      // awaited; if so, drop the session we just opened.
      if (!identical(sessionById(tab.id), tab)) {
        await session.close();
        return;
      }
      tab.session = session;
      tab.files = RemoteFilesController(
        session.openRemoteFileSystem,
        shellDirectory: engine.workingDirectory,
        managedFileStore: services.managedRemoteFiles,
        serverId: tab.serverId,
        editSessionId: tab.editSessionId,
        initialBookmarks:
            services.settings.remotePathBookmarks[tab.serverId] ?? const [],
        saveBookmarks: (paths) async {
          if (paths.isEmpty) {
            services.settings.remotePathBookmarks.remove(tab.serverId);
          } else {
            services.settings.remotePathBookmarks[tab.serverId] = paths;
          }
          await services.saveSettings();
        },
        initialShowHidden:
            services.settings.remoteShowHidden[tab.serverId] ?? true,
        saveShowHidden: (value) async {
          services.settings.remoteShowHidden[tab.serverId] = value;
          await services.saveSettings();
        },
        terminalTitle: engine.terminalTitle,
        initialLocalCopies: tab.retainedLocalCopies,
      );
      tab.retainedLocalCopies.clear();
      tab.connecting = false;
      // The connection is up: stop the connection log from capturing dartssh2's
      // per-packet trace, which would otherwise fire notifyListeners (rebuilding
      // the whole app) on every packet for the life of the session.
      log.freeze();
      session.onClosed = () {
        // Remote side ended: flip to disconnected if this is still the tab.
        if (identical(sessionById(tab.id), tab)) {
          final files = tab.files;
          if (files != null) {
            tab.retainedLocalCopies.addAll(files.takeLocalCopies());
            files.dispose();
            tab.files = null;
          }
          tab.session = null;
          tab.connecting = false;
          notifyListeners();
        }
      };
      // The widget drives resize; forward it to the SSH PTY.
      engine.terminal.onResize = (w, h, pw, ph) {
        if (!session.isClosed) session.resize(TerminalSize(w, h));
      };
    } catch (e) {
      if (!identical(sessionById(tab.id), tab)) return;
      tab.connecting = false;
      tab.error = e is SshConnectException ? e.message : e.toString();
    }
    notifyListeners();
  }

  /// Retry a session that failed or dropped: replace it in place with a fresh
  /// connection (new engine, new id) at the same tab position, disposing the
  /// old one. A new id means a fresh `_SessionView` mounts cleanly.
  Future<void> reconnect(String sessionId) async {
    final index = sessions.indexWhere((s) => s.id == sessionId);
    if (index < 0) return;
    final old = sessions[index];
    final config = _configFor(old.serverId) ?? old.config;

    final replacement = TerminalSession(
      id: uuidV4(),
      editSessionId: old.editSessionId,
      serverId: old.serverId,
      config: config,
      engine: XtermTerminalEngine(onCommand: _recordCommand),
      log: SshConnectionLog(onUpdate: notifyListeners),
    );
    sessions[index] = replacement;
    if (activeSessionId == old.id) _setActive(replacement.id);
    await _disposeSession(old);
    replacement.retainedLocalCopies.addAll(old.retainedLocalCopies);
    old.retainedLocalCopies.clear();
    notifyListeners();
    await _connect(replacement);
  }

  ServerConfig? _configFor(String serverId) {
    for (final s in servers) {
      if (s.id == serverId) return s;
    }
    for (final s in sessions) {
      if (s.serverId == serverId) return s.config;
    }
    return null;
  }

  /// Close a session's SSH connection AND dispose its engine. For a session
  /// that never connected (still connecting, or errored) there is no session
  /// to close the engine for us, so dispose it directly.
  Future<void> _disposeSession(
    TerminalSession tab, {
    bool deleteLocalCopies = false,
  }) async {
    final files = tab.files;
    if (files != null) {
      if (deleteLocalCopies) {
        await files.deleteAllLocalCopies();
      } else {
        tab.retainedLocalCopies.addAll(files.takeLocalCopies());
      }
      files.dispose();
      tab.files = null;
    }
    if (deleteLocalCopies && tab.retainedLocalCopies.isNotEmpty) {
      for (final copy in tab.retainedLocalCopies.values) {
        await services.managedRemoteFiles.remove(copy.id);
      }
      tab.retainedLocalCopies.clear();
    }
    if (tab.session != null) {
      await tab.session!.close(); // SshSession.close disposes the engine
    } else {
      await tab.engine.dispose();
    }
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
    _statsSaveDebounce = Timer(
      const Duration(seconds: 3),
      services.saveCommandStats,
    );
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
    await saveSnippet(
      Snippet(
        id: uuidV4(),
        title: _snippetTitle(command),
        body: command,
        createdAt: now,
        updatedAt: now,
      ),
    );
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
    return firstLine.length <= 40
        ? firstLine
        : '${firstLine.substring(0, 39)}…';
  }

  /// Focus a server's most-recently-used tab (or its last tab).
  void focusServer(String serverId) {
    final sessions = sessionsForServer(serverId);
    if (sessions.isEmpty) return;
    final last = sessionById(_lastSessionForServer[serverId]) ?? sessions.last;
    focusSession(last.id);
  }

  /// Make [sessionId] the active session (the tab shown in the pane).
  void focusSession(String sessionId) {
    if (sessionById(sessionId) == null) return;
    _setActive(sessionId);
    notifyListeners();
  }

  /// Set the active session and remember it as its server's most-recent tab.
  /// Does not notify — callers do, so multiple state changes coalesce.
  void _setActive(String? sessionId) {
    activeSessionId = sessionId;
    final session = sessionById(sessionId);
    if (session != null) {
      _lastSessionForServer[session.serverId] = session.id;
    }
  }

  /// React to the app moving in/out of the foreground (wired to the app
  /// lifecycle in `main`). While backgrounded, pause the reachability probe so
  /// it stops opening a TCP connection to every server every ~45s — which would
  /// otherwise drain battery/data on mobile and spam remote sshd/auth logs
  /// (fail2ban) even when the app isn't visible.
  void setForeground(bool foreground) {
    if (foreground) {
      services.probe.resume();
      unawaited(_reconcileRetainedLocalCopies());
      for (final tab in sessions) {
        final files = tab.files;
        if (files != null) unawaited(files.reconcileLocalCopies());
      }
    } else {
      services.probe.pause();
    }
  }

  Future<void> _reconcileRetainedLocalCopies() async {
    final reconciled = await services.managedRemoteFiles.reconcileAll();
    final byId = {for (final copy in reconciled) copy.id: copy};
    var changed = false;
    for (final tab in sessions) {
      for (final entry in tab.retainedLocalCopies.entries.toList()) {
        final updated = byId[entry.value.id];
        if (updated != null && !identical(updated, entry.value)) {
          tab.retainedLocalCopies[entry.key] = updated;
          changed = true;
        }
      }
    }
    if (changed) notifyListeners();
  }

  /// Best-effort check for a newer GitHub release than [currentVersion]. If one
  /// exists (and the user hasn't opted out), [updateInfo] is set so the UI can
  /// offer a link to the releases page. Never downloads or installs; any error
  /// (offline, rate-limited) is swallowed silently.
  Future<void> checkForUpdate(String currentVersion) async {
    if (!services.settings.checkForUpdates) return;
    final info = await _updateChecker.check(currentVersion);
    if (info != null) {
      updateInfo = info;
      notifyListeners();
    }
  }

  /// Dismiss the update affordance for this session (a fresh launch re-checks).
  void dismissUpdateNotice() {
    if (updateInfo == null) return;
    updateInfo = null;
    notifyListeners();
  }

  /// Close a session's SSH connection but keep the tab: its dot goes grey
  /// (disconnected) and the pane offers a reconnect.
  Future<void> disconnect(String sessionId) async {
    final tab = sessionById(sessionId);
    if (tab == null) return;
    final files = tab.files;
    if (files != null) {
      tab.retainedLocalCopies.addAll(files.takeLocalCopies());
      files.dispose();
      tab.files = null;
    }
    await tab.session?.close();
    tab.session = null;
    tab.connecting = false;
    tab.error = null;
    notifyListeners();
  }

  Future<void> discardRetainedLocalCopy(
    String sessionId,
    ManagedRemoteFile copy,
  ) async {
    final tab = sessionById(sessionId);
    if (tab == null ||
        tab.retainedLocalCopies[copy.remotePath]?.id != copy.id) {
      return;
    }
    await services.managedRemoteFiles.remove(copy.id);
    tab.retainedLocalCopies.remove(copy.remotePath);
    notifyListeners();
  }

  /// Close a single tab and drop it. The active session falls back to the next
  /// tab of the same server, then the previous, then any other server's
  /// most-recent tab, then null (which returns the UI to the server list).
  Future<void> closeTab(String sessionId) async {
    final index = sessions.indexWhere((s) => s.id == sessionId);
    if (index < 0) return;
    final tab = sessions[index];
    final wasActive = activeSessionId == tab.id;
    final siblingsBefore = sessionsForServer(tab.serverId);
    sessions.removeAt(index);
    if (_lastSessionForServer[tab.serverId] == tab.id) {
      _lastSessionForServer.remove(tab.serverId);
    }
    await _disposeSession(tab, deleteLocalCopies: true);

    if (wasActive) {
      _setActive(
        fallbackAfterClosing(
          closed: tab,
          siblingsBefore: siblingsBefore,
          remaining: sessions,
          lastSessionForServer: _lastSessionForServer,
        )?.id,
      );
    }
    notifyListeners();
  }

  /// Pick the session to focus after [closed] is removed: the next tab of the
  /// same server (else the previous), then any other server's most-recent tab,
  /// then the last remaining session, then null.
  @visibleForTesting
  static TerminalSession? fallbackAfterClosing({
    required TerminalSession closed,
    required List<TerminalSession> siblingsBefore,
    required List<TerminalSession> remaining,
    required Map<String, String> lastSessionForServer,
  }) {
    final sameServer = sessionsForServerIn(remaining, closed.serverId);
    if (sameServer.isNotEmpty) {
      // The removed tab's old position now holds its successor; clamp to the
      // last when it was the final tab.
      final closedPos = siblingsBefore.indexWhere((s) => s.id == closed.id);
      if (closedPos >= 0 && closedPos < sameServer.length) {
        return sameServer[closedPos];
      }
      return sameServer.last;
    }
    // No tabs left for this server: prefer another server's most-recent tab.
    for (final id in lastSessionForServer.values) {
      for (final s in remaining) {
        if (s.id == id) return s;
      }
    }
    return remaining.isNotEmpty ? remaining.last : null;
  }

  /// Close every tab of a server (used when the server is deleted).
  Future<void> closeAllTabsForServer(String serverId) async {
    final ids = [for (final s in sessionsForServer(serverId)) s.id];
    for (final id in ids) {
      await closeTab(id);
    }
  }

  /// Recreate disconnected placeholder tabs for durable managed edits. The
  /// user explicitly reconnects before upload, while Open/Discard remain tied
  /// to the same logical tab instead of being attached to an arbitrary session.
  Future<void> _restoreManagedEditSessions() async {
    final copies = await services.managedRemoteFiles.reconcileAll();
    final configs = {for (final server in servers) server.id: server};
    final groups = <(String, String), List<ManagedRemoteFile>>{};
    for (final copy in copies) {
      if (!configs.containsKey(copy.serverId)) continue;
      groups
          .putIfAbsent((copy.serverId, copy.editSessionId), () => [])
          .add(copy);
    }
    for (final group in groups.entries) {
      final config = configs[group.key.$1]!;
      final tab = TerminalSession(
        id: uuidV4(),
        editSessionId: group.key.$2,
        serverId: config.id,
        config: config,
        engine: XtermTerminalEngine(onCommand: _recordCommand),
        log: SshConnectionLog(onUpdate: notifyListeners),
        connecting: false,
      );
      tab.retainedLocalCopies.addEntries(
        group.value.map((copy) => MapEntry(copy.remotePath, copy)),
      );
      sessions.add(tab);
      _lastSessionForServer[config.id] = tab.id;
    }
  }

  @override
  void dispose() {
    _probeSub?.cancel();
    _autoSyncTimer?.cancel();
    _syncDebounce?.cancel();
    _statsSaveDebounce?.cancel();
    services.probe.dispose();
    for (final t in sessions) {
      _disposeSession(t);
    }
    super.dispose();
  }
}
