import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../main.dart';
import '../theme.dart';
import 'app_menus.dart';
import 'middle_ellipsis_text.dart';
import 'server_appearance.dart';
import 'server_editor.dart';
import 'server_filter.dart';
import 'server_grouping.dart';
import 'settings_screen.dart';
import 'top_toast.dart';

/// Left pane / first screen: the configured servers with a reachability dot.
/// Tapping one opens a terminal (via [onOpen]).
class ServerListPane extends StatefulWidget {
  final void Function(ServerConfig server) onOpen;
  const ServerListPane({super.key, required this.onOpen});

  /// Below this many servers the list is short enough to read at a glance and
  /// the filter would just be chrome. Matches the Snippets pane's threshold.
  static const int filterThreshold = 5;

  @override
  State<ServerListPane> createState() => _ServerListPaneState();
}

class _ServerListPaneState extends State<ServerListPane> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _setQuery(String value) => setState(() => _query = value);

  void _clearQuery() {
    _search.clear();
    _setQuery('');
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
  /// you're on the box". Deliberately works with several matches too; the
  /// helper text says which one Enter will take.
  ///
  /// Matches are recomputed here rather than captured from the build that
  /// wired this up: typing and submitting inside one frame would otherwise act
  /// on a list one keystroke out of date.
  void _openFirstMatch() {
    if (_query.isEmpty) return;
    final matches = filterServers(AppScope.of(context).servers, _query);
    if (matches.isEmpty) return;
    _searchFocus.unfocus();
    widget.onOpen(matches.first);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Séance'),
        actions: [
          ListenableBuilder(
            listenable: state,
            builder: (context, _) => _SyncIndicator(
              state: state,
              onTap: () => _openSettings(context, SettingsTab.sync),
            ),
          ),
          IconButton(
            tooltip: 'Import ~/.ssh/config',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _importConfig(context, state),
          ),
          IconButton(
            tooltip: 'Sync & settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          if (state.servers.isEmpty) _dropStaleQuery();
          final matches = filterServers(state.servers, _query);
          // Keep the field once a query is active even if the match count
          // drops below the threshold, or filtering would strand an
          // uneditable filter with no way to clear it.
          // Never above the onboarding empty state: a filter box beside
          // "No servers yet" reads as "your servers are hidden" rather than
          // "you have none".
          final showFilter =
              state.servers.isNotEmpty &&
              (state.servers.length >= ServerListPane.filterThreshold ||
                  _query.isNotEmpty);
          final Widget list;
          if (state.servers.isEmpty) {
            list = const _EmptyState();
          } else if (matches.isEmpty) {
            list = _NoMatches(onClear: _clearQuery);
          } else {
            list = _serverList(context, state, matches);
          }
          final update = state.updateInfo;
          return Column(
            children: [
              // A newer release exists: a dismissible banner above the list.
              if (update != null)
                _UpdateBanner(
                  info: update,
                  onDismiss: state.dismissUpdateNotice,
                ),
              if (showFilter)
                _filterField(matches, state.servers.length),
              Expanded(child: list),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editServer(context, state, null),
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
    );
  }

  Widget _filterField(List<ServerConfig> matches, int totalServers) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Shortcuts(
        // Escape clears rather than propagating; there is nothing else in this
        // pane for it to dismiss.
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                _clearQuery();
                return null;
              },
            ),
          },
          child: TextField(
            controller: _search,
            focusNode: _searchFocus,
            onChanged: _setQuery,
            // _openFirstMatch is a no-op on an empty query, so Enter in an
            // empty field cannot connect to whichever server is first.
            onSubmitted: (_) => _openFirstMatch(),
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Filter servers…',
              helperText: _query.isEmpty
                  ? null
                  // Enter is a no-op with nothing to open, so don't offer it.
                  : matches.isEmpty
                  ? '0 of $totalServers'
                  : '${matches.length} of $totalServers · ↵ opens the first',
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear filter',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: _clearQuery,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _serverList(
    BuildContext context,
    AppState state,
    List<ServerConfig> servers,
  ) {
    final rows = serverListRows(
      sections: groupServers(servers),
      // A live query overrides every collapsed section. Otherwise the filter
      // would report "3 of 12" and show one row, with the other two folded
      // away behind a header the user never opened — which reads as the filter
      // being broken rather than as the list being tidy.
      collapsedKeys: _query.isEmpty ? state.collapsedServerGroups : const {},
    );
    return ListView.separated(
      itemCount: rows.length,
      // Rules belong between servers, not under a section header — the
      // header's own fill already separates it from what follows.
      separatorBuilder: (_, i) =>
          rows[i] is ServerRow && rows[i + 1] is ServerRow
          ? const Divider(height: 1)
          : const SizedBox.shrink(),
      itemBuilder: (context, i) => switch (rows[i]) {
        ServerGroupHeaderRow(
          :final name,
          :final key,
          :final count,
          :final collapsed,
        ) =>
          ServerGroupHeader(
            name: name,
            count: count,
            collapsed: collapsed,
            onToggle: () => state.toggleServerGroup(key),
          ),
        ServerRow(:final server) => _tile(context, state, server),
      },
    );
  }

  Widget _tile(BuildContext context, AppState state, ServerConfig server) {
    final reachability = state.statuses[server.id] ?? ProbeStatus.unknown;
    final tabs = state.sessionsForServer(server.id);
    return ServerTile(
      // Stable identity so a background sync replacing the list
      // reconciles each tile to its server instead of by position.
      key: ValueKey(server.id),
      server: server,
      connection: _aggregateStatus(tabs),
      tabCount: tabs.length,
      reachability: reachability,
      selected: server.id == state.activeServerId,
      onTap: () => widget.onOpen(server),
      onNewTab: () => state.newTab(server),
      onEdit: () => _editServer(context, state, server),
      onDuplicate: () => _duplicateServer(context, state, server),
      onDelete: () => _deleteServer(context, state, server),
      // Disconnect every live tab; reconnect the lone dead tab.
      onDisconnect: () {
        for (final t in tabs) {
          if (t.status == TerminalStatus.connected) {
            state.disconnect(t.id);
          }
        }
      },
      onReconnect: tabs.length == 1
          ? () => state.reconnect(tabs.first.id)
          : null,
    );
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
    } catch (error) {
      // The vault throws when the OS keyring is locked. Say so rather than
      // leaving the menu looking like it did nothing.
      if (context.mounted) {
        showTopToastIn(context, message: 'Could not duplicate: $error');
      }
      return;
    }
    if (!context.mounted) return;
    showTopToastIn(
      context,
      message: 'Duplicated as "${copy.label}"',
      actionLabel: 'Edit',
      onAction: () => _editServer(context, state, copy),
    );
  }

  Future<void> _deleteServer(
    BuildContext context,
    AppState state,
    ServerConfig server,
  ) async {
    final localCopyCount = state
        .sessionsForServer(server.id)
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

/// A compact header affordance that shows background-sync activity: a spinner
/// while a round runs, an error badge if the last one failed. Hidden when idle
/// and healthy (the gear icon already leads to sync). Tapping opens settings.
class _SyncIndicator extends StatelessWidget {
  final AppState state;
  final VoidCallback onTap;
  const _SyncIndicator({required this.state, required this.onTap});

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
        tooltip: 'Last sync failed — open settings',
        icon: Icon(
          Icons.cloud_off_outlined,
          color: Theme.of(context).colorScheme.error,
        ),
        onPressed: onTap,
      );
    }
    return const SizedBox.shrink();
  }
}

