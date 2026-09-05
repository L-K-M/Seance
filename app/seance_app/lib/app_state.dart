import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart' show TerminalController;

import 'services/app_services.dart';
import 'services/app_settings.dart';
import 'services/background_keep_alive.dart';
import 'services/chat_session.dart';
import 'services/default_snippets.dart';
import 'services/managed_remote_file.dart';
import 'services/remote_files_controller.dart';
import 'services/server_duplication.dart';
import 'services/xterm_engine.dart';
import 'ui/session_label.dart';
import 'ui/terminal_appearance.dart';

/// Connection state of a server's terminal, mirrored by the status dot in the
/// server list (green / grey / red, with a spinner while connecting).
enum TerminalStatus { connecting, connected, disconnected, error }

/// What the remote shell has told us about a session: the OSC 7 working
/// directory, the OSC 0/2 terminal title, and the command it is running right
/// now. Used to name the session's tab.
@immutable
class SessionMetadata {
  final String? workingDirectory;
  final String? terminalTitle;

  /// The command the session has been running for a while (already redacted),
  /// or null at a prompt. Unlike the fields above this is *not* kept-last:
  /// it names what the tab is doing, and a finished command must fall back
  /// to where the tab is.
  final String? runningCommand;

  const SessionMetadata({
    this.workingDirectory,
    this.terminalTitle,
    this.runningCommand,
  });

  /// This metadata with the transient command dropped — what a reconnect
  /// carries over: the command died with the connection, the place did not.
  SessionMetadata get withoutRunningCommand => SessionMetadata(
    workingDirectory: workingDirectory,
    terminalTitle: terminalTitle,
  );

  @override
  bool operator ==(Object other) =>
      other is SessionMetadata &&
      other.workingDirectory == workingDirectory &&
      other.terminalTitle == terminalTitle &&
      other.runningCommand == runningCommand;

  @override
  int get hashCode =>
      Object.hash(workingDirectory, terminalTitle, runningCommand);
}

