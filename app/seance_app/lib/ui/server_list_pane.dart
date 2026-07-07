import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import '../theme.dart';
import 'server_editor.dart';
import 'settings_screen.dart';

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
          IconButton(
            tooltip: 'Import ~/.ssh/config',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _importConfig(context, state),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
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
              final status = state.statuses[server.id] ?? ProbeStatus.unknown;
              return _ServerTile(
                server: server,
                status: status,
                onTap: () => onOpen(server),
                onEdit: () => _editServer(context, state, server),
                onDelete: () => _deleteServer(context, state, server),
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

class _ServerTile extends StatelessWidget {
  final ServerConfig server;
  final ProbeStatus status;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ServerTile({
    required this.server,
    required this.status,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _StatusDot(status: status),
      title: Text(server.label),
      subtitle: Text('${server.username}@${server.host}:${server.port}'),
      onTap: onTap,
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final ProbeStatus status;
  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      ProbeStatus.online => (StatusColors.online(context), 'online'),
      ProbeStatus.offline => (StatusColors.offline(context), 'offline'),
      ProbeStatus.unknown => (StatusColors.unknown(context), 'unknown'),
    };
    return Tooltip(
      message: label,
      child: Icon(Icons.circle, size: 12, color: color),
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
            const Text('Add one, or import your ~/.ssh/config.'),
          ],
        ),
      ),
    );
  }
}