/// A dismissible banner shown above the server list when a newer release
/// exists on GitHub. It only offers a link to the releases page — Séance never
/// downloads or installs an update; the user decides.
class _UpdateBanner extends StatelessWidget {
  final UpdateInfo info;
  final VoidCallback onDismiss;
  const _UpdateBanner({required this.info, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Icons.system_update_outlined,
              size: 20,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Séance ${info.latestVersion} is available.',
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ),
            TextButton(
              onPressed: () => launchUrl(
                info.releasesUrl,
                mode: LaunchMode.externalApplication,
              ),
              child: const Text('View release'),
            ),
            IconButton(
              tooltip: 'Dismiss',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

/// Aggregate a server's tab statuses into the single dot shown on its row:
/// any connecting wins (spinner), else any connected (green), else any error
/// (red), else disconnected/none (grey).
TerminalStatus _aggregateStatus(List<TerminalSession> tabs) {
  if (tabs.any((t) => t.status == TerminalStatus.connecting)) {
    return TerminalStatus.connecting;
  }
  if (tabs.any((t) => t.status == TerminalStatus.connected)) {
    return TerminalStatus.connected;
  }
  if (tabs.any((t) => t.status == TerminalStatus.error)) {
    return TerminalStatus.error;
  }
  return TerminalStatus.disconnected;
}

/// One server's row in the list.
///
/// Public, like [ServerGroupHeader] and unlike the rest of this pane's parts,
/// so a widget test can assert what the row says without standing up an
/// [AppState]: the sync-exclusion mark is an icon, and what a screen reader
/// makes of an icon is not something to assume.
class ServerTile extends StatelessWidget {
  final ServerConfig server;
  final TerminalStatus connection;

  /// Number of open sessions (tabs) for this server; a small "×N" appears
  /// beside the dot when >1.
  final int tabCount;
  final ProbeStatus reachability;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onNewTab;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final VoidCallback onDisconnect;

  /// Only offered when the server has exactly one (dead) tab; per-tab
  /// reconnect otherwise lives in the pane.
  final VoidCallback? onReconnect;

  const ServerTile({
    super.key,
    required this.server,
    required this.connection,
    required this.tabCount,
    required this.reachability,
    required this.selected,
    required this.onTap,
    required this.onNewTab,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
    required this.onDisconnect,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    final connected = connection == TerminalStatus.connected;
    final hasSession = tabCount > 0;
    return ListTile(
      selected: selected,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ServerAvatar(server: server, connection: connection),
          if (tabCount > 1)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '×$tabCount',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
        ],
      ),
      title: MiddleEllipsisText(server.label),
      subtitle: Text(
        '${server.username}@${server.host}:${server.port}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (server.excludeFromSync) const _ExcludedFromSyncMark(),
          _ReachabilityDot(status: reachability),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'newTab':
                  onNewTab();
                case 'edit':
                  onEdit();
                case 'duplicate':
                  onDuplicate();
                case 'delete':
                  onDelete();
                case 'disconnect':
                  onDisconnect();
                case 'reconnect':
                  onReconnect?.call();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'newTab', child: Text('New tab')),
              if (connected)
                PopupMenuItem(
                  value: 'disconnect',
                  child: Text(tabCount > 1 ? 'Disconnect all' : 'Disconnect'),
                ),
              if (hasSession && !connected && onReconnect != null)
                const PopupMenuItem(
                  value: 'reconnect',
                  child: Text('Reconnect'),
                ),
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              const PopupMenuItem(
                value: 'duplicate',
                child: Text('Duplicate'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

/// The mark on a row whose server never leaves this device.
///
/// Shown whether or not sync is set up: the flag is the user's standing answer
/// for this server, and hiding it until an account exists would make it look
/// like it had been forgotten.
///
/// The description is carried as a [Semantics] *label* and the [Tooltip] is
/// kept out of the semantics tree, which is not the obvious way round. A
/// [ListTile] merges everything under it into one node, and a merge keeps only
/// one tooltip while concatenating every label — so a tooltip here would be
/// dropped in favour of some other one on the row (the row already has
/// several), and a screen reader would be told nothing at all. The tooltip
/// still does its own job for a pointer.
class _ExcludedFromSyncMark extends StatelessWidget {
  const _ExcludedFromSyncMark();

  static const String description = 'Excluded from sync — this device only';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: description,
      child: Tooltip(
        message: description,
        excludeFromSemantics: true,
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Icon(
            Icons.cloud_off_outlined,
            size: 16,
            color: Theme.of(context).hintColor,
          ),
        ),
      ),
    );
  }
}

/// A collapsible section header over one group of servers.
///
/// Only ever built when at least one server carries a group: a list with none
/// renders exactly as it always did, with no headers to look past.
///
/// Public, unlike the tile beside it, so its semantics can be asserted in a
/// widget test — it is the app's only collapsible surface, and what a screen
/// reader makes of a chevron and a bare number is not something to assume.
class ServerGroupHeader extends StatelessWidget {
  final String name;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;

  const ServerGroupHeader({
    super.key,
    required this.name,
    required this.count,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      // The chevron is the only thing that says which way this row goes, and
      // it is pure decoration to a screen reader — so the state is declared.
      // Merged into one node so the row is announced as a single control
      // ("Production, 3 servers, expanded") rather than as a name, a stray
      // number, and a button that appear unrelated. The annotation sits
      // *inside* the merge boundary on purpose: outside it, the fold state
      // lands on a node above the one carrying the label and the tap, and is
      // announced as a property of something the label doesn't name.
      child: MergeSemantics(
        child: Semantics(
          expanded: !collapsed,
          child: InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
              child: Row(
                children: [
                  Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  // A collapsed group still says how much it is hiding, so
                  // folding one away never looks like losing servers. Spelled
                  // out for a screen reader, where a bare "3" between a name
                  // and a button says nothing about what there are three of.
                  Text(
                    '$count',
                    semanticsLabel:
                        '$count ${count == 1 ? 'server' : 'servers'}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A subtle secondary dot: whether the host is reachable on the network (the
/// background probe), independent of whether we have a session open.
class _ReachabilityDot extends StatelessWidget {
  final ProbeStatus status;
  const _ReachabilityDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      ProbeStatus.online => (StatusColors.online(context), 'reachable'),
      ProbeStatus.offline => (StatusColors.offline(context), 'unreachable'),
      ProbeStatus.unknown => (
        StatusColors.unknown(context),
        'reachability unknown',
      ),
    };
    return Tooltip(
      message: 'Host $label',
      child: Icon(Icons.circle_outlined, size: 10, color: color),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, size: 40),
            const SizedBox(height: 12),
            Text(
              'No servers match',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: onClear, child: const Text('Clear filter')),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 48),
            const SizedBox(height: 12),
            Text(
              'No servers yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Add one, or import your ~/.ssh/config.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            // The tooltip-only gear above is invisible on touch; a fresh
            // install (especially on a phone) needs a visible path to the
            // sync-server setup.
            OutlinedButton.icon(
              onPressed: () => openSettings(),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Sync & settings'),
            ),
          ],
        ),
      ),
    );
  }
}
