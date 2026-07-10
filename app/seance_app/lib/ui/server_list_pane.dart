import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import '../theme.dart';
import 'app_menus.dart';
import 'command_generator.dart';
import 'middle_ellipsis_text.dart';
import 'server_editor.dart';

/// Left pane / first screen: the configured servers with a reachability dot.
/// Tapping one opens a terminal (via [onOpen]).
class ServerListPane extends StatelessWidget {
  final void Function(ServerConfig server) onOpen;
  const ServerListPane({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Séance'),
        actions: [
          ListenableBuilder(
            listenable: state,
            builder: (context, _) =>
                _SyncIndicator(state: state, onTap: () => _openSettings(context)),
          ),
          if (state.llmConfigured)
            IconButton(
              tooltip: 'Generate a command (⌘K)',
              icon: const Icon(Icons.auto_fix_high),
              onPressed: () => showCommandGenerator(context, state),
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
          if (state.servers.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            itemCount: state.servers.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final server = state.servers[i];
              final reachability =
                  state.statuses[server.id] ?? ProbeStatus.unknown;
              final tabs = state.sessionsForServer(server.id);
              return _ServerTile(
                // Stable identity so a background sync replacing the list
                // reconciles each tile to its server instead of by position.
                key: ValueKey(server.id),
                server: server,
                connection: _aggregateStatus(tabs),
                tabCount: tabs.length,
                reachability: reachability,
                selected: server.id == state.activeServerId,
                onTap: () => onOpen(server),
                onNewTab: () => state.newTab(server),
                onEdit: () => _editServer(context, state, server),
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
            },
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

  static void _openSettings(BuildContext context) => openSettings();

  Future<void> _editServer(
      BuildContext context, AppState state, ServerConfig? server) async {
    await showServerEditor(context, state, server);
  }

  Future<void> _deleteServer(
      BuildContext context, AppState state, ServerConfig server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${server.label}"?'),
        content: const Text('This removes the server and any stored secret.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
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
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Import')),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) {
      final n = await state.importSshConfig(text);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported $n host(s)')),
        );
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
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (state.lastSyncError != null) {
      return IconButton(
        tooltip: 'Last sync failed — open settings',
        icon: Icon(Icons.cloud_off_outlined,
            color: Theme.of(context).colorScheme.error),
        onPressed: onTap,
      );
    }
    return const SizedBox.shrink();
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

class _ServerTile extends StatelessWidget {
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
  final VoidCallback onDelete;
  final VoidCallback onDisconnect;

  /// Only offered when the server has exactly one (dead) tab; per-tab
  /// reconnect otherwise lives in the pane.
  final VoidCallback? onReconnect;

  const _ServerTile({
    super.key,
    required this.server,
    required this.connection,
    required this.tabCount,
    required this.reachability,
    required this.selected,
    required this.onTap,
    required this.onNewTab,
    required this.onEdit,
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
          _ConnectionDot(status: connection),
          if (tabCount > 1)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('×$tabCount',
                  style: Theme.of(context).textTheme.labelSmall),
            ),
        ],
      ),
      title: MiddleEllipsisText(server.label),
      subtitle: Text('${server.username}@${server.host}:${server.port}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ReachabilityDot(status: reachability),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'newTab':
                  onNewTab();
                case 'edit':
                  onEdit();
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
                    child: Text(tabCount > 1 ? 'Disconnect all' : 'Disconnect')),
              if (hasSession && !connected && onReconnect != null)
                const PopupMenuItem(
                    value: 'reconnect', child: Text('Reconnect')),
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

/// The prominent leading dot: the state of this server's terminal session.
class _ConnectionDot extends StatelessWidget {
  final TerminalStatus status;
  const _ConnectionDot({required this.status});

  @override
  Widget build(BuildContext context) {
    if (status == TerminalStatus.connecting) {
      return const Tooltip(
        message: 'connecting',
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final (color, label) = switch (status) {
      TerminalStatus.connected => (StatusColors.online(context), 'connected'),
      TerminalStatus.error => (StatusColors.offline(context), 'connection error'),
      TerminalStatus.disconnected =>
        (StatusColors.unknown(context), 'disconnected'),
      TerminalStatus.connecting =>
        (StatusColors.unknown(context), 'connecting'),
    };
    return Tooltip(
      message: label,
      child: Icon(Icons.circle, size: 12, color: color),
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
      ProbeStatus.unknown => (StatusColors.unknown(context), 'reachability unknown'),
    };
    return Tooltip(
      message: 'Host $label',
      child: Icon(Icons.circle_outlined, size: 10, color: color),
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
            Text('No servers yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Add one, or import your ~/.ssh/config.',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            // The tooltip-only gear above is invisible on touch; a fresh
            // install (especially on a phone) needs a visible path to the
            // sync-server setup.
            OutlinedButton.icon(
              onPressed: () => ServerListPane._openSettings(context),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Sync & settings'),
            ),
          ],
        ),
      ),
    );
  }
}
