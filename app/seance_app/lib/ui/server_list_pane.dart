import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../main.dart';
import '../theme.dart';
import 'app_menus.dart';
import 'server_editor.dart';
import 'server_filter.dart';
import 'server_grouping.dart';
import 'server_list_density.dart';
import 'server_status_dot.dart';
import 'server_tile.dart';
import 'settings_screen.dart';
import 'sidebar/sidebar_kit.dart';
import 'top_toast.dart';

/// Where the server list is mounted, which decides its chrome.
enum ServerListPosture {
  /// The wide layout's left rail: the sibling sidebar anatomy (Poltergeist's
  /// plan, 10 §5) with no app bar, a filter field at the top and the bottom
  /// bar's "+" menu, sync status and gear at the foot.
  rail,

  /// The narrow layout's home screen, full screen (10 §9, §10.6): an app
  /// bar, the same sections and rows at the platform's row extent, and a
  /// "+" button that adds a server.
  home,
}

/// The copy the sibling kit renders, in Séance's words. Public so a widget
/// test can pump a kit header or row exactly as the pane does.
final SidebarKitStrings serverSidebarStrings = SidebarKitStrings(
  sectionSemantics: (title, count) =>
      '$title, $count ${count == 1 ? 'server' : 'servers'}',
  showSection: 'Show',
  hideSection: 'Hide',
  filterHint: 'Filter servers…',
  filterClear: 'Clear filter',
  addMenu: 'New server or import',
  settings: 'Sync & settings',
  rowMenu: 'More actions',
  compactRows: 'Compact rows',
  comfortableRows: 'Comfortable rows',
);

/// The configured servers with their live state, in the sibling rail's
/// sections. Tapping one opens a terminal (via [onOpen]).
class ServerListPane extends StatefulWidget {
  final void Function(ServerConfig server) onOpen;
  final ServerListPosture posture;

  const ServerListPane({
    super.key,
    required this.onOpen,
    required this.posture,
  });

  /// Below this many servers the list is short enough to read at a glance
  /// and the filter would just be chrome (10 §5). The field still shows while
  /// a query is live, and on demand through [revealFilter].
  static const int filterThreshold = 8;

  static final List<_ServerListPaneState> _mounted = [];

  /// Show and focus the filter field of the pane on screen (⌥⌘F, or
  /// Ctrl+Alt+F off Apple platforms). Returns false when no pane is mounted
  /// to take it, or when its list has nothing to filter: the onboarding
  /// state draws no field, and a reveal remembered from then would pop one
  /// open the moment the first server arrived. The newest pane wins: during
  /// the narrow layout's screen switch the outgoing one is still mounted,
  /// and is not the one the user is looking at.
  static bool revealFilter() {
    if (_mounted.isEmpty) return false;
    return _mounted.last._revealFilter();
  }

  @override
  State<ServerListPane> createState() => _ServerListPaneState();
}

class _ServerListPaneState extends State<ServerListPane> {
  /// Bottom padding that lets the last row scroll clear of the home screen's
  /// floating "+" button, so a row's "⋮" is never tapped through to the
  /// button: 56 (button) + 16 (endFloat margin) + 16 (gap). The geometry
  /// assertion in server_list_pane_test.dart fails if a button change ever
  /// erodes the gap.
  static const double _fabScrollClearance = 56 + 16 + 16;

  /// How often the "Synced · 2 min" age is repainted while it shows.
  static const Duration _syncAgeRefresh = Duration(seconds: 30);

  /// Where the query outlives the pane. The narrow layout disposes the home
  /// list while a terminal shows; back must return to the list as it was
  /// (10 §10.6), so the query and the scroll offset are kept in the route's
  /// page storage, which outlives the swap.
  static const String _queryStorageId = 'servers.filter.query';

  final _filterFocus = FocusNode();
  String _query = '';
  bool _queryRestored = false;

  /// Opened by [ServerListPane.revealFilter] on a list below the threshold;
  /// Esc on an empty field closes it again.
  bool _filterOpen = false;

