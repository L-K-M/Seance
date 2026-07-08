import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../main.dart';
import 'command_generator.dart';
import 'sidebar_panel.dart';
import 'terminal_keyboard_bar.dart';

/// Touch platforms get the on-screen key row (Tab/Ctrl/arrows) and need the
/// terminal to reflow above the soft keyboard; desktops use a hardware keyboard.
final bool _isTouchPlatform = Platform.isAndroid || Platform.isIOS;

/// Right pane / second screen: the active server's terminal. The server list is
/// the tab list, so there is no tab strip here.
///
/// Every open session stays mounted in an [IndexedStack] so switching servers
/// is instant — the previously-rendered terminal is shown immediately instead
/// of being rebuilt (which flashed a blank pane for a few seconds).
///
/// In the wide layout the server name and disconnect controls live in the
/// sidebar, so the app bar is dropped ([showAppBar] false). The narrow layout
/// keeps a slim bar for back-navigation and the assistant drawer.
class TerminalPane extends StatelessWidget {
  final VoidCallback? onBack;
  final bool showAssistantAffordance;
  final bool showAppBar;

  const TerminalPane({
    super.key,
    this.onBack,
    this.showAssistantAffordance = false,
    this.showAppBar = true,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final active = state.activeSession;
        final showKeyRow =
            _isTouchPlatform && active != null && active.isConnected;
        return Scaffold(
          // Reflow the terminal (and the key row) above the soft keyboard.
          resizeToAvoidBottomInset: true,
          endDrawer: showAssistantAffordance
              ? const Drawer(width: 380, child: SidebarPanel())
              : null,
          appBar: showAppBar ? _appBar(context, state) : null,
          body: Column(
            children: [
              Expanded(child: _body(state)),
              if (showKeyRow) TerminalKeyboardBar(engine: active.engine),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _appBar(BuildContext context, AppState state) {
    final active = state.activeSession;
    final status = active?.status;
    return AppBar(
      leading: onBack != null
          ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack)
          : null,
      title: Text(active?.config.label ?? 'Terminal'),
      actions: [
        if (state.llmConfigured && status == TerminalStatus.connected)
          IconButton(
            tooltip: 'Generate command',
            icon: const Icon(Icons.auto_fix_high),
            onPressed: () => showCommandGenerator(context, state),
          ),
        if (status == TerminalStatus.connected)
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
            onPressed: () => state.disconnect(active!.serverId),
          ),
        if (status == TerminalStatus.error ||
            status == TerminalStatus.disconnected)
          IconButton(
            tooltip: 'Reconnect',
            icon: const Icon(Icons.refresh),
            onPressed: () => state.reconnect(active!.serverId),
          ),
        if (showAssistantAffordance)
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Assistant & snippets',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: () => Scaffold.of(context).openEndDrawer(),
            ),
          ),
      ],
    );
  }

  Widget _body(AppState state) {
    final entries = state.sessions.values.toList();
    if (entries.isEmpty) return const _NoSession();
    final index =
        entries.indexWhere((t) => t.serverId == state.activeServerId);
    if (index < 0) return const _NoSession();
    return IndexedStack(
      index: index,
      sizing: StackFit.expand,
      children: [
        for (var i = 0; i < entries.length; i++)
          _SessionView(
            key: ValueKey(entries[i].serverId),
            tab: entries[i],
            state: state,
            isActive: i == index,
          ),
      ],
    );
  }
}

/// One session's content: the live terminal, or a connecting / error /
/// disconnected placeholder. Kept alive across switches by the [IndexedStack].
class _SessionView extends StatefulWidget {
  final TerminalSession tab;
  final AppState state;
  final bool isActive;
  const _SessionView({
    super.key,
    required this.tab,
    required this.state,
    required this.isActive,
  });

  @override
  State<_SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends State<_SessionView> {
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(_SessionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Focus the terminal when this session becomes the active one.
    if (widget.isActive && !oldWidget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    if (tab.connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tab.error != null) {
      return _ConnectionError(tab: tab, state: widget.state);
    }
    if (!tab.isConnected) {
      return _Disconnected(tab: tab, state: widget.state);
    }
    return TerminalView(
      tab.engine.terminal,
      focusNode: _focus,
      autofocus: widget.isActive,
      onKeyEvent: _handleKeyEvent,
      padding: const EdgeInsets.all(6),
    );
  }

  /// Intercept the command-generator shortcut before the terminal consumes the
  /// keystroke. Uses Cmd+K (macOS) or Ctrl+Shift+K elsewhere — plain Ctrl+K is
  /// left alone because that's readline's "kill to end of line".
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    final isGenerator = event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyK &&
        (keys.isMetaPressed ||
            (keys.isControlPressed && keys.isShiftPressed));
    if (isGenerator && widget.state.llmConfigured) {
      showCommandGenerator(context, widget.state);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
