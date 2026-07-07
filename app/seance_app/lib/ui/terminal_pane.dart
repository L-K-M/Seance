import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../main.dart';
import 'chat_sidebar.dart';

/// Right pane / second screen: the open terminal sessions as tabs, plus the
/// always-available assistant in an end drawer.
class TerminalPane extends StatelessWidget {
  final VoidCallback? onBack;
  const TerminalPane({super.key, this.onBack});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final active = state.activeTab;
        return Scaffold(
          endDrawer: const Drawer(width: 380, child: ChatSidebar()),
          appBar: AppBar(
            leading: onBack != null
                ? IconButton(
                    icon: const Icon(Icons.arrow_back), onPressed: onBack)
                : null,
            title: Text(active?.config.label ?? 'Terminal'),
            actions: [
              Builder(
                builder: (context) => IconButton(
                  tooltip: 'Assistant',
                  icon: const Icon(Icons.auto_awesome_outlined),
                  onPressed: active == null
                      ? null
                      : () => Scaffold.of(context).openEndDrawer(),
                ),
              ),
            ],
            bottom: state.tabs.isEmpty
                ? null
                : _TabStrip(state: state, preferredSize: const Size.fromHeight(40)),
          ),
          body: active == null
              ? const _NoSession()
              : _TerminalBody(tab: active),
        );
      },
    );
  }
}

class _TabStrip extends StatelessWidget implements PreferredSizeWidget {
  final AppState state;
  @override
  final Size preferredSize;
  const _TabStrip({required this.state, required this.preferredSize});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: preferredSize.height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final tab in state.tabs)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: InputChip(
                selected: tab.id == state.activeTabId,
                label: Text(tab.config.label),
                avatar: Icon(
                  tab.isConnected
                      ? Icons.circle
                      : (tab.connecting
                          ? Icons.more_horiz
                          : Icons.error_outline),
                  size: 12,
                ),
                onPressed: () => state.focusTab(tab.id),
                onDeleted: () => state.closeTab(tab.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _TerminalBody extends StatelessWidget {
  final TerminalTab tab;
  const _TerminalBody({required this.tab});

  @override
  Widget build(BuildContext context) {
    if (tab.connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tab.error != null) {
      return Center(
        child: Padding(
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
            ],
          ),
        ),
      );
    }
    return TerminalView(
      tab.engine.terminal,
      autofocus: true,
      padding: const EdgeInsets.all(6),
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