  Timer? _syncAgeTicker;

  @override
  void initState() {
    super.initState();
    ServerListPane._mounted.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_queryRestored) return;
    _queryRestored = true;
    final saved = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _queryStorageId);
    if (saved is String) _query = saved;
  }

  @override
  void dispose() {
    ServerListPane._mounted.remove(this);
    _syncAgeTicker?.cancel();
    _filterFocus.dispose();
    super.dispose();
  }

  void _setQuery(String value) {
    setState(() => _query = value);
    PageStorage.maybeOf(
      context,
    )?.writeState(context, value, identifier: _queryStorageId);
  }

  void _clearQuery() => _setQuery('');

  /// Opens and focuses the field; false, with nothing latched, while the
  /// list is empty (see [ServerListPane.revealFilter]).
  bool _revealFilter() {
    if (AppScope.of(context).servers.isEmpty) return false;
    setState(() => _filterOpen = true);
    // The field may be mounting in this very frame: focus it after.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _filterFocus.requestFocus();
    });
    return true;
  }

  /// Esc: a live query clears first; an empty field then hands control back
  /// (and closes, if it was only open on request).
  void _dismissFilter() {
    if (_query.isNotEmpty) {
      _clearQuery();
      return;
    }
    setState(() => _filterOpen = false);
    _filterFocus.unfocus();
  }

  /// Drop a stale query once the list it filtered is empty, so adding a server
  /// afterwards shows it instead of "No servers match". Deferred to after the
  /// frame because this is observed from inside a build.
  void _dropStaleQuery() {
    if (_query.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _query.isNotEmpty) _clearQuery();
    });
  }

  /// Open the first match — the fast path for "type three letters, hit return,
  /// you're on the box". Deliberately works with several matches too.
  ///
  /// Matches are recomputed here rather than captured from the build that
  /// wired this up: typing and submitting inside one frame would otherwise act
  /// on a list one keystroke out of date.
  ///
  /// "First" is the first row the user can *see*, which is why this goes
  /// through the same sectioning the list renders rather than taking the head
  /// of the filtered list: pinning floats a match to the top and grouping
  /// sorts groups by name, so store order is not what the eye reads. A live
  /// query overrides every collapsed section (see [_serverList]), so no row
  /// counted here is folded away.
  void _openFirstMatch() {
    if (_query.isEmpty) return;
    final state = AppScope.of(context);
    final rows = serverListRows(
      sections: _sections(state, filterServers(state.servers, _query)),
      collapsedKeys: const {},
    );
    final first = rows.whereType<ServerRow>().firstOrNull;
    if (first == null) return;
    _filterFocus.unfocus();
    widget.onOpen(first.server);
  }

  /// The sections the list is drawn from.
  ///
  /// One definition, because "the first row" has to mean the same thing to
  /// [_openFirstMatch] as to the eye reading [_serverList] — and pinning is
  /// exactly what makes those two orders differ from the store's.
  ServerSidebarSections _sections(AppState state, List<ServerConfig> servers) =>
      groupServers(servers, pinnedIds: state.pinnedServerIds);

  bool get _home => widget.posture == ServerListPosture.home;

  /// The phone home at [density] (the kit's [sidebarHomeLayout]): an
  /// Android list when comfortable, the same list Poltergeist's Home uses
  /// (sibling contract §10.6), and one-line touch rows when compact. The
  /// rail, on a desktop or a tablet, and a narrow desktop window are
  /// rail-drawn at either density.
  SidebarKitLayout _layoutFor(BuildContext context, SidebarKitDensity density) {
    final touch = switch (Theme.of(context).platform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => true,
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => false,
    };
    return _home && touch ? sidebarHomeLayout(density) : SidebarKitLayout.rail;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final chrome = SeanceChrome.of(context);
    final background = _home
        ? Theme.of(context).colorScheme.surface
        : chrome.sidebarBackground;
    final body = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        // The one density gate: every posture follows the preference, and
        // the kit derives what each density draws from it.
        final density = state.serverListDensity.kit;
        return SidebarKitScope(
          strings: serverSidebarStrings,
          background: background,
          layout: _layoutFor(context, density),
          density: density,
          child: Builder(builder: (context) => _body(context, state)),
        );
      },
    );
    // A Material rather than a bare fill: the filter field and the kit's
    // buttons ink on it, and the rail must not depend on a Scaffold above.
    if (!_home) return Material(color: background, child: body);
    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        title: const Text('Séance'),
        actions: [
          ListenableBuilder(
            listenable: state,
            builder: (context, _) =>
                _SyncIndicator(state: state, onRetry: () => _syncNow(state)),
          ),
          ListenableBuilder(
            listenable: state,
            builder: (context, _) => _DensitySwitch(state: state),
          ),
          IconButton(
            tooltip: 'Import SSH config',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _importConfig(context, state),
          ),
          IconButton(
            tooltip: serverSidebarStrings.settings,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(context),
          ),
        ],
      ),
      body: body,
      floatingActionButton: FloatingActionButton(
        tooltip: 'New server',
        onPressed: () => _editServer(context, state, null),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _body(BuildContext context, AppState state) {
    final servers = state.servers;
    if (servers.isEmpty) _dropStaleQuery();
    final matches = filterServers(servers, _query);
    // Kept once a query is active even if the match count drops below the
    // threshold, or filtering would strand an uneditable filter with no way
    // to clear it. Never above the onboarding empty state: a filter box
    // beside "No servers yet" reads as "your servers are hidden" rather than
    // "you have none".
    final showFilter =
        servers.isNotEmpty &&
        (servers.length >= ServerListPane.filterThreshold ||
            _query.isNotEmpty ||
            _filterOpen);
    final Widget list;
    if (servers.isEmpty) {
      list = _EmptyState(
        onNewServer: () => _editServer(context, state, null),
        onImport: () => _importConfig(context, state),
      );
    } else if (matches.isEmpty) {
      list = _NoMatches(onClear: _clearQuery);
    } else {
      list = _serverList(context, state, matches);
    }
    final update = state.updateInfo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A newer release exists: a dismissible banner above the list.
        if (update != null)
          _UpdateBanner(info: update, onDismiss: state.dismissUpdateNotice),
        if (showFilter)
          SidebarFilterField(
            key: const ValueKey('servers.filter'),
            fieldKey: const ValueKey('servers.filter.field'),
            query: _query,
            focusNode: _filterFocus,
            onChanged: _setQuery,
            onDismiss: _dismissFilter,
            // A no-op on an empty query, so Enter in an empty field cannot
            // connect to whichever server is first.
            onSubmitted: _openFirstMatch,
            countText: _query.isEmpty
                ? null
                : '${matches.length} of ${servers.length}',
          ),
        Expanded(child: list),
        if (!_home)
          SidebarBottomBar(
            key: const ValueKey('servers.bottomBar'),
            addKey: const ValueKey('servers.add'),
            settingsKey: const ValueKey('servers.settings'),
            addEntries: () => [
              SidebarMenuAction(
                key: const ValueKey('servers.add.newServer'),
                label: 'New server…',
                onSelected: () => _editServer(context, state, null),
              ),
              SidebarMenuAction(
                key: const ValueKey('servers.add.import'),
                label: 'Import SSH config…',
                onSelected: () => _importConfig(context, state),
              ),
            ],
            sync: _syncChip(state),
            onSettings: () => _openSettings(context),
          ),
      ],
    );
  }

  Widget _serverList(
    BuildContext context,
    AppState state,
    List<ServerConfig> servers,
  ) {
    final rows = serverListRows(
      sections: _sections(state, servers),
      // A live query overrides every collapsed section. Otherwise the filter
      // would report "3 of 12" and show one row, with the other two folded
      // away behind a header the user never opened — which reads as the filter
      // being broken rather than as the list being tidy.
      collapsedKeys: _query.isEmpty ? state.collapsedServerGroups : const {},
    );
    // What each header folds or filters out of view, measured against the
    // whole list, so a hidden live session still shows on its header.
    final hidden = hiddenByHeader(
      sections: _sections(state, state.servers),
      rows: rows,
    );
    // The home screen lets the ListView take the ambient insets (the
    // gesture-nav bar on Android) and extends the bottom one by the floating
    // button's clearance; an explicit EdgeInsets must neither drop the
    // bottom inset nor add side insets the default never had.
    final safeAreaInsets = MediaQuery.paddingOf(context);
    final padding = _home
        ? safeAreaInsets.copyWith(
            left: 0,
            right: 0,
            top: safeAreaInsets.top + 4,
            bottom: safeAreaInsets.bottom + _fabScrollClearance,
          )
        : const EdgeInsets.only(top: 4, bottom: 8);
    // Built eagerly, not lazily: the rows move focus with ↑/↓ through the
    // focus tree, and a row a lazy list has not built is not in it.
    return ListView(
      // Restores the scroll offset when the home list comes back from a
      // terminal (see [_queryStorageId]).
      key: PageStorageKey<String>('servers.list.${widget.posture.name}'),
      padding: padding,
      children: [
        for (final row in rows)
          switch (row) {
            ServerSectionRow(
              :final title,
              :final key,
              :final count,
              :final collapsed,
            ) =>
              SidebarSectionHeader(
                key: ValueKey('servers.section.$key'),
                headerKey: ValueKey('servers.section.header.$key'),
                title: title,
                count: count,
                collapsed: collapsed,
                status: _hiddenLiveDot(context, state, hidden[key]),
                onToggle: () => state.toggleServerGroup(key),
                // SERVERS' "+" adds to it; the shortlist is filled from a
                // row's menu, so PINNED has none. The home screen's floating
                // "+" already does this, so a second one is left off there.
                onAdd: key == kServersKey && !_home
                    ? () => _editServer(context, state, null)
                    : null,
                addKey: const ValueKey('servers.section.add'),
                addTooltip: 'New server',
              ),
            ServerGroupHeaderRow(
              :final name,
              :final key,
              :final count,
              :final collapsed,
            ) =>
              SidebarSectionHeader(
                key: ValueKey('servers.group.$key'),
                headerKey: ValueKey('servers.group.header.$key'),
                nested: true,
                title: name,
                count: count,
                collapsed: collapsed,
                status: _hiddenLiveDot(context, state, hidden[key]),
                onToggle: () => state.toggleServerGroup(key),
              ),
            ServerRow(:final server, :final depth) => _tile(
              context,
              state,
              server,
              depth,
            ),
          },
      ],
    );
  }

  /// A header's dot for the live sessions it keeps out of view: green while
  /// one of [servers] is connected, amber while one is connecting. A
  /// failure is left to its row: folding a group is a choice not to look,
  /// and what must not vanish with it is a connection still open.
  SidebarStatusDot? _hiddenLiveDot(
    BuildContext context,
    AppState state,
    List<ServerConfig>? servers,
  ) {
    if (servers == null) return null;
    final live = {
      for (final server in servers)
        for (final tab in state.tabsForServer(server.id))
          if (tab is TerminalSession) tab.status,
    };
    final dot = live.contains(TerminalStatus.connected)
        ? ServerDot.connected
        : live.contains(TerminalStatus.connecting)
        ? ServerDot.connecting
        : null;
    if (dot == null) return null;
    return SidebarStatusDot(dot.color(context)!, style: dot.style);
  }

  Widget _tile(
    BuildContext context,
    AppState state,
    ServerConfig server,
    int depth,
  ) {
    final tabs = state.tabsForServer(server.id);
    final terminals = tabs.whereType<TerminalSession>().toList();
    final session = aggregateSessionStatus(terminals);
    final live = terminals.where((t) => t.status == TerminalStatus.connected);
    final dead =
        terminals.length == 1 &&
        (session == TerminalStatus.disconnected ||
            session == TerminalStatus.error);
    return ServerTile(
      // Stable identity so a background sync replacing the list reconciles
      // each row to its server instead of by position.
      key: ValueKey(server.id),
      server: server,
      dot: serverDotFor(
        session: session,
        probe: state.statuses[server.id] ?? ProbeStatus.unknown,
        hostKeyBlocked: terminals.any(
          (t) => t.status == TerminalStatus.error && t.hostKeyBlocked,
        ),
      ),
      tabCount: tabs.length,
      selected: server.id == state.activeServerId,
      pinned: state.isServerPinned(server.id),
      depth: depth,
      onOpen: () => widget.onOpen(server),
      onNewTab: () => state.newTab(server),
      onEdit: () => _editServer(context, state, server),
      onDuplicate: () => _duplicateServer(context, state, server),
      onDelete: () => _deleteServer(context, state, server),
      onTogglePin: () => state.toggleServerPin(server.id),
      // Disconnect every live terminal; reconnect the lone dead one.
      onDisconnect: live.isEmpty
          ? null
          : () {
              for (final t in live.toList()) {
                state.disconnect(t.id);
              }
            },
      onReconnect: dead ? () => state.reconnect(terminals.single.id) : null,
    );
  }

  /// One sync round now: the chip's retry. The outcome lands in the shared
  /// sync status the chip repaints from, so nothing is lost by not awaiting
  /// the error here.
  void _syncNow(AppState state) {
    unawaited(
      state.syncNow().then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          developer.log(
            'Sync from the server list failed',
            name: 'seance.app',
            level: 800,
            error: error,
            stackTrace: stackTrace,
          );
        },
      ),
    );
  }

  /// The bottom bar's sync status (10 §5): "Synced · 2 min", a spinner, or
  /// a red "Sync failed" whose click retries; "Sync off" leads to setting it
  /// up.
  SidebarSyncChipData _syncChip(AppState state) {
    const key = ValueKey('servers.syncChip');
    final ageShown =
        state.services.isSyncConfigured &&
        !state.syncing &&
        state.lastSyncError == null &&
        state.lastSyncAt != null;
    _tickSyncAge(ageShown);
    if (!state.services.isSyncConfigured) {
      return SidebarSyncChipData(
        key: key,
        label: 'Sync off',
        tone: SidebarSyncTone.muted,
        tooltip: 'Set up sync',
        onPressed: () => openSettings(SettingsTab.sync),
      );
    }
    if (state.syncing) {
      return const SidebarSyncChipData(
        key: key,
        label: 'Syncing…',
        tone: SidebarSyncTone.busy,
      );
    }
    final error = state.lastSyncError;
    if (error != null) {
      return SidebarSyncChipData(
        key: key,
        label: 'Sync failed',
        tone: SidebarSyncTone.error,
        tooltip: '$error\nClick to retry',
        onPressed: () => _syncNow(state),
      );
    }
    final last = state.lastSyncAt;
    return SidebarSyncChipData(
      key: key,
      label: last == null
          ? 'Not synced yet'
          : 'Synced · ${syncAgeLabel(DateTime.now().difference(last))}',
      tone: SidebarSyncTone.normal,
      tooltip: 'Sync now',
      onPressed: () => _syncNow(state),
    );
  }

  /// "2 min" goes stale between rounds; a slow ticker repaints it while it
  /// shows, and stops when it does not.
  void _tickSyncAge(bool shown) {
    if (!shown) {
      _syncAgeTicker?.cancel();
      _syncAgeTicker = null;
      return;
    }
    _syncAgeTicker ??= Timer.periodic(_syncAgeRefresh, (_) {
      if (mounted) setState(() {});
    });
  }

  static void _openSettings(
    BuildContext context, [
    SettingsTab tab = SettingsTab.general,
  ]) => openSettings(tab);

  Future<void> _editServer(
    BuildContext context,
    AppState state,
    ServerConfig? server,
  ) async {
    await showServerEditor(context, state, server);
  }

  /// Copy a server, then offer the editor — duplicating is almost always the
  /// first half of "…and change one thing", and the toast's action is a
  /// shorter route back than finding the new row and reopening its menu.
  Future<void> _duplicateServer(
    BuildContext context,
    AppState state,
    ServerConfig server,
  ) async {
    final ServerConfig copy;
    try {
      copy = await state.duplicateServer(server);
    } on SourceServerChanged catch (error) {
      // Verbatim: this one is written as a whole sentence *for* this toast,
      // and "Could not duplicate: …Nothing was created." says it twice.
      if (context.mounted) {
        showTopToastIn(context, message: '$error');
      } else {
        // Nowhere to show it. Logged so the refusal is not the failure that
        // vanished — the same reason the branch below logs.
        developer.log(
          'Could not duplicate "${server.label}": $error',
          name: 'seance.app',
          level: 900,
          error: error,
        );
      }
      return;
    } catch (error, stackTrace) {
      // The vault throws when the OS keyring is locked. Say so rather than
      // leaving the menu looking like it did nothing — and name the server,
      // because a toast is all the user gets and two rows can fail apart.
      // The error itself stays verbatim: `VaultLockedException.toString()` is
      // the sentence that says what to do about it.
      final message = 'Could not duplicate "${server.label}": $error';
      // Logged whether or not there is a toast to show: the toast and the
      // log are for different readers. With the trace, because this catch is
      // broad, and for the failures it was not written for the message names
      // the server and nothing else — no throw site to tell a locked keyring
      // from a bug in the vault.
      developer.log(
        message,
        name: 'seance.app',
        level: 900,
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) showTopToastIn(context, message: message);
      return;
    }
    if (!context.mounted) return;
    showTopToastIn(
      context,
      message: 'Duplicated as "${copy.label}"',
      actionLabel: 'Edit',
      // Checked again inside the closure, not only before showing the toast:
      // the action fires whenever the user taps it, which can be after this
      // pane is gone, and a defunct context reaches showDialog as an ancestor
      // lookup on a deactivated widget.
      onAction: () {
        if (context.mounted) _editServer(context, state, copy);
      },
    );
  }

  Future<void> _deleteServer(
    BuildContext context,
    AppState state,
    ServerConfig server,
  ) async {
    final localCopyCount = state
        .tabsForServer(server.id)
        .whereType<TerminalSession>()
        .fold<int>(
          0,
          (count, session) =>
              count +
              (session.files?.localCopies.length ?? 0) +
              session.retainedLocalCopies.length,
        );
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${server.label}"?'),
        content: Text(
          localCopyCount == 0
              ? 'This removes the server and any stored secret.'
              : 'This removes the server, its stored secret, and '
                    '$localCopyCount managed local '
                    '${localCopyCount == 1 ? 'edit' : 'edits'}. Any changes not '
                    'uploaded to the server will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await state.deleteServer(server.id);
  }

  Future<void> _importConfig(BuildContext context, AppState state) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Import SSH config'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: 'Paste the contents of ~/.ssh/config …',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) {
      final n = await state.importSshConfig(text);
      if (context.mounted) {
        showTopToastIn(context, message: 'Imported $n host(s)');
      }
    }
  }
}

