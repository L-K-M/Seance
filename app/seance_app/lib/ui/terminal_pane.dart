import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../main.dart';
import '../theme.dart';
import 'app_menus.dart';
import 'command_generator.dart';
import 'sidebar_panel.dart';
import 'terminal_keyboard_bar.dart';

/// Touch platforms get the on-screen key row (Tab/Ctrl/arrows) and need the
/// terminal to reflow above the soft keyboard; desktops use a hardware keyboard.
final bool _isTouchPlatform = Platform.isAndroid || Platform.isIOS;

/// Right pane / second screen: the active server's terminal.
///
/// A server can have several sessions, shown as a tab strip at the top of the
/// pane (only when that server has more than one — a single-tab server looks
/// exactly as before). Tabs are one level *below* the server list: the strip
/// only ever shows the active server's sessions, so adjacent tabs are always
/// the same server.
///
/// Every open session stays mounted in an [IndexedStack] so switching tabs (or
/// servers) is instant — the previously-rendered terminal is shown immediately
/// instead of being rebuilt (which flashed a blank pane for a few seconds).
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
        final serverTabs = active == null
            ? const <TerminalSession>[]
            : state.sessionsForServer(active.serverId);
        return Scaffold(
          // Reflow the terminal (and the key row) above the soft keyboard.
          resizeToAvoidBottomInset: true,
          endDrawer: showAssistantAffordance
              ? const Drawer(width: 380, child: SidebarPanel())
              : null,
          appBar: showAppBar ? _appBar(context, state) : null,
          body: Column(
            children: [
              // The strip appears only once a server has 2+ tabs, so the
              // single-session case is visually unchanged.
              if (active != null && serverTabs.length > 1)
                _TabStrip(state: state, active: active),
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
        if (active != null)
          IconButton(
            tooltip: 'New tab',
            icon: const Icon(Icons.add),
            onPressed: () => state.newTab(active.config),
          ),
        if (status == TerminalStatus.connected)
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
            onPressed: () => state.disconnect(active!.id),
          ),
        if (status == TerminalStatus.error ||
            status == TerminalStatus.disconnected)
          IconButton(
            tooltip: 'Reconnect',
            icon: const Icon(Icons.refresh),
            onPressed: () => state.reconnect(active!.id),
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
    final entries = state.sessions;
    if (entries.isEmpty) return const _NoSession();
    final index = entries.indexWhere((t) => t.id == state.activeSessionId);
    if (index < 0) return const _NoSession();
    return IndexedStack(
      index: index,
      sizing: StackFit.expand,
      children: [
        for (var i = 0; i < entries.length; i++)
          _SessionView(
            // Keyed by session id (not server id): a reconnect swaps in a new
            // session with a new id, so a fresh _SessionView mounts and binds
            // its controller in initState — no didUpdateWidget rebind needed.
            key: ValueKey(entries[i].id),
            tab: entries[i],
            state: state,
            isActive: i == index,
          ),
      ],
    );
  }
}

/// The per-server tab strip, shown above the terminal when a server has more
/// than one open session. Renders only the active server's sessions, so
/// adjacent tabs are always the same server.
class _TabStrip extends StatelessWidget {
  final AppState state;
  final TerminalSession active;
  const _TabStrip({required this.state, required this.active});

  @override
  Widget build(BuildContext context) {
    final tabs = state.sessionsForServer(active.serverId);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    _TabChip(
                      // 1-based ordinal within the server; no OSC title yet.
                      label: 'Session ${i + 1}',
                      status: tabs[i].status,
                      selected: tabs[i].id == state.activeSessionId,
                      onTap: () => state.focusSession(tabs[i].id),
                      onClose: () => state.closeTab(tabs[i].id),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'New tab',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add),
            onPressed: () => state.newTab(active.config),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final TerminalStatus status;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _TabChip({
    required this.label,
    required this.status,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Middle-click closes, matching browser/terminal tab conventions.
    return GestureDetector(
      onTertiaryTapUp: (_) => onClose(),
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 38,
          padding: const EdgeInsets.only(left: 12, right: 4),
          decoration: BoxDecoration(
            color: selected ? scheme.surface : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TabStatusDot(status: status),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  )),
              const SizedBox(width: 2),
              IconButton(
                tooltip: 'Close tab',
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The small status dot on a tab chip (mirrors the server-list dot semantics
/// at a smaller size).
class _TabStatusDot extends StatelessWidget {
  final TerminalStatus status;
  const _TabStatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    if (status == TerminalStatus.connecting) {
      return const SizedBox(
        width: 9,
        height: 9,
        child: CircularProgressIndicator(strokeWidth: 1.6),
      );
    }
    final color = switch (status) {
      TerminalStatus.connected => StatusColors.online(context),
      TerminalStatus.error => StatusColors.offline(context),
      _ => StatusColors.unknown(context),
    };
    return Icon(Icons.circle, size: 9, color: color);
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
  // Our own controller so the copy/paste menu can read (and set) the selection.
  final TerminalController _terminalController = TerminalController();
  @override
  void initState() {
    super.initState();
    // Expose the controller on the session so the native macOS Edit menu can
    // copy from the active terminal, and report focus so it only routes ⌘C/⌘V
    // to the terminal when a terminal (not a text field) is focused.
    widget.tab.controller = _terminalController;
    _focus.addListener(_reportTerminalFocus);
  }

  @override
  void didUpdateWidget(_SessionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sessions are keyed by their (immutable) id, so widget.tab is stable for
    // the life of this State — a reconnect mounts a fresh _SessionView with a
    // new id instead of swapping the tab under this one, so no controller
    // rebind is needed (the old server-id keying required one).
    //
    // Focus the terminal when this session becomes the active one.
    if (widget.isActive && !oldWidget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_reportTerminalFocus);
    if (identical(widget.tab.controller, _terminalController)) {
      widget.tab.controller = null;
    }
    _focus.dispose();
    _terminalController.dispose();
    super.dispose();
  }

  /// Tell the macOS shell whether a terminal is focused, so the native Edit
  /// menu routes ⌘C/⌘V/⌘A to the terminal rather than a focused text field.
  void _reportTerminalFocus() {
    if (Platform.isMacOS) {
      const MethodChannel('seance/menu')
          .invokeMethod('setTerminalFocused', _focus.hasFocus);
    }
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
    // Click semantics (single/double/triple, shift-click extension, drag
    // anchoring, edge autoscroll) live in the vendored xterm fork — one owner
    // in the gesture arena. The old app-side Listener machine raced xterm's
    // recognizers: its selections were force-cleared ~100ms later.
    return TerminalView(
      tab.engine.terminal,
      controller: _terminalController,
      focusNode: _focus,
      autofocus: widget.isActive,
      onKeyEvent: _handleKeyEvent,
      // No default shortcut layer: _handleKeyEvent and the menus already
      // cover copy/paste/select-all, and xterm's defaults hijacked plain
      // Ctrl+A (readline line-home) into a select-all and ate Ctrl+V before
      // the shell ever saw it.
      shortcuts: const <ShortcutActivator, Intent>{},
      onSecondaryTapDown: (details, _) =>
          _showContextMenu(context, details.globalPosition),
      padding: const EdgeInsets.all(6),
    );
  }

  /// Intercept a few shortcuts before the terminal consumes the keystroke: the
  /// command generator, and copy/paste. Copy/paste use ⌘C/⌘V on macOS and
  /// Ctrl+Shift+C/V elsewhere (leaving Ctrl+C as the shell interrupt). Plain
  /// Ctrl+K is left alone because that's readline's "kill to end of line".
  ///
  /// Note: on macOS the native Edit menu claims ⌘C/⌘V/⌘A at the OS level, so
  /// those never reach here — the right-click menu is the reliable path there.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;

    if (event.logicalKey == LogicalKeyboardKey.keyK &&
        (keys.isMetaPressed ||
            (keys.isControlPressed && keys.isShiftPressed)) &&
        widget.state.llmConfigured) {
      showCommandGenerator(context, widget.state);
      return KeyEventResult.handled;
    }

    // Apple platforms use ⌘ (on iPad this is the only hardware-keyboard
    // path — there is no native menu to fall back to); elsewhere
    // Ctrl+Shift leaves plain Ctrl+C/A for the shell.
    final apple = Platform.isMacOS || Platform.isIOS;
    final clip = apple
        ? keys.isMetaPressed
        : (keys.isControlPressed && keys.isShiftPressed);
    // Open another tab for this server: ⌘T / Ctrl+Shift+T.
    if (clip && event.logicalKey == LogicalKeyboardKey.keyT) {
      widget.state.newTab(widget.tab.config);
      return KeyEventResult.handled;
    }
    if (clip && event.logicalKey == LogicalKeyboardKey.keyC) {
      return terminalCopy(widget.tab)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (clip && event.logicalKey == LogicalKeyboardKey.keyV) {
      terminalPaste(widget.tab);
      return KeyEventResult.handled;
    }
    if (clip && event.logicalKey == LogicalKeyboardKey.keyA) {
      terminalSelectAll(widget.tab);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Right-click menu: Copy (when there's a selection), Paste, Select all.
  Future<void> _showContextMenu(
      BuildContext context, Offset globalPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final hasSelection = _terminalController.selection != null;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: [
        PopupMenuItem(
            value: 'copy', enabled: hasSelection, child: const Text('Copy')),
        const PopupMenuItem(value: 'paste', child: Text('Paste')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'selectAll', child: Text('Select all')),
      ],
    );
    switch (choice) {
      case 'copy':
        terminalCopy(widget.tab);
      case 'paste':
        await terminalPaste(widget.tab);
      case 'selectAll':
        terminalSelectAll(widget.tab);
    }
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
                onPressed: () => state.reconnect(tab.id),
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
              onPressed: () => state.reconnect(tab.id),
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