/// Repaint signal for one session's connection log.
///
/// dartssh2 calls `printTrace` per packet, so a handshake appends hundreds of
/// lines. Routing those into [AppState.notifyListeners] rebuilt the server
/// list, every mounted terminal, and the utility panel once per trace line —
/// a burst of full-tree rebuilds during exactly the moment the user is already
/// waiting on a connection. Giving the log its own notifier means only the
/// widget that displays it repaints, and while the pane is showing the
/// connecting spinner there is no listener at all.
class ConnectionLogNotifier extends ChangeNotifier {
  void bump() => notifyListeners();
}

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
  /// "connection log" details when a connection fails. Owned by the session so
  /// its trace lines drive [logNotifier] rather than the whole app.
  late final SshConnectionLog log;

  /// Repaints the connection-log view as lines arrive. See
  /// [ConnectionLogNotifier].
  final ConnectionLogNotifier logNotifier = ConnectionLogNotifier();

  /// The xterm selection controller for this session's terminal. Set by the
  /// live [_SessionView] widget while it's mounted (and cleared on dispose), so
  /// the native macOS Edit menu can copy from the active session.
  TerminalController? controller;

  /// The session's shell-reported identity, mirrored off the engine.
  ///
  /// Owned by the session rather than read from the engine directly, because
  /// the engine (and its notifiers) is disposed when the connection drops
  /// while the *tab* lives on — the strip must keep naming a disconnected tab
  /// by where it last was. Its own notifier also means a new title repaints
  /// the tab strip alone instead of the whole app.
  final ValueNotifier<SessionMetadata> metadata;

  /// A name the user gave this tab, or null to follow the shell.
  ///
  /// Overrides every automatic source. When you open three tabs to one box
  /// you have roles in mind — "logs", "deploy" — that no heuristic can guess,
  /// so the manual name is the top of the naming ladder and nothing the
  /// remote reports displaces it.
  ///
  /// Kept separate from [metadata] deliberately: that is what the *shell*
  /// reported, and a user-chosen name is not remote data. In memory only,
  /// like the sessions it names — a relaunch has no session to re-label.
  final ValueNotifier<String?> customName;

  /// How long a command must keep running before it becomes the tab's name.
  /// Quick commands (`ls`, `git status`) finish inside this window, so the
  /// strip doesn't repaint a new label for every enter key.
  static const Duration commandRevealDelay = Duration(milliseconds: 1500);

  /// Tab labels are chrome: a secret pasted into a command line must never be
  /// rendered in the strip. Always on — unlike the assistant's redaction
  /// toggle there is nothing being *sent* here to opt out of, and the engine's
  /// capture is keystroke-level so it sees passwords typed at flag prompts.
  static final SecretRedactor _redactor = SecretRedactor();

  Timer? _commandReveal;
  int _commandGeneration = 0;

  TerminalSession({
    required this.id,
    String? editSessionId,
    required this.serverId,
    required this.config,
    required this.engine,
    this.connecting = true,
    this.error,
    SessionMetadata initialMetadata = const SessionMetadata(),
    String? initialCustomName,
  }) : editSessionId = editSessionId ?? id,
       metadata = ValueNotifier<SessionMetadata>(initialMetadata),
       customName = ValueNotifier<String?>(initialCustomName) {
    log = SshConnectionLog(onUpdate: logNotifier.bump);
    engine.workingDirectory.addListener(_syncMetadata);
    engine.terminalTitle.addListener(_syncMetadata);
    engine.activeCommand.addListener(_syncRunningCommand);
  }

  void _syncMetadata() {
    metadata.value = SessionMetadata(
      // Keep the last known values: a shell that stops reporting — or clears
      // its title with an empty OSC 2, which is a common way to reset it —
      // should not blank the tab back to "Session N" mid-session.
      workingDirectory: _keepLast(
        engine.workingDirectory.value,
        metadata.value.workingDirectory,
      ),
      terminalTitle: _keepLast(
        engine.terminalTitle.value,
        metadata.value.terminalTitle,
      ),
      runningCommand: metadata.value.runningCommand,
    );
  }

  static String? _keepLast(String? reported, String? previous) =>
      (reported == null || reported.isEmpty) ? previous : reported;

  /// Mirror the engine's running command into [metadata], but only once it
  /// has been running for [commandRevealDelay]. Ends are immediate; reveals
  /// are debounced by generation so a command that finished (or was replaced)
  /// during the delay never surfaces late. The command text is captured and
  /// redacted here, up front — the timer must not read the engine, which a
  /// dropped connection disposes out from under it.
  void _syncRunningCommand() {
    final line = engine.activeCommand.value;
    _commandGeneration++;
    _commandReveal?.cancel();
    _commandReveal = null;
    if (line == null || line.isEmpty) {
      if (metadata.value.runningCommand != null) {
        metadata.value = metadata.value.withoutRunningCommand;
      }
      return;
    }
    final generation = _commandGeneration;
    final shown = _redactor.redact(line);
    _commandReveal = Timer(commandRevealDelay, () {
      if (generation != _commandGeneration) return;
      metadata.value = SessionMetadata(
        workingDirectory: metadata.value.workingDirectory,
        terminalTitle: metadata.value.terminalTitle,
        runningCommand: shown,
      );
    });
  }

  /// Release what the session owns beyond its engine and SSH connection.
  ///
  /// The engine's own disposal already drops these listeners along with the
  /// notifiers they are attached to, so the explicit removal is belt and
  /// braces — it makes the ordering invariant local instead of something a
  /// reader has to infer from `XtermTerminalEngine.dispose`. Removing a
  /// listener from an already-disposed notifier is explicitly supported.
  void dispose() {
    _commandReveal?.cancel();
    engine.workingDirectory.removeListener(_syncMetadata);
    engine.terminalTitle.removeListener(_syncMetadata);
    engine.activeCommand.removeListener(_syncRunningCommand);
    metadata.dispose();
    customName.dispose();
  }

  bool get isConnected => session != null && !session!.isClosed;

  TerminalStatus get status {
    if (connecting) return TerminalStatus.connecting;
    if (error != null) return TerminalStatus.error;
    if (isConnected) return TerminalStatus.connected;
    return TerminalStatus.disconnected;
  }
}

