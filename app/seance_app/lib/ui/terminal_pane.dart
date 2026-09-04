import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../main.dart';
import '../services/xterm_engine.dart';
import '../theme.dart';
import 'app_menus.dart';
import 'command_generator.dart';
import 'files_pane.dart';
import 'middle_ellipsis_text.dart';
import 'server_appearance.dart';
import 'session_label.dart';
import 'sidebar_panel.dart';
import 'terminal_appearance.dart';
import 'terminal_keyboard_bar.dart';
import 'top_toast.dart';

/// Touch platforms get the on-screen key row (Tab/Ctrl/arrows) and need the
/// terminal to reflow above the soft keyboard; desktops use a hardware keyboard.
final bool _isTouchPlatform = Platform.isAndroid || Platform.isIOS;

/// Right pane / second screen: the active server's terminal.
///
/// A server can have several sessions, shown as a tab strip at the top of the
/// pane. Tabs are one level *below* the server list: the strip only ever shows
/// the active server's sessions, so adjacent tabs are always the same server.
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
        // The stored config, not the session's connect-time snapshot: recolour
        // a server while you are on it and the strip should follow.
        final server = active == null
            ? null
            : state.configFor(active.serverId) ?? active.config;
        return Scaffold(
          // Reflow the terminal (and the key row) above the soft keyboard.
          resizeToAvoidBottomInset: true,
          endDrawer: showAssistantAffordance
              ? const Drawer(
                  width: 380,
                  child: SidebarPanel(includeFiles: false),
                )
              : null,
          appBar: showAppBar ? _appBar(context, state, server) : null,
          body: Column(
            children: [
              if (active != null)
                TerminalTabStrip(
                  tabs: state.sessionsForServer(active.serverId),
                  activeSessionId: state.activeSessionId,
                  onFocus: state.focusSession,
                  onClose: (id) => _closeTab(context, state, id),
                  onNewTab: () => state.newTab(active.config),
                  onGenerateCommand: () => openCommandGenerator(state),
                  onRename: state.renameSession,
                  // In the wide layout the strip is the only chrome the
                  // terminal has, so it carries the server's colour: the
                  // "am I on prod?" question gets an answer at the edge of
                  // vision instead of one you have to read.
                  accent: serverAccent(context, server?.color)?.line,
                ),
              Expanded(child: _body(state)),
              if (active != null) SessionStatusBar(session: active),
              if (showKeyRow) TerminalKeyboardBar(engine: active.engine),
            ],
          ),
        );
      },
    );
  }

  Future<void> _closeTab(
    BuildContext context,
    AppState state,
    String sessionId,
  ) async {
    final session = state.sessionById(sessionId);
    if (session == null) return;
    final localCopyCount =
        (session.files?.localCopies.length ?? 0) +
        session.retainedLocalCopies.length;
    if (localCopyCount > 0) {
      final close = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Close session and local edits?'),
          content: Text(
            '$localCopyCount downloaded ${localCopyCount == 1 ? 'file has' : 'files have'} '
            'a managed local copy. Closing this tab deletes '
            '${localCopyCount == 1 ? 'it' : 'them'}, including changes that '
            'have not been uploaded.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Close and Delete'),
            ),
          ],
        ),
      );
      if (close != true) return;
    }
    await state.closeTab(sessionId);
  }

  PreferredSizeWidget _appBar(
    BuildContext context,
    AppState state,
    ServerConfig? server,
  ) {
    final active = state.activeSession;
    final status = active?.status;
    return AppBar(
      leading: onBack != null
          ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack)
          : null,
      // The badge repeats the mark from the list row, which is what makes it
      // worth anything: the same colour and glyph you picked the server by is
      // still in front of you once you are on it. `leading` is spoken for by
      // back-navigation on the narrow layout, so it rides with the title.
      title: Row(
        children: [
          if (server != null) ...[
            ServerBadge(color: server.color, icon: server.icon, size: 24),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(
              server?.label ?? active?.config.label ?? 'Terminal',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        if (active != null)
          IconButton(
            tooltip: 'Remote files',
            icon: const Icon(Icons.folder_outlined),
            onPressed:
                active.isConnected || active.retainedLocalCopies.isNotEmpty
                ? () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const FilesScreen(),
                    ),
                  )
                : null,
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

/// The active server's tab strip, including actions to open another session and
/// generate a command for the current one. It remains visible for a single
/// session so those actions are always reachable.
class TerminalTabStrip extends StatelessWidget {
  final List<TerminalSession> tabs;
  final String? activeSessionId;
  final ValueChanged<String> onFocus;
  final ValueChanged<String> onClose;
  final VoidCallback onNewTab;
  final VoidCallback onGenerateCommand;

  /// Called with a tab's id and its new name, or null to clear it back to
  /// automatic naming. Optional so the strip can be built without one.
  final void Function(String sessionId, String? name)? onRename;

  /// The server's accent colour, drawn as the strip's bottom rule. Null keeps
  /// the ordinary hairline — a server with no colour looks exactly as before.
  final Color? accent;

  const TerminalTabStrip({
    super.key,
    required this.tabs,
    required this.activeSessionId,
    required this.onFocus,
    required this.onClose,
    required this.onNewTab,
    required this.onGenerateCommand,
    this.onRename,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(
            color: accent ?? scheme.outlineVariant,
            // Thickened as well as coloured: on a dim accent against a dark
            // theme, a hairline is a hairline whatever colour it is.
            width: accent == null ? 1 : 2,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // One listenable over every tab's name sources, not one per
              // chip: a name change on one tab can add or remove another
              // tab's disambiguating suffix, so labels are computed across
              // the strip. Still scoped to this server's tabs — nothing here
              // repaints the rest of the app.
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  for (final tab in tabs) ...[tab.metadata, tab.customName],
                ]),
                builder: (context, _) {
                  final labels = disambiguateTabLabels([
                    for (var i = 0; i < tabs.length; i++)
                      sessionTabLabel(
                        // 1-based ordinal within the server, used only as the
                        // fallback name when the shell reports nothing.
                        ordinal: i + 1,
                        customName: tabs[i].customName.value,
                        workingDirectory:
                            tabs[i].metadata.value.workingDirectory,
                        terminalTitle: tabs[i].metadata.value.terminalTitle,
                        runningCommand: tabs[i].metadata.value.runningCommand,
                      ),
                  ]);
                  return Row(
                    children: [
                      for (var i = 0; i < tabs.length; i++)
                        _TabChip(
                          ordinal: i + 1,
                          label: labels[i],
                          session: tabs[i],
                          selected: tabs[i].id == activeSessionId,
                          onTap: () => onFocus(tabs[i].id),
                          onClose: () => onClose(tabs[i].id),
                          onRename: onRename == null
                              ? null
                              : () => _rename(context, tabs[i]),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          IconButton(
            tooltip: 'New tab',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 38),
            icon: const Icon(Icons.add),
            onPressed: onNewTab,
          ),
          VerticalDivider(
            width: 1,
            indent: 7,
            endIndent: 7,
            color: scheme.outlineVariant,
          ),
          IconButton(
            tooltip: 'Generate command',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 38),
            icon: const Icon(Icons.auto_fix_high),
            onPressed: onGenerateCommand,
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, TerminalSession session) async {
    final name = await showTabRenameDialog(context, session);
    // `null` is "cancelled"; the dialog reports a clear as an empty string,
    // which renameSession turns back into automatic naming.
    if (name == null) return;
    onRename?.call(session.id, name.isEmpty ? null : name);
  }
}

/// Ask for a tab's name. Returns the new name, `''` to clear it back to
/// automatic naming, or null if the user cancelled.
///
/// A dialog rather than in-place editing in the chip: it is the same
/// interaction on a phone and a desktop, and the chip is 38 px of chrome with
/// a close button in it — not a comfortable text field.
Future<String?> showTabRenameDialog(
  BuildContext context,
  TerminalSession session,
) => showDialog<String>(
  context: context,
  builder: (_) => _RenameTabDialog(currentName: session.customName.value),
);

/// Stateful so the [TextEditingController] lives exactly as long as the
/// dialog's element does. Disposing it when the `showDialog` future completes
/// is too early: `Navigator.pop` completes that future immediately, while the
/// route is still building through its dismissal animation.
class _RenameTabDialog extends StatefulWidget {
  final String? currentName;
  const _RenameTabDialog({required this.currentName});

  @override
  State<_RenameTabDialog> createState() => _RenameTabDialogState();
}

class _RenameTabDialogState extends State<_RenameTabDialog> {
  // `late` matters: the initializer reads `widget`, which the framework only
  // wires up after construction, so this must not be evaluated eagerly.
  late final TextEditingController _controller = TextEditingController(
    text: widget.currentName ?? '',
  )..selection = TextSelection(
    baseOffset: 0,
    extentOffset: (widget.currentName ?? '').length,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename tab'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.pop(context, value),
        decoration: const InputDecoration(
          labelText: 'Tab name',
          hintText: 'logs, deploy, …',
          helperText: 'Leave empty to follow the shell again',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        // Only worth offering when there is a name to remove.
        if (widget.currentName != null)
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Reset'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// One tab in the strip. Its [label] is computed by the strip across all
/// same-server tabs (the disambiguating suffix depends on its siblings), so
/// the chip itself is display-only.
class _TabChip extends StatelessWidget {
  final int ordinal;
  final String label;
  final TerminalSession session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  /// Open the rename prompt, or null when renaming isn't wired up.
  final VoidCallback? onRename;

  const _TabChip({
    required this.ordinal,
    required this.label,
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onClose,
    this.onRename,
  });

  /// Where to anchor a menu opened by long-press, which — unlike a right-click
  /// — carries no position of its own.
  Offset _chipCenter(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Offset.zero;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  Future<void> _showMenu(BuildContext context, Offset globalPosition) async {
    // Positioning needs the overlay's box; give up rather than crash if the
    // chip is being torn down as the menu opens.
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final metadata = session.metadata.value;
    final config = session.config;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: [
        // The tooltip's content, as a menu header: on touch there is no hover
        // to show it any other way, and this is the gesture that used to.
        PopupMenuItem(
          enabled: false,
          // height: 0 is the idiom for "size to the child": the default
          // minimum would leave this multi-line header boxed in a single
          // row's height.
          height: 0,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            sessionTabTooltip(
              ordinal: ordinal,
              target: '${config.username}@${config.host}:${config.port}',
              customName: session.customName.value,
              workingDirectory: metadata.workingDirectory,
              terminalTitle: metadata.terminalTitle,
              runningCommand: metadata.runningCommand,
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'rename', child: Text('Rename tab…')),
        const PopupMenuItem(value: 'close', child: Text('Close tab')),
      ],
    );
    if (choice == 'rename') {
      onRename?.call();
    } else if (choice == 'close') {
      onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final config = session.config;
    final metadata = session.metadata.value;
    // Middle-click closes, matching browser/terminal tab conventions.
    //
    // Rename is reached through a context menu — right-click on a desktop,
    // long-press on touch — rather than through a tab gesture directly.
    // Both alternatives were tried and measured:
    //
    //  * `onLongPress` never fired: [Tooltip] registers its own long-press
    //    recognizer and wins the arena, so the tip appeared and rename did
    //    not.
    //  * `onDoubleTap` worked, but registering it made the InkWell's `onTap`
    //    wait out the double-tap timeout before resolving — a ~300 ms delay
    //    on *every tab switch* to pay for a rare action.
    //
    // A menu also gives the action a name, which no bare gesture does.
    return GestureDetector(
      onTertiaryTapUp: (_) => onClose(),
      onSecondaryTapUp: onRename == null
          ? null
          : (details) => _showMenu(context, details.globalPosition),
      onLongPress: onRename == null
          ? null
          : () => _showMenu(context, _chipCenter(context)),
      child: Tooltip(
          // No gesture trigger, so the long-press above reaches this widget.
          // Hover is unaffected — it is handled separately from the trigger
          // mode — so a desktop still gets the tip by pointing at the tab.
          // Touch keeps the same information: the menu opened by long-press
          // carries it as the header.
          triggerMode: TooltipTriggerMode.manual,
          message: sessionTabTooltip(
            ordinal: ordinal,
            target:
                '${config.username}@${config.host}:${config.port}',
            customName: session.customName.value,
            workingDirectory: metadata.workingDirectory,
            terminalTitle: metadata.terminalTitle,
            runningCommand: metadata.runningCommand,
          ),
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
                  _TabStatusDot(status: session.status),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: 'Close tab',
                    iconSize: 15,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
      ),
    );
  }
}

/// A slim footer naming the machine the keystrokes are going to, plus where on
/// it the shell currently is and how the last command exited.
///
/// In the wide layout the terminal pane has no app bar at all, so before this
/// the only clue to *which host you are typing into* was the highlighted row
/// in the server list.
class SessionStatusBar extends StatelessWidget {
  final TerminalSession session;
  const SessionStatusBar({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final config = session.config;
    final target = '${config.username}@${config.host}:${config.port}';
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFamily: 'monospace',
    );
    return Container(
      // Grow with accessibility text size instead of clipping the host identity.
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          _TabStatusDot(status: session.status),
          const SizedBox(width: 8),
          Flexible(
            child: Tooltip(
              message: target,
              excludeFromSemantics: true,
              child: MiddleEllipsisText(target, style: style),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ValueListenableBuilder<SessionMetadata>(
              valueListenable: session.metadata,
              builder: (context, metadata, _) {
                final cwd = metadata.workingDirectory;
                if (cwd == null) return const SizedBox.shrink();
                return MiddleEllipsisText(sanitizeRemoteLabel(cwd), style: style);
              },
            ),
          ),
          // The exit code comes from the live engine's OSC 133 state, so it is
          // only shown while the engine exists (a closed session disposes it).
          if (session.isConnected)
            ValueListenableBuilder<ShellIntegrationState>(
              valueListenable: session.engine.shellIntegration,
              builder: (context, shell, _) {
                final code = shell.lastExitCode;
                if (code == null || code == 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    'exit $code',
                    style: style?.copyWith(color: scheme.error),
                  ),
                );
              },
            ),
        ],
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
  /// Zoom keys. `equal` covers the unshifted key that carries "+" on most
  /// layouts, and the numpad variants cover the keypad, so ⌘+ works whether or
  /// not the user reaches for Shift. `static final`, not `const`:
  /// LogicalKeyboardKey overrides `==`, which a const set may not contain.
  static final Set<LogicalKeyboardKey> _zoomInKeys = {
    LogicalKeyboardKey.equal,
    LogicalKeyboardKey.add,
    LogicalKeyboardKey.numpadAdd,
  };
  static final Set<LogicalKeyboardKey> _zoomOutKeys = {
    LogicalKeyboardKey.minus,
    LogicalKeyboardKey.numpadSubtract,
  };

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
      const MethodChannel(
        'seance/menu',
      ).invokeMethod('setTerminalFocused', _focus.hasFocus);
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
    final appearance = TerminalAppearance.resolve(
      widget.state.services.settings,
      Theme.of(context).brightness,
    );
    // Click semantics (single/double/triple, shift-click extension, drag
    // anchoring, edge autoscroll) live in the vendored xterm fork — one owner
    // in the gesture arena. The old app-side Listener machine raced xterm's
    // recognizers: its selections were force-cleared ~100ms later.
    return ColoredBox(
      // The padding around the grid is outside xterm's own painted area, so
      // without this the app surface would frame the terminal in a mismatched
      // color at every edge.
      color: appearance.theme.background,
      child: TerminalView(
        tab.engine.terminal,
        controller: _terminalController,
        focusNode: _focus,
        autofocus: widget.isActive,
        onKeyEvent: _handleKeyEvent,
        textStyle: appearance.style,
        theme: appearance.theme,
        keyboardAppearance: appearance.brightness,
        // No default shortcut layer: _handleKeyEvent and the menus already
        // cover copy/paste/select-all, and xterm's defaults hijacked plain
        // Ctrl+A (readline line-home) into a select-all and ate Ctrl+V before
        // the shell ever saw it.
        shortcuts: const <ShortcutActivator, Intent>{},
        onSecondaryTapDown: (details, _) =>
            _showContextMenu(context, details.globalPosition),
        padding: const EdgeInsets.all(6),
      ),
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
    // Zoom (see _zoomInKeys).
    if (clip && _zoomInKeys.contains(event.logicalKey)) {
      widget.state.zoomTerminal(kTerminalFontSizeStep);
      return KeyEventResult.handled;
    }
    if (clip && _zoomOutKeys.contains(event.logicalKey)) {
      widget.state.zoomTerminal(-kTerminalFontSizeStep);
      return KeyEventResult.handled;
    }
    if (clip &&
        (event.logicalKey == LogicalKeyboardKey.digit0 ||
            event.logicalKey == LogicalKeyboardKey.numpad0)) {
      widget.state.zoomTerminal(null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Right-click menu: Copy (when there's a selection), Paste, Select all.
  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
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
          value: 'copy',
          enabled: hasSelection,
          child: const Text('Copy'),
        ),
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
              Text(
                'Connection failed',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(tab.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => state.reconnect(tab.id),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              const SizedBox(height: 12),
              _ConnectionLogView(session: tab),
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
            Text(
              'Disconnected',
              style: Theme.of(context).textTheme.titleMedium,
            ),
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
  final TerminalSession session;
  const _ConnectionLogView({required this.session});

  @override
  Widget build(BuildContext context) {
    // Listens to the session's own log notifier, not to AppState: a handshake
    // appends a line per packet, and routing those through the app-wide
    // notifier rebuilt the entire tree hundreds of times per connection.
    return ListenableBuilder(
      listenable: session.logNotifier,
      builder: (context, _) => _log(context, session.log.toString()),
    );
  }

  Widget _log(BuildContext context, String text) {
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
                      showTopToastIn(context, message: 'Log copied');
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
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.4,
                ),
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
          Text(
            'Select a server to open a session',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}
