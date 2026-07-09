import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../main.dart';
import 'app_menus.dart';
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
  // Our own controller so the copy/paste menu can read (and set) the selection.
  final TerminalController _terminalController = TerminalController();
  // Reaches the render object to convert a click into a word/line selection.
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();

  // Desktop multi-click selection: xterm's own double-tap word-select is
  // preempted by its mouse drag recognizer, and it has no triple-tap, so we
  // detect double/triple clicks ourselves (see [_onPointerDown]).
  int _tapCount = 0;
  Offset? _lastTapDown;
  Timer? _multiTapTimer;

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
    // A reconnect swaps in a brand-new TerminalSession under the same server id,
    // so this State is reused (same ValueKey) and initState does NOT re-run.
    // Re-bind the selection controller to the new tab, or the macOS Edit menu /
    // Copy / Select All would silently no-op for the rest of the session.
    if (!identical(widget.tab, oldWidget.tab)) {
      if (identical(oldWidget.tab.controller, _terminalController)) {
        oldWidget.tab.controller = null;
      }
      widget.tab.controller = _terminalController;
    }
    // Focus the terminal when this session becomes the active one.
    if (widget.isActive && !oldWidget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _multiTapTimer?.cancel();
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
    // Listener observes pointer-downs without joining the gesture arena, so it
    // can add double/triple-click selection on top of xterm's own gestures.
    return Listener(
      onPointerDown: _onPointerDown,
      child: TerminalView(
        tab.engine.terminal,
        key: _terminalViewKey,
        controller: _terminalController,
        focusNode: _focus,
        autofocus: widget.isActive,
        onKeyEvent: _handleKeyEvent,
        onSecondaryTapDown: (details, _) =>
            _showContextMenu(context, details.globalPosition),
        padding: const EdgeInsets.all(6),
      ),
    );
  }

  /// Detect double/triple mouse clicks and select the word / line under the
  /// cursor. Touch keeps xterm's built-in double-tap-to-select-word.
  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse &&
        event.kind != PointerDeviceKind.trackpad) {
      return;
    }
    if (event.buttons != kPrimaryButton) {
      _tapCount = 0;
      return;
    }
    final continues = _lastTapDown != null &&
        (_multiTapTimer?.isActive ?? false) &&
        (event.position - _lastTapDown!).distance <= 8;
    _tapCount = continues ? _tapCount + 1 : 1;
    _lastTapDown = event.position;
    _multiTapTimer?.cancel();
    _multiTapTimer =
        Timer(const Duration(milliseconds: 400), () => _tapCount = 0);

    if (_tapCount == 2) {
      _selectWordAt(event.position);
    } else if (_tapCount >= 3) {
      _selectLineAt(event.position);
      _tapCount = 0;
    }
  }

  void _selectWordAt(Offset globalPosition) {
    final state = _terminalViewKey.currentState;
    if (state == null) return;
    try {
      final render = state.renderTerminal;
      render.selectWord(render.globalToLocal(globalPosition));
    } catch (_) {
      // Render object not laid out yet — ignore.
    }
  }

  void _selectLineAt(Offset globalPosition) {
    final state = _terminalViewKey.currentState;
    if (state == null) return;
    try {
      final render = state.renderTerminal;
      final cell = render.getCellOffset(render.globalToLocal(globalPosition));
      final terminal = widget.tab.engine.terminal;
      final buffer = terminal.buffer;
      _terminalController.setSelection(
        buffer.createAnchor(0, cell.y),
        buffer.createAnchor(terminal.viewWidth, cell.y),
      );
    } catch (_) {
      // Render object not laid out yet — ignore.
    }
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

    final clip = Platform.isMacOS
        ? keys.isMetaPressed
        : (keys.isControlPressed && keys.isShiftPressed);
    if (clip && event.logicalKey == LogicalKeyboardKey.keyC) {
      return terminalCopy(widget.tab)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (clip && event.logicalKey == LogicalKeyboardKey.keyV) {
      terminalPaste(widget.tab);
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