/// Whether the server a duplicate was planned from still is what it was.
///
/// Only the credential reference matters: the copy carries its own id, label
/// and timestamps, and a rename or a colour change on the source between the
/// plan and the save costs nothing. A missing server or a different ref does,
/// because the credential the plan holds was read against the old one.
///
/// A top-level function so the rule can be asserted directly — no test in this
/// app can construct an [AppState].
bool duplicationSourceUnchanged(ServerConfig? latest, ServerConfig source) =>
    latest != null && latest.secretRef == source.secretRef;

/// The source of a duplicate stopped matching what the copy was planned from.
///
/// Its [toString] is a sentence because the list pane shows it verbatim, the
/// way it shows a locked keyring: a user who is told only "could not
/// duplicate" has nothing to do next.
class SourceServerChanged implements Exception {
  final String label;
  const SourceServerChanged(this.label);

  @override
  String toString() => '"$label" changed while it was being copied — it was '
      'deleted, or it now holds a different credential. Nothing was created.';
}

/// Whether any server other than [excludingId] still points at [secretRef].
///
/// Deleting a server drops its vault entry, and nothing stops two configs
/// sharing one — a synced credential record is keyed by the credential rather
/// than by the server holding it, and the editor can be pointed at an existing
/// ref by hand. Dropping it out from under a server that still names it is
/// silent credential loss the survivor only discovers at connect time.
///
/// The same check `SyncCoordinator` makes before applying a `secret:`
/// tombstone. A top-level function so the rule can be asserted directly — no
/// test in this app can construct an [AppState].
bool secretStillReferenced(
  String secretRef,
  Iterable<ServerConfig> servers, {
  required String excludingId,
}) =>
    servers.any((s) => s.id != excludingId && s.secretRef == secretRef);

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

  /// The assistant conversation. Lives here rather than in the sidebar widget
  /// so it survives the drawer closing on narrow layouts, and the pane being
  /// rebuilt when the layout crosses the wide/narrow breakpoint.
  final ChatSession chat = ChatSession();

  /// UI-supplied interaction hooks (wired by the root widget so dialogs can be
  /// shown). Default to a safe "deny" if the UI hasn't set them yet.
  HostKeyPrompter? hostKeyPrompter;
  KeyboardInteractiveResponder? keyboardInteractiveResponder;

  // --- Update check ---

  /// Set when a newer release exists on GitHub; drives the "update available"
  /// affordance. The app never downloads or installs — it only links out.
  UpdateInfo? updateInfo;
  final UpdateChecker _updateChecker;

  /// Keeps the process anchored to the OS while sessions are connecting or
  /// connected, so backgrounding the app on Android doesn't let the OS freeze
  /// it and drop every live SSH connection. No-op on other platforms.
  final BackgroundKeepAlive _keepAlive;

  AppState(
    this.services, {
    UpdateChecker? updateChecker,
    BackgroundKeepAlive? keepAlive,
  })  : _updateChecker = updateChecker ?? UpdateChecker(),
        _keepAlive = keepAlive ?? BackgroundKeepAlive() {
    _sessionManager = SshSessionManager(
      tofu: services.tofu,
      onHostKey: _promptForHostKey,
      onKeyboardInteractive: _promptKeyboardInteractive,
    );
  }

  /// The host-key prompt as the SSH layer wants it, reading [hostKeyPrompter]
  /// at call time so the root widget can wire it after this state exists.
  /// Denies while it is unwired: refusing an unverified key is the safe answer.
  Future<bool> _promptForHostKey(HostKeyDecision decision) async {
    final prompt = hostKeyPrompter;
    return prompt == null ? false : prompt(decision);
  }

  Future<List<String>> _promptKeyboardInteractive(
    List<String> prompts,
    String name,
    String instruction,
  ) async {
    final responder = keyboardInteractiveResponder;
    return responder == null
        ? const <String>[]
        : responder(prompts, name, instruction);
  }

  /// Try [config] the way a real connection would — the same host-key and
  /// keyboard-interactive prompts, the same failure wording — without opening
  /// a shell, running the login script, or creating a tab.
  ///
  /// [config] may be a draft the editor has not saved, so the `draft…`
  /// arguments carry what its fields hold; see
  /// [AppServices.resolveCredentials] for why reading the vault alone would
  /// test the wrong credential.
  ///
  /// A host key approved during the attempt is pinned only for its duration
  /// (see [UnpinnedHostKeyStore]). A form the user may still cancel, naming a
  /// host they may still retype, is not where trust-on-first-use should be
  /// granted for good — the first real connection asks once more.
  Future<ConnectionTestResult> testServerConnection(
    ServerConfig config, {
    String? draftPassword,
    String? draftPrivateKey,
    String? draftKeyPassphrase,
    IdentityFileBookmark? draftIdentityBookmark,
    SshConnectionLog? log,
  }) {
    return runConnectionTest(
      config: config,
      credentials: () => services.resolveCredentials(
        config,
        draftPassword: draftPassword,
        draftPrivateKey: draftPrivateKey,
        draftKeyPassphrase: draftKeyPassphrase,
        draftIdentityBookmark: draftIdentityBookmark,
      ),
      authenticate: liveHostAuthenticator(
        // Not a verifier: liveHostAuthenticator wraps this in an
        // UnpinnedHostKeyStore itself, so a trial cannot be wired to pin.
        hostKeys: services.hostKeyStore,
        onHostKey: _promptForHostKey,
        onKeyboardInteractive: _promptKeyboardInteractive,
      ),
      log: log,
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
    // Honor the keep-alive setting from the very first session event on; the
    // app can be backgrounded mid-handshake right after opening a tab.
    _keepAlive.setEnabled(services.settings.keepSessionsAliveInBackground);
    servers = await services.configStore.listServers();
    await _restoreManagedEditSessions();
    await _seedDefaultSnippets();
    snippets = await services.snippetStore.listSnippets();
    await refreshLlmConfigured();
    // Invariant insurance: if any restore path ever leaves a session
    // connecting or connected, the anchor must reflect it before the app can
    // be backgrounded. (Today's restores insert disconnected placeholders.)
    _refreshKeepAlive();
    _recomputeSuggestions();
    // Skip hosts that already hold a live session: they are demonstrably
    // reachable, and probing them only adds an sshd log line every sweep.
    services.probe.connectedServerIds = () => {
      for (final session in sessions)
        if (session.isConnected) session.serverId,
    };
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
  /// works keyless as long as a base URL is set. Keystore errors read as
  /// "no key" here (the masterKeys layer is tolerant on reads).
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

  /// [identityFileBookmark] is the final, device-local security-scope grant
  /// for the server's identity file: a value stores it, null clears any stored
  /// one (the editor owns the keep-or-drop decision, so this always applies).
  Future<void> saveServer(
    ServerConfig config, {
    Secret? secret,
    IdentityFileBookmark? identityFileBookmark,
  }) =>
      _mutate(() => _saveServerNow(
            config,
            secret: secret,
            identityFileBookmark: identityFileBookmark,
          ));

  /// [saveServer] without the queue, for callers already holding it.
  Future<void> _saveServerNow(
    ServerConfig config, {
    Secret? secret,
    IdentityFileBookmark? identityFileBookmark,
  }) async {
    if (secret != null) await services.vault.putSecret(secret);
    await services.configStore.putServer(config);
    final bookmarks = services.settings.identityFileBookmarks;
    if (identityFileBookmark != null) {
      if (bookmarks[config.id] != identityFileBookmark) {
        bookmarks[config.id] = identityFileBookmark;
        await services.saveSettings();
      }
    } else if (bookmarks.remove(config.id) != null) {
      await services.saveSettings();
    }
    servers = await services.configStore.listServers();
    services.probe.updateServers(servers);
    notifyListeners();
    _scheduleAutoSync();
  }

  /// Duplicate [source] as a new server and return the copy.
  ///
  /// The credential is copied into a vault entry of the copy's own (see
  /// [duplicateServerConfig] for why it is never shared), and so is the
  /// device-local security-scoped grant for a Browse…-picked identity file:
  /// that grant is keyed by server id, so without copying it the duplicate
  /// would silently fall back to the raw path and fail to open a key outside
  /// `~/.ssh`.
  ///
  /// Vault failures propagate, as they do from [saveServer]. A duplicate that
  /// quietly lost its password would look identical in the list and only admit
  /// it at connect time.
  Future<ServerConfig> duplicateServer(ServerConfig source) async {
    return _mutate(() async {
      final plan = await planServerDuplication(
        source,
        vault: services.vault,
        takenLabels: servers.map((s) => s.label),
        id: uuidV4(),
        secretId: uuidV4(),
        now: DateTime.now().millisecondsSinceEpoch,
        bookmarkFor: (id) => services.settings.identityFileBookmarks[id],
      );
      // Deletes, saves and sync rounds are all serialized behind this one
      // now, so nothing can move the vault under the plan. What the queue
      // cannot make fresh is [source] itself: the caller captured it before
      // the queue was entered, so by the time the plan is built it may
      // describe a server that has since been deleted or re-pointed at
      // another credential. Saving from a stale snapshot would create the
      // copy the user asked for without the password they expect it to have —
      // and resurrect a config another device deleted.
      if (!duplicationSourceUnchanged(
        await services.configStore.getServer(source.id),
        source,
      )) {
        throw SourceServerChanged(source.label);
      }
      // The non-queuing core: this is already inside the queue, and calling
      // the public one would wait on itself.
      await _saveServerNow(
        plan.config,
        secret: plan.secret,
        identityFileBookmark: plan.identityFileBookmark,
      );
      return plan.config;
    });
  }

  /// The store mutation currently in flight, so the next one waits for it.
  Future<void> _mutating = Future<void>.value();

  /// The zone this object was built in, i.e. one no mutation is running in.
  ///
  /// A `Timer` runs its callback in the zone it was *created* in, and the
  /// callback is bound there before any `createTimer` override sees it — so a
  /// zone specification cannot hand it back. A timer scheduled from inside a
  /// mutation (every save schedules the auto-sync debounce) therefore has to
  /// be created out here, or its round runs carrying the mutation marker and
  /// trips the assert in [_mutate].
  final Zone _outsideMutations = Zone.current;

  /// Run [action] after every mutation queued before it has finished.
  ///
  /// Duplicating reads the vault, and that read can sit behind an OS keychain
  /// prompt for as long as the user takes to answer it — long enough for a
  /// second Duplicate to pick a name from a list that does not yet contain the
  /// first copy, so both land on the same one, which is the outcome the naming
  /// rule exists to prevent. Deleting shares the queue because it reads the
  /// server list to decide whether a credential is still referenced: two
  /// deletes of servers sharing one vault entry, each running that read before
  /// the other's config removal lands, would each see the other as a live
  /// referent and both leave the entry behind with nothing able to name it.
  ///
  /// Saving and applying a sync round share it for the same reason from the
  /// other side: both write the config store and the vault, so either landing
  /// between a delete's reference count and its vault delete, or between a
  /// duplicate's plan and its save, is the same read-then-write hazard. With
  /// them on the queue, a credential rewritten in place under an unchanged
  /// ref — which is what editing a server's password does — can no longer
  /// happen while a duplicate is reading it.
  ///
  /// No timeout, deliberately. A mutation waiting on an OS keychain prompt
  /// holds everything queued behind it, deletes included, until the prompt is
  /// answered; the answer to that is to surface the pending prompt, not to
  /// time out a queue whose whole job is keeping a check and its write
  /// together.
  Future<T> _mutate<T>(Future<T> Function() action) async {
    // A queued action that calls a queued method waits on its own completion,
    // and since the queue has no timeout the app's mutations simply stop with
    // no error to find. The marker is a zone value rather than a field: a
    // field would read as "set" for an unrelated second caller arriving while
    // the first action is suspended at an await, which is the normal case
    // this queue exists to serialize, not a bug.
    assert(
      Zone.current[#seanceMutation] == null,
      'Re-entrant mutation: an action inside the queue must call the '
      'non-queuing core (_saveServerNow), not saveServer, deleteServer, '
      'duplicateServer or a sync round.',
    );
    final queued = _mutating;
    final finished = Completer<void>();
    _mutating = finished.future;
    await queued;
    try {
      return await runZoned(action, zoneValues: {#seanceMutation: true});
    } finally {
      finished.complete();
    }
  }

  Future<void> deleteServer(String id) async {
    // Outside the queue: tearing sessions down touches no store, and holding
    // the queue across a session teardown would stall every other mutation
    // behind however long the far end takes to hang up.
    await closeAllTabsForServer(id);
    await _mutate(() async {
      final server = await services.configStore.getServer(id);
      final secretRef = server?.secretRef;
      if (secretRef != null &&
          !secretStillReferenced(
            secretRef,
            await services.configStore.listServers(),
            excludingId: id,
          )) {
        await services.vault.deleteSecret(secretRef);
      }
      if (services.settings.identityFileBookmarks.remove(id) != null) {
        await services.saveSettings();
      }
      await services.configStore.deleteServer(id);
      servers = await services.configStore.listServers();
    });
    services.probe.updateServers(servers);
    notifyListeners();
    _scheduleAutoSync();
  }

  /// Server-list group sections currently folded away, keyed by
  /// [serverGroupKey]. Read straight off settings rather than mirrored here:
  /// there is one owner of the value, and it is the thing that persists it.
  ///
  /// A view rather than a copy — `Set.unmodifiable` would duplicate the
  /// elements on every read, and the list pane reads this on every build. The
  /// wrapper is what says [toggleServerGroup] is the only writer: folding a
  /// section by mutating this set would skip both the repaint and the save.
  Set<String> get collapsedServerGroups =>
      UnmodifiableSetView(services.settings.collapsedServerGroups);

  /// Fold a group section away, or open it again.
  Future<void> toggleServerGroup(String key) async {
    final collapsed = services.settings.collapsedServerGroups;
    // remove() reports whether it was there, so this is one lookup, not two.
    if (!collapsed.remove(key)) collapsed.add(key);
    notifyListeners();
    await services.saveSettings();
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
    );
    sessions.insert(insertIndexFor(sessions, config.id), tab);
    _setActive(tab.id);
    notifyListeners();
    // The tab is `connecting` from here on — the anchor must be up before the
    // handshake starts, not after it finishes.
    _refreshKeepAlive();
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
          _refreshKeepAlive();
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
    _refreshKeepAlive();
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
      // Carry the shell-reported identity across the reconnect so the tab
      // keeps its name instead of flickering back to "Session N". The running
      // command is deliberately not carried: it belonged to the dead
      // connection. A name the user chose outlives the connection entirely.
      initialMetadata: old.metadata.value.withoutRunningCommand,
      initialCustomName: old.customName.value,
    );
    sessions[index] = replacement;
    if (activeSessionId == old.id) _setActive(replacement.id);
    await _disposeSession(old);
    replacement.retainedLocalCopies.addAll(old.retainedLocalCopies);
    old.retainedLocalCopies.clear();
    notifyListeners();
    await _connect(replacement);
  }

  /// The current config for [serverId], preferring the stored list over the
  /// snapshot a live session captured at connect time — an edit made while a
  /// session is open should be reflected by anything that reads the config for
  /// display, not just by the next connection.
  ServerConfig? configFor(String serverId) => _configFor(serverId);

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
    // Sever the log's callback before anything async begins: a trace line
    // arriving during (or after) teardown would otherwise reach a notifier
    // that is about to be disposed, which asserts. Freezing also stops the
    // transcript growing while the transport closes.
    tab.log.freeze();
    try {
      if (tab.session != null) {
        await tab.session!.close(); // SshSession.close disposes the engine
      } else {
        await tab.engine.dispose();
      }
    } finally {
      tab.logNotifier.dispose();
    }
    // Only here, not in disconnect(): a disconnected tab stays in the strip and
    // keeps showing where it last was.
    tab.dispose();
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

  /// The vault just unlocked (the OS keystore came back after being down at
  /// bootstrap): re-evaluate what depended on it — the assistant key check and
  /// the sync round that couldn't run.
  Future<void> onVaultUnlocked() async {
    await refreshLlmConfigured();
    if (services.settings.autoSync && services.isSyncConfigured) {
      unawaited(_autoSync());
    }
  }

  /// One sync round + refresh of the domain lists from the (possibly updated)
  /// stores. Shared by manual and automatic sync.
  Future<SyncOutcome> _runSyncAndRefresh() async {
    // On the mutation queue: a round writes the config store and the vault
    // (tombstones delete both), so it is a mutation like any other and must
    // not interleave with a delete's reference count or a duplicate's plan.
    // The re-reads are inside it too — outside, a mutation could land while
    // `listServers` was still resolving and then have its own assignment
    // overwritten by this older snapshot.
    final outcome = await _mutate(() async {
      final result = await services.runSync();
      servers = await services.configStore.listServers();
      snippets = await services.snippetStore.listSnippets();
      return result;
    });
    services.probe.updateServers(servers);
    _recomputeSuggestions();
    // A pulled assistant configuration changes the provider, the model or the
    // key, none of which an already-built chat provider notices.
    if (services.assistantSettingsChanged) await reloadLlmProvider();
    return outcome;
  }

  /// The assistant's configuration was just edited here: stamp it so the
  /// synced record has a timestamp that moved for a real reason, and push it.
  Future<void> assistantSettingsEdited() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // Never below a record this device already holds. The stamp is the whole
    // of the last-write-wins comparison, so a clock that runs behind the
    // device this configuration was pulled from would make a fresh edit lose
    // to the record it had just adopted — and the next round would re-apply
    // that record over the edit, silently.
    services.settings.assistantUpdatedAt =
        now > services.settings.assistantUpdatedAt
            ? now
            : services.settings.assistantUpdatedAt + 1;
    await services.saveSettings();
    _scheduleAutoSync();
  }

  /// Assistant sync was just switched on here: take whatever the account
  /// already holds, and publish this device's configuration only if it held
  /// nothing.
  ///
  /// Stamping unconditionally would make this device win. `assistantUpdatedAt`
  /// would be "now", later than any record on the account, so a laptop that
  /// has never configured the assistant would push its defaults over a phone's
  /// real provider, model and keys — leaving every device looking configured
  /// and answering nothing, which is the outcome the zero stamp exists to
  /// prevent, arriving through the switch instead.
  ///
  /// Adopting first cannot cause the mirror of that. A device that never
  /// edited the assistant still stamps zero and offers nothing; one that did
  /// offers a real record and wins the round if its edit was genuinely later.
  /// Only when the round adopts nothing is there an account with no assistant
  /// configuration, and then publishing this device's is the point of the
  /// switch.
  Future<void> assistantSyncSwitchedOn() async {
    if (services.isSyncConfigured) {
      try {
        await _runSyncAndRefresh();
      } on Exception {
        // Offline, or the server is down: this is the one moment not to
        // publish on a guess. An `Error` is a bug in this path rather than a
        // fact about the network, and swallowing one here would leave a
        // toggle that quietly does nothing with no trace of why. The switch stays on and the next round settles
        // it — either by adopting the account's record or, once this device
        // is edited, by publishing that edit.
        return;
      }
      if (services.assistantSettingsChanged) return;
    }
    // Nothing configured here, so there is nothing worth publishing: stamping
    // now would turn this device's defaults into the account's newest write
    // and beat a phone that configured its assistant while sync was off and
    // enables the switch afterwards. The zero stamp is the whole guard, and
    // it is this line that would step around it.
    if (services.settings.assistantUpdatedAt == 0) return;
    await assistantSettingsEdited();
  }

  /// Start (or restart) the periodic auto-sync timer. Safe to call repeatedly —
  /// e.g. after enrolling in sync or toggling the setting.
  void ensureAutoSyncTimer() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    if (services.settings.autoSync && services.isSyncConfigured) {
      _autoSyncTimer = _outsideMutations
          .run(() => Timer.periodic(_autoSyncInterval, (_) => _autoSync()));
    }
  }

  /// Queue a debounced background sync after a local edit, so rapid successive
  /// edits coalesce into one round.
  void _scheduleAutoSync() {
    if (!services.settings.autoSync || !services.isSyncConfigured) return;
    _syncDebounce?.cancel();
    // Created in [_outsideMutations]: this is reached from inside `_mutate`
    // (every save schedules one), and a timer's callback runs in the zone it
    // was created in — so the debounce would fire a sync round carrying the
    // mutation marker and trip the re-entrancy assert on every save.
    _syncDebounce =
        _outsideMutations.run(() => Timer(_syncDebounceDelay, _autoSync));
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

  /// Name a tab explicitly, or clear the name (null or blank) to return it to
  /// shell-derived naming.
  ///
  /// The name is collapsed to one line the same way remote labels are — not
  /// because the user is untrusted, but because a tab chip is one line of
  /// chrome and a pasted newline would break the strip either way.
  void renameSession(String sessionId, String? name) {
    final session = sessionById(sessionId);
    if (session == null) return;
    final cleaned = name == null ? '' : sanitizeRemoteLabel(name);
    // Only the chip repaints: the name lives on the session's own notifier,
    // so renaming a tab does not rebuild the app the way notifyListeners
    // would.
    session.customName.value = cleaned.isEmpty ? null : cleaned;
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

  /// Apply a change of the "keep sessions alive in the background" setting:
  /// re-anchor or drop the OS-level keep-alive for the currently live sessions.
  void setKeepSessionsAliveEnabled(bool enabled) {
    _keepAlive.setEnabled(enabled);
    _refreshKeepAlive();
  }

  /// Recompute how many sessions are connecting or connected and tell the
  /// keep-alive — that count, not the session identities, is all it needs.
  /// Called after every mutation of a session's connection state.
  void _refreshKeepAlive() {
    _keepAlive.refresh(
      sessions.where((s) => s.connecting || s.session != null).length,
    );
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

  // --- Terminal appearance ---

  /// Change the terminal font size by [delta] points (the ⌘+ / ⌘− shortcuts),
  /// or reset it to the default when [delta] is null (⌘0). Clamped to the
  /// supported range; a no-op change neither notifies nor writes to disk.
  Future<void> zoomTerminal(double? delta) async {
    final settings = services.settings;
    final next = clampTerminalFontSize(
      delta == null
          ? kDefaultTerminalFontSize
          : settings.terminalFontSize + delta,
    );
    if (next == settings.terminalFontSize) return;
    settings.terminalFontSize = next;
    notifyListeners();
    await services.saveSettings();
  }

  /// Repaint live terminals after the appearance settings changed in place
  /// (the settings screen owns the write; this only refreshes the views).
  void terminalAppearanceChanged() => notifyListeners();

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
    _refreshKeepAlive();
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

  Future<void> reconcileRetainedLocalCopy(
    String sessionId,
    ManagedRemoteFile copy,
  ) async {
    final tab = sessionById(sessionId);
    if (tab == null) return;
    final updated = await services.managedRemoteFiles.reconcile(copy.id);
    if (updated == null ||
        tab.retainedLocalCopies[copy.remotePath]?.id != copy.id) {
      return;
    }
    tab.retainedLocalCopies[copy.remotePath] = updated;
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
    _refreshKeepAlive();
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
    // Nothing anchors a dying app: drop the OS keep-alive before the sessions
    // it was holding open go.
    _keepAlive.stop();
    chat.dispose();
    // Drop the callback before the service goes: it closes over `sessions`,
    // so a probe service that outlived this state would keep reading a list
    // that is no longer maintained (and keep this object alive).
    services.probe.connectedServerIds = null;
    services.probe.dispose();
    for (final t in sessions) {
      // Teardown is asynchronous but nothing can await it here: swallow the
      // failure explicitly rather than leaving an unhandled async error to
      // surface long after the state object is gone.
      unawaited(
        _disposeSession(t).catchError((Object error, StackTrace stack) {
          debugPrint('Session teardown failed: $error\n$stack');
        }),
      );
    }
    // Teardown is in flight and does not read this list; clearing it makes the
    // contract explicit — nothing may reach a session after this point.
    sessions.clear();
    super.dispose();
  }
}
