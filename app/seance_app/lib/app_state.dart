import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

import 'services/app_services.dart';
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
    await refreshLlmConfigured();
    _probeSub = services.probe.statuses.listen((s) {
      statuses = s;
      notifyListeners();
    });
    services.probe.start(servers);
    notifyListeners();
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
    final engine = XtermTerminalEngine();
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

  /// Run one sync round, then refresh the server list from the (possibly
  /// updated) store. Returns the outcome for the UI to report.
  Future<SyncOutcome> syncNow() async {
    final outcome = await services.runSync();
    servers = await services.configStore.listServers();
    services.probe.updateServers(servers);
    notifyListeners();
    return outcome;
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
    services.probe.dispose();
    for (final t in sessions.values) {
      t.session?.close();
    }
    super.dispose();
  }
}
