import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  static const double minimumTerminalWidth = 480;
  static const double minimumListWidth = 200;
  static const double defaultListWidth = 300;
  static const double maximumListWidth = 480;
  static const double minimumUtilityWidth = 260;
  static const double defaultUtilityWidth = 340;
  static const double maximumUtilityWidth = 680;
  static const double resizeHandleWidth = 10;
  static const double breakpoint =
      minimumListWidth +
      minimumTerminalWidth +
      minimumUtilityWidth +
      resizeHandleWidth * 2;

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  // Narrow mode only: whether we're currently on the terminal screen.
  bool _viewingTerminal = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final settings = state.services.settings;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return AdaptivePaneLayout(
          initialListWidth:
              settings.paneListWidth ?? AdaptiveShell.defaultListWidth,
          initialUtilityWidth:
              settings.paneUtilityWidth ?? AdaptiveShell.defaultUtilityWidth,
          onPaneWidthsChanged: (listWidth, utilityWidth) => unawaited(
            state.setPaneWidths(
              listWidth: listWidth,
              utilityWidth: utilityWidth,
            ),
          ),
          listPane: ServerListPane(
            posture: ServerListPosture.rail,
            onOpen: (s) => _open(state, s),
          ),
          terminalPane: const TerminalPane(showAppBar: false),
          // The utility panel (Assistant + Snippets) is always available;
          // Snippets works without an LLM configured.
          utilityPane: const SidebarPanel(),
          narrowPane: _buildNarrow(state),
        );
      },
    );
  }

  Widget _buildNarrow(AppState state) {
    final showTerminal = _viewingTerminal && state.activeServerId != null;
    // The terminal is a state flag here, not a pushed route, so an unhandled
    // system back would reach the root route and go to the platform. On
    // Android that finishes the activity, and the engine and every live SSH
    // session die with it. While the terminal shows, back does what the app
    // bar's arrow does; on the list it stays the platform's.
    return PopScope(
      canPop: !showTerminal,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _backFromTerminal();
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: showTerminal
            ? TerminalPane(
                key: const ValueKey('terminal'),
                showAssistantAffordance: true,
                onBack: () => setState(() => _viewingTerminal = false),
              )
            : ServerListPane(
                key: const ValueKey('list'),
                posture: ServerListPosture.home,
                onOpen: (s) => _open(state, s),
              ),
      ),
    );
  }

  void _backFromTerminal() {
    // A blocking PopScope outranks the route's local history, so an open
    // drawer would otherwise be skipped. Let the route close it first: the
    // imperative pop removes the history entry and leaves the route in place.
    if (ModalRoute.of(context)?.willHandlePopInternally ?? false) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _viewingTerminal = false);
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

  late final double rawList;
  late final double rawUtility;
  if (requestedExtra <= availableExtra) {
    rawList = requestedList;
    rawUtility = requestedUtility;
  } else {
    final scale = availableExtra / requestedExtra;
    rawList = AdaptiveShell.minimumListWidth + listExtra * scale;
    rawUtility = AdaptiveShell.minimumUtilityWidth + utilityExtra * scale;
  }
  final list = rawList
      .clamp(AdaptiveShell.minimumListWidth, AdaptiveShell.maximumListWidth)
      .toDouble();
  final utility = rawUtility
      .clamp(
        AdaptiveShell.minimumUtilityWidth,
        AdaptiveShell.maximumUtilityWidth,
      )
      .toDouble();

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
    this.initialListWidth = AdaptiveShell.defaultListWidth,
    this.initialUtilityWidth = AdaptiveShell.defaultUtilityWidth,
    this.onPaneWidthsChanged,
  });

  final Widget listPane;
  final Widget terminalPane;
  final Widget utilityPane;
  final Widget narrowPane;

  /// Requested pane widths to start from (the persisted values, on real
  /// launches). The widget owns them once mounted; later changes to these
  /// fields do not reset a live layout.
  final double initialListWidth;
  final double initialUtilityWidth;

  /// Fired when a resize drag ends, with the user's *requested* widths — the
  /// values worth persisting (rendered widths are just these, clamped to the
  /// current window).
  final void Function(double listWidth, double utilityWidth)?
  onPaneWidthsChanged;

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
  late double _requestedListWidth = widget.initialListWidth;
  late double _requestedUtilityWidth = widget.initialUtilityWidth;
  double? _temporaryListWidth;
  double? _temporaryUtilityWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        AdaptivePaneWidths? currentWidths() => allocateAdaptivePaneWidths(
          availableWidth: constraints.maxWidth,
          requestedListWidth: _temporaryListWidth ?? _requestedListWidth,
          requestedUtilityWidth:
              _temporaryUtilityWidth ?? _requestedUtilityWidth,
        );
        final widths = currentWidths();
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
                label: 'Resize server list',
                width: widths.list,
                minimumWidth: AdaptiveShell.minimumListWidth,
                maximumWidth: _maximumListWidth(widths),
                edge: _PaneEdge.leading,
                widthAfterStep: (delta) => _widthAfterStep(
                  _PaneEdge.leading,
                  currentWidths()!,
                  constraints.maxWidth,
                  delta,
                ),
                onStep: (delta) =>
                    _stepPane(_PaneEdge.leading, currentWidths()!, delta),
                onStart: () => _startListResize(currentWidths()!),
                onDelta: _resizeList,
                onEnd: _endListResize,
              ),
              Expanded(
                child: SizedBox(
                  key: AdaptivePaneLayout.terminalPaneKey,
                  child: widget.terminalPane,
                ),
              ),
              _ResizeHandle(
                key: AdaptivePaneLayout.utilityResizeHandleKey,
                label: 'Resize utility panel',
                width: widths.utility,
                minimumWidth: AdaptiveShell.minimumUtilityWidth,
                maximumWidth: _maximumUtilityWidth(widths),
                edge: _PaneEdge.trailing,
                widthAfterStep: (delta) => _widthAfterStep(
                  _PaneEdge.trailing,
                  currentWidths()!,
                  constraints.maxWidth,
                  delta,
                ),
                onStep: (delta) =>
                    _stepPane(_PaneEdge.trailing, currentWidths()!, delta),
                onStart: () => _startUtilityResize(currentWidths()!),
                onDelta: _resizeUtility,
                onEnd: _endUtilityResize,
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

  /// Read bounds with each event, not from the handle's last frame: an
  /// immediate reversal after leaving a bound must not see the old width.
  void _stepPane(_PaneEdge edge, AdaptivePaneWidths widths, double delta) {
    final leading = edge == _PaneEdge.leading;
    final growing = (leading ? delta : -delta) > 0;
    final width = leading ? widths.list : widths.utility;
    final minimum = leading
        ? AdaptiveShell.minimumListWidth
        : AdaptiveShell.minimumUtilityWidth;
    final maximum = leading
        ? _maximumListWidth(widths)
        : _maximumUtilityWidth(widths);
    if ((growing && width >= maximum) || (!growing && width <= minimum)) {
      return;
    }
    if (leading) {
      _startListResize(widths);
      _resizeList(delta);
      _endListResize();
    } else {
      _startUtilityResize(widths);
      _resizeUtility(delta);
      _endUtilityResize();
    }
  }

  /// A completed step releases the temporary sibling constraint just like
  /// a finished drag. Announce the resulting allocation, which may differ
  /// from the raw delta while the window clamps both requested widths.
  double _widthAfterStep(
    _PaneEdge edge,
    AdaptivePaneWidths widths,
    double availableWidth,
    double delta,
  ) {
    final leading = edge == _PaneEdge.leading;
    final requested = leading
        ? (widths.list + delta).clamp(
            AdaptiveShell.minimumListWidth,
            _maximumListWidth(widths),
          )
        : (widths.utility + delta).clamp(
            AdaptiveShell.minimumUtilityWidth,
            _maximumUtilityWidth(widths),
          );
    final next = allocateAdaptivePaneWidths(
      availableWidth: availableWidth,
      requestedListWidth: leading ? requested : _requestedListWidth,
      requestedUtilityWidth: leading ? _requestedUtilityWidth : requested,
    )!;
    return leading ? next.list : next.utility;
  }

  double _maximumListWidth(AdaptivePaneWidths widths) =>
      (widths.list + widths.terminal - AdaptiveShell.minimumTerminalWidth)
          .clamp(AdaptiveShell.minimumListWidth, AdaptiveShell.maximumListWidth)
          .toDouble();

  double _maximumUtilityWidth(AdaptivePaneWidths widths) =>
      (widths.utility + widths.terminal - AdaptiveShell.minimumTerminalWidth)
          .clamp(
            AdaptiveShell.minimumUtilityWidth,
            AdaptiveShell.maximumUtilityWidth,
          )
          .toDouble();

  void _startListResize(AdaptivePaneWidths widths) {
    // A window shrink clamps rendered widths without replacing the user's
    // requests. Starting a drag intentionally adopts the rendered widths so
    // the handle does not jump back toward those stale requests.
    _listDragStart = widths.list;
    _listDragDelta = 0;
    _listDragMaximum = _maximumListWidth(widths);
    setState(() {
      _requestedListWidth = widths.list;
      _temporaryUtilityWidth = widths.utility;
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
    // See _startListResize: interaction starts from what the user can see.
    _utilityDragStart = widths.utility;
    _utilityDragDelta = 0;
    _utilityDragMaximum = _maximumUtilityWidth(widths);
    setState(() {
      _temporaryListWidth = widths.list;
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

  void _endListResize() {
    setState(() {
      _listDragStart = null;
      _temporaryUtilityWidth = null;
    });
    widget.onPaneWidthsChanged?.call(
      _requestedListWidth,
      _requestedUtilityWidth,
    );
  }

  void _endUtilityResize() {
    setState(() {
      _utilityDragStart = null;
      _temporaryListWidth = null;
    });
    widget.onPaneWidthsChanged?.call(
      _requestedListWidth,
      _requestedUtilityWidth,
    );
  }
}

/// The owned pane's position in the direction-aware row.
enum _PaneEdge { leading, trailing }

const double _resizeKeyStep = 16;

/// A labelled, keyboard-adjustable divider with the same clamping and
/// persistence boundary as a pointer drag. Physical arrow direction follows
/// the divider; assistive increase/decrease follows the owned pane's width.
class _ResizeHandle extends StatefulWidget {
  final String label;
  final double width;
  final double minimumWidth;
  final double maximumWidth;
  final _PaneEdge edge;
  final double Function(double delta) widthAfterStep;
  final ValueChanged<double> onStep;
  final VoidCallback onStart;
  final ValueChanged<double> onDelta;
  final VoidCallback onEnd;

  const _ResizeHandle({
    super.key,
    required this.label,
    required this.width,
    required this.minimumWidth,
    required this.maximumWidth,
    required this.edge,
    required this.widthAfterStep,
    required this.onStep,
    required this.onStart,
    required this.onDelta,
    required this.onEnd,
  });

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _focused = false;

  double get _direction =>
      Directionality.of(context) == TextDirection.rtl ? -1 : 1;

  double get _grow => widget.edge == _PaneEdge.leading ? 1 : -1;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.onStep(_resizeKeyStep * _direction);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      widget.onStep(-_resizeKeyStep * _direction);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  String _value(double width) => '${width.round()} pixels';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: widget.label,
      slider: true,
      value: _value(widget.width),
      increasedValue: _value(widget.widthAfterStep(_resizeKeyStep)),
      decreasedValue: _value(widget.widthAfterStep(-_resizeKeyStep)),
      onIncrease: widget.width < widget.maximumWidth
          ? () => widget.onStep(_resizeKeyStep * _grow)
          : null,
      onDecrease: widget.width > widget.minimumWidth
          ? () => widget.onStep(-_resizeKeyStep * _grow)
          : null,
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => widget.onStart(),
            onHorizontalDragUpdate: (d) =>
                widget.onDelta(d.delta.dx * _direction),
            onHorizontalDragEnd: (_) => widget.onEnd(),
            onHorizontalDragCancel: widget.onEnd,
            child: SizedBox(
              width: AdaptiveShell.resizeHandleWidth,
              child: Center(
                child: Container(
                  width: _focused ? 3 : 1,
                  color: _focused
                      ? theme.colorScheme.primary
                      : theme.dividerColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
