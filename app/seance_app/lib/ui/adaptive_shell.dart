import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import 'server_list_pane.dart';
import 'sidebar_panel.dart';
import 'terminal_pane.dart';

/// The adaptive layout. At and above [breakpoint] the server list, terminal, and
/// utility panel sit side by side as tiled, horizontally-resizable panes.
/// Below it they become screens the user moves between, with the utility panel
/// behind an end-drawer.
class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({super.key});

  static const double breakpoint = 960;
  static const double minimumTerminalWidth = 480;
  static const double minimumListWidth = 200;
  static const double maximumListWidth = 480;
  static const double minimumUtilityWidth = 260;
  static const double maximumUtilityWidth = 680;
  static const double resizeHandleWidth = 10;

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  // Narrow mode only: whether we're currently on the terminal screen.
  bool _viewingTerminal = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return AdaptivePaneLayout(
          listPane: ServerListPane(onOpen: (s) => _open(state, s)),
          terminalPane: const TerminalPane(showAppBar: false),
          utilityPane: const SidebarPanel(),
          narrowPane: _buildNarrow(state),
        );
      },
    );
  }

  Widget _buildNarrow(AppState state) {
    final showTerminal = _viewingTerminal && state.activeServerId != null;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: showTerminal
          ? TerminalPane(
              key: const ValueKey('terminal'),
              showAssistantAffordance: true,
              onBack: () => setState(() => _viewingTerminal = false),
            )
          : ServerListPane(
              key: const ValueKey('list'),
              onOpen: (s) => _open(state, s),
            ),
    );
  }

  Future<void> _open(AppState state, ServerConfig server) async {
    if (mounted) setState(() => _viewingTerminal = true);
    await state.openTerminal(server);
  }
}

/// The pane sizes that fit within one wide-layout constraint.
class AdaptivePaneWidths {
  const AdaptivePaneWidths({
    required this.list,
    required this.terminal,
    required this.utility,
  });

  final double list;
  final double terminal;
  final double utility;
}

/// Allocates a wide layout while preserving a useful terminal. Returns `null`
/// when the narrow layout should be used instead.
///
/// When both requested side panes do not fit, their space above their minimums
/// is reduced proportionally. This preserves the user's relative drag choices
/// without letting either side pane crowd out the terminal.
AdaptivePaneWidths? allocateAdaptivePaneWidths({
  required double availableWidth,
  required double requestedListWidth,
  required double requestedUtilityWidth,
}) {
  if (availableWidth < AdaptiveShell.breakpoint) return null;

  final requestedList = requestedListWidth
      .clamp(AdaptiveShell.minimumListWidth, AdaptiveShell.maximumListWidth)
      .toDouble();
  final requestedUtility = requestedUtilityWidth
      .clamp(
        AdaptiveShell.minimumUtilityWidth,
        AdaptiveShell.maximumUtilityWidth,
      )
      .toDouble();
  final sidePaneBudget =
      availableWidth -
      AdaptiveShell.minimumTerminalWidth -
      AdaptiveShell.resizeHandleWidth * 2;
  final availableExtra =
      sidePaneBudget -
      AdaptiveShell.minimumListWidth -
      AdaptiveShell.minimumUtilityWidth;
  final listExtra = requestedList - AdaptiveShell.minimumListWidth;
  final utilityExtra = requestedUtility - AdaptiveShell.minimumUtilityWidth;
  final requestedExtra = listExtra + utilityExtra;

  late final double list;
  late final double utility;
  if (requestedExtra <= availableExtra) {
    list = requestedList;
    utility = requestedUtility;
  } else {
    final scale = availableExtra / requestedExtra;
    list = AdaptiveShell.minimumListWidth + listExtra * scale;
    utility = AdaptiveShell.minimumUtilityWidth + utilityExtra * scale;
  }

  return AdaptivePaneWidths(
    list: list,
    terminal:
        availableWidth - list - utility - AdaptiveShell.resizeHandleWidth * 2,
    utility: utility,
  );
}

/// Constraint-aware tiled panes used by [AdaptiveShell]. Kept independent of
/// app state so allocation and drag behavior can be exercised in widget tests.
class AdaptivePaneLayout extends StatefulWidget {
  const AdaptivePaneLayout({
    super.key,
    required this.listPane,
    required this.terminalPane,
    required this.utilityPane,
    required this.narrowPane,
  });

  final Widget listPane;
  final Widget terminalPane;
  final Widget utilityPane;
  final Widget narrowPane;

  static const listPaneKey = ValueKey('adaptive-list-pane');
  static const terminalPaneKey = ValueKey('adaptive-terminal-pane');
  static const utilityPaneKey = ValueKey('adaptive-utility-pane');
  static const narrowPaneKey = ValueKey('adaptive-narrow-pane');
  static const listResizeHandleKey = ValueKey('adaptive-list-resize-handle');
  static const utilityResizeHandleKey = ValueKey(
    'adaptive-utility-resize-handle',
  );