/// How long ago a sync round finished, as the chip says it: "just now",
/// "2 min", "3 h", "2 d".
String syncAgeLabel(Duration age) {
  if (age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes} min';
  if (age.inDays < 1) return '${age.inHours} h';
  return '${age.inDays} d';
}

/// The home screen's app-bar sync affordance: a spinner while a round runs,
/// an error badge if the last one failed (tapping retries, as the rail's
/// chip does). Hidden when idle and healthy: the gear beside it leads to
/// sync.
class _SyncIndicator extends StatelessWidget {
  final AppState state;
  final VoidCallback onRetry;
  const _SyncIndicator({required this.state, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (state.syncing) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (state.lastSyncError != null) {
      return IconButton(
        tooltip: 'Sync failed — tap to retry',
        icon: Icon(
          Icons.sync_problem,
          color: Theme.of(context).colorScheme.error,
        ),
        onPressed: onRetry,
      );
    }
    return const SizedBox.shrink();
  }
}

/// A dismissible banner above the server list when a newer release exists on
/// GitHub. It only offers a link to the releases page — Séance never
/// downloads or installs an update; the user decides. Compact, because the
/// rail it sits in can be 200 px wide.
class _UpdateBanner extends StatelessWidget {
  final UpdateInfo info;
  final VoidCallback onDismiss;
  const _UpdateBanner({required this.info, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = scheme.onSecondaryContainer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(10, 4, 2, 4),
          child: Row(
            children: [
              Icon(Icons.system_update_outlined, size: 16, color: ink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Séance ${info.latestVersion} is available.',
                  style: theme.textTheme.bodySmall?.copyWith(color: ink),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: () => launchUrl(
                  info.releasesUrl,
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('View release'),
              ),
              IconButton(
                tooltip: 'Dismiss',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close, color: ink),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The home screen's view control: whether a row spells its address out on a
/// second line.
///
/// A segmented button rather than a menu: both choices are in view, the
/// current one is the filled segment, and switching is one tap. A third
/// density would be a third segment, which is why the segments are built
/// from the enum rather than written out. The rail has no such control: its
/// rows are one line by the sibling anatomy, with the address in the tooltip.
class _DensitySwitch extends StatelessWidget {
  final AppState state;
  const _DensitySwitch({required this.state});

  /// A switch rather than a ternary because a third density is addable: a
  /// ternary would draw it with the comfortable icon while its own tooltip
  /// said otherwise, and nothing would complain.
  static IconData _icon(ServerListDensity density) => switch (density) {
    ServerListDensity.comfortable => Icons.density_medium,
    ServerListDensity.compact => Icons.density_small,
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Center(
        child: SegmentedButton<ServerListDensity>(
          segments: [
            for (final density in ServerListDensity.values)
              ButtonSegment(
                value: density,
                icon: Icon(_icon(density)),
                // The label, as a tooltip: icons alone fit the app bar, and
                // the tooltip is also what a screen reader gets.
                tooltip: density.label,
              ),
          ],
          selected: {state.serverListDensity},
          showSelectedIcon: false,
          // Tightened to the app bar: at its default size the button is as
          // tall as the bar's icons' tap targets and visibly heavier. The
          // tap target itself is left to the theme, which pads it to 48 on
          // touch platforms and shrink-wraps it on desktop.
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          onSelectionChanged: (selection) =>
              state.setServerListDensity(selection.single),
        ),
      ),
    );
  }
}

/// Shown when a filter excludes every server — distinct from having no
/// servers at all, which needs the onboarding empty state instead.
class _NoMatches extends StatelessWidget {
  final VoidCallback onClear;
  const _NoMatches({required this.onClear});

  @override
  Widget build(BuildContext context) {
    final chrome = SeanceChrome.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 32, color: chrome.secondaryText),
            const SizedBox(height: 8),
            Text(
              'No servers match',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: onClear, child: const Text('Clear filter')),
          ],
        ),
      ),
    );
  }
}

/// The onboarding state: no servers yet. Every way in is a visible button,
/// because the rail's "+" and gear are small, and a fresh install —
/// especially on a phone — needs an obvious path to the sync-server setup.
class _EmptyState extends StatelessWidget {
  final VoidCallback onNewServer;
  final VoidCallback onImport;
  const _EmptyState({required this.onNewServer, required this.onImport});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = SeanceChrome.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 40, color: chrome.secondaryText),
            const SizedBox(height: 12),
            Text('No servers yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Add one, import your ~/.ssh/config, or sign in to sync.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: chrome.secondaryText,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onNewServer,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New server'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Import SSH config'),
            ),
            TextButton.icon(
              onPressed: () => openSettings(),
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('Sync & settings'),
            ),
          ],
        ),
      ),
    );
  }
}
