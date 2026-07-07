import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

import 'services/app_services.dart';
import 'services/xterm_engine.dart';

/// One open terminal session in the right pane.
class TerminalTab {
  final String id;
  final ServerConfig config;
  final XtermTerminalEngine engine;
  SshSession? session;
  bool connecting;
  String? error;

  TerminalTab({
    required this.id,
    required this.config,
    required this.engine,
    this.connecting = true,
    this.error,
  });

  bool get isConnected => session != null && !session!.isClosed;
}

/// Top-level app state: the server list, live reachability, and open terminal
/// tabs. The UI is a thin `ListenableBuilder` over this.
class AppState extends ChangeNotifier {
  final AppServices services;
  late final SshSessionManager _sessionManager;

  List<ServerConfig> servers = [];
  Map<String, ProbeStatus> statuses = {};
  final List<TerminalTab> tabs = [];
  String? activeTabId;
  String? selectedServerId;

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

  TerminalTab? get activeTab {
    if (activeTabId == null) return null;
    for (final t in tabs) {
      if (t.id == activeTabId) return t;
    }
    return null;
  }

  Future<void> load() async {
    servers = await services.configStore.listServers();
    _probeSub = services.probe.statuses.listen((s) {
      statuses = s;
      notifyListeners();
    });
    services.probe.start(servers);
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
    final server = await services.configStore.getServer(id);
    if (server?.secretRef != null) {
      await services.vault.deleteSecret(server!.secretRef!);
    }
    await services.configStore.deleteServer(id);
    servers = await services.configStore.listServers();
    services.probe.updateServers(servers);
    if (selectedServerId == id) selectedServerId = null;
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

  /// Open (or focus) a terminal for [config].
  Future<TerminalTab> openTerminal(ServerConfig config) async {
    final engine = XtermTerminalEngine();
    final tab = TerminalTab(id: uuidV4(), config: config, engine: engine);
    tabs.add(tab);
    activeTabId = tab.id;
    notifyListeners();

    try {
      final credentials = await services.resolveCredentials(config);
      final session = await _sessionManager.connect(
        config: config,
        credentials: credentials,
        engine: engine,
      );
      tab.session = session;
      tab.connecting = false;
      // The widget drives resize; forward it to the SSH PTY.
      engine.terminal.onResize = (w, h, pw, ph) {
        if (!session.isClosed) session.resize(TerminalSize(w, h));
      };
    } catch (e) {
      tab.connecting = false;
      tab.error = e.toString();
    }
    notifyListeners();
    return tab;
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

  void focusTab(String id) {
    activeTabId = id;
    notifyListeners();
  }

  Future<void> closeTab(String id) async {
    TerminalTab? tab;
    for (final t in tabs) {
      if (t.id == id) tab = t;
    }
    if (tab == null) return;
    await tab.session?.close();
    tabs.remove(tab);
    if (activeTabId == id) {
      activeTabId = tabs.isNotEmpty ? tabs.last.id : null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _probeSub?.cancel();
    services.probe.dispose();
    for (final t in tabs) {
      t.session?.close();
    }
    super.dispose();
  }
}