  @override
  State<AdaptivePaneLayout> createState() => _AdaptivePaneLayoutState();
}

class _AdaptivePaneLayoutState extends State<AdaptivePaneLayout> {
  double _requestedListWidth = 300;
  double _requestedUtilityWidth = 340;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final widths = allocateAdaptivePaneWidths(
          availableWidth: constraints.maxWidth,
          requestedListWidth: _requestedListWidth,
          requestedUtilityWidth: _requestedUtilityWidth,
        );
        if (widths == null) {
          return KeyedSubtree(
            key: AdaptivePaneLayout.narrowPaneKey,
            child: widget.narrowPane,
          );
        }

        return Scaffold(
          body: Row(
            children: [
              SizedBox(
                key: AdaptivePaneLayout.listPaneKey,
                width: widths.list,
                child: widget.listPane,
              ),
              _ResizeHandle(
                key: AdaptivePaneLayout.listResizeHandleKey,
                onStart: () => _startListResize(widths),
                onDelta: _resizeList,
                onEnd: _endResize,
              ),
              Expanded(
                child: SizedBox(
                  key: AdaptivePaneLayout.terminalPaneKey,
                  child: widget.terminalPane,
                ),
              ),
              _ResizeHandle(
                key: AdaptivePaneLayout.utilityResizeHandleKey,
                onStart: () => _startUtilityResize(widths),
                onDelta: _resizeUtility,
                onEnd: _endResize,
              ),
              SizedBox(
                key: AdaptivePaneLayout.utilityPaneKey,
                width: widths.utility,
                child: widget.utilityPane,
              ),
            ],
          ),
        );
      },
    );
  }

  double? _listDragStart;
  double _listDragDelta = 0;
  double _listDragMaximum = AdaptiveShell.maximumListWidth;

  double? _utilityDragStart;
  double _utilityDragDelta = 0;
  double _utilityDragMaximum = AdaptiveShell.maximumUtilityWidth;

  void _startListResize(AdaptivePaneWidths widths) {
    _listDragStart = widths.list;
    _listDragDelta = 0;
    _listDragMaximum =
        (widths.list + widths.terminal - AdaptiveShell.minimumTerminalWidth)
            .clamp(
              AdaptiveShell.minimumListWidth,
              AdaptiveShell.maximumListWidth,
            )
            .toDouble();
    setState(() {
      _requestedListWidth = widths.list;
      _requestedUtilityWidth = widths.utility;
    });
  }

  void _resizeList(double dx) {
    final dragStart = _listDragStart;
    if (dragStart == null) return;
    _listDragDelta += dx;
    setState(() {
      _requestedListWidth = (dragStart + _listDragDelta)
          .clamp(AdaptiveShell.minimumListWidth, _listDragMaximum)
          .toDouble();
    });
  }

  void _startUtilityResize(AdaptivePaneWidths widths) {
    _utilityDragStart = widths.utility;
    _utilityDragDelta = 0;
    _utilityDragMaximum =
        (widths.utility + widths.terminal - AdaptiveShell.minimumTerminalWidth)
            .clamp(
              AdaptiveShell.minimumUtilityWidth,
              AdaptiveShell.maximumUtilityWidth,
            )
            .toDouble();
    setState(() {
      _requestedListWidth = widths.list;
      _requestedUtilityWidth = widths.utility;
    });
  }

  void _resizeUtility(double dx) {
    final dragStart = _utilityDragStart;
    if (dragStart == null) return;
    _utilityDragDelta -= dx;
    setState(() {
      _requestedUtilityWidth = (dragStart + _utilityDragDelta)
          .clamp(AdaptiveShell.minimumUtilityWidth, _utilityDragMaximum)
          .toDouble();
    });
  }

  void _endResize() {
    _listDragStart = null;
    _utilityDragStart = null;
  }
}

/// A thin, draggable vertical divider that reports horizontal drag deltas so a
/// neighbouring pane can be resized. Shows a resize cursor on desktop.
class _ResizeHandle extends StatelessWidget {
  final VoidCallback onStart;
  final ValueChanged<double> onDelta;
  final VoidCallback onEnd;
  const _ResizeHandle({
    super.key,
    required this.onStart,
    required this.onDelta,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => onStart(),
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        onHorizontalDragEnd: (_) => onEnd(),
        onHorizontalDragCancel: onEnd,
        child: SizedBox(
          width: AdaptiveShell.resizeHandleWidth,
          child: Center(
            child: Container(width: 1, color: Theme.of(context).dividerColor),
          ),
        ),
      ),
    );
  }
}
