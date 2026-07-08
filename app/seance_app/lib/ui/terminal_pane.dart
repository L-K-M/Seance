import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../main.dart';
import 'chat_sidebar.dart';

/// Right pane / second screen: the active server's terminal. The server list is
/// the tab list, so there is no tab strip here.
///
/// When the assistant is not shown as a tiled sidebar (narrow or medium
/// widths), [showAssistantAffordance] puts it behind an end-drawer button.
class TerminalPane extends StatelessWidget {
  final VoidCallback? onBack;
  final bool showAssistantAffordance;

  const TerminalPane({
    super.key,
    this.onBack,
    this.showAssistantAffordance = false,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final active = state.activeSession;
        return Scaffold(
          endDrawer: showAssistantAffordance
              ? const Drawer(width: 380, child: ChatSidebar())
              : null,
          appBar: AppBar(
            leading: onBack != null
                ? IconButton(
                    icon: const Icon(Icons.arrow_back), onPressed: onBack)
                : null,
            title: Text(active?.config.label ?? 'Terminal'),
            actions: [
              if (active != null &&
                  (active.status == TerminalStatus.connected ||
                      active.status == TerminalStatus.error ||
                      active.status == TerminalStatus.disconnected))
                IconButton(
                  tooltip: active.status == TerminalStatus.connected
                      ? 'Disconnect'
                      : 'Reconnect',
                  icon: Icon(active.status == TerminalStatus.connected
                      ? Icons.link_off
                      : Icons.refresh),
                  onPressed: active.status == TerminalStatus.connected
                      ? () => state.disconnect(active.serverId)
                      : () => state.reconnect(active.serverId),
                ),
              if (showAssistantAffordance)
                Builder(
                  builder: (context) => IconButton(
                    tooltip: 'Assistant',
                    icon: const Icon(Icons.auto_awesome_outlined),
                    onPressed: () => Scaffold.of(context).openEndDrawer(),
                  ),
                ),
            ],
          ),
          body: active == null
              ? const _NoSession()
              : _TerminalBody(tab: active, state: state),
        );
      },
    );
  }
}

class _TerminalBody extends StatelessWidget {
  final TerminalSession tab;
  final AppState state;
  const _TerminalBody({required this.tab, required this.state});

  @override
  Widget build(BuildContext context) {
    if (tab.connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tab.error != null) {
      return _ConnectionError(tab: tab, state: state);
    }
    if (!tab.isConnected) {
      // Session dropped (remote exit / network). Offer a reconnect.
      return _Disconnected(tab: tab, state: state);
    }
    return TerminalView(
      tab.engine.terminal,
      autofocus: true,
      padding: const EdgeInsets.all(6),
    );
  }
}

/// Shown when a connection attempt failed. Surfaces the one-line summary and an
/// expandable connection log so the user can see exactly what happened.
class _ConnectionError extends StatelessWidget {
  final TerminalSession tab;
  final AppState state;
  const _ConnectionError({required this.tab, required this.state});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off, size: 40),
              const SizedBox(height: 12),
              Text('Connection failed',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(tab.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => state.reconnect(tab.serverId),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              const SizedBox(height: 12),
              _ConnectionLogView(log: tab.log),
            ],
          ),
        ),
      ),
    );
  }
}

class _Disconnected extends StatelessWidget {
  final TerminalSession tab;
  final AppState state;
  const _Disconnected({required this.tab, required this.state});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.power_off_outlined, size: 40),
            const SizedBox(height: 12),
            Text('Disconnected',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('The session ended.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => state.reconnect(tab.serverId),
              icon: const Icon(Icons.refresh),
              label: const Text('Reconnect'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A collapsible view of the raw connection transcript, with a copy button.
class _ConnectionLogView extends StatelessWidget {
  final SshConnectionLog log;
  const _ConnectionLogView({required this.log});

  @override
  Widget build(BuildContext context) {
    final text = log.toString();
    final scheme = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Connection log'),
        childrenPadding: EdgeInsets.zero,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: text.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Log copied')),
                      );
                    },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
            ),
          ),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text.isEmpty ? '(no log captured)' : text,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoSession extends StatelessWidget {
  const _NoSession();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.terminal, size: 48),
          const SizedBox(height: 12),
          Text('Select a server to open a session',
              style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
