import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.readOnly = false,
  });

  final TerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  /// [seance fork] Carries the multi-click tap count (see
  /// [GestureCountedTapDownCallback]).
  final GestureCountedTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final bool readOnly;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  TerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  /// [seance fork] The drag origin, captured ONCE at drag start as a buffer
  /// anchor so it stays glued to its text while the viewport moves mid-drag
  /// (streaming output, wheel scroll, autoscroll, scrollback trim). Upstream
  /// kept the raw start *pixel* and re-converted it on every update, which
  /// slid the selection start through content whenever the view scrolled.
  CellAnchor? _dragStartAnchor;

  /// [seance fork] Word-boundary anchors of the word under the gesture
  /// origin, for word-select drags (touch pan / long-press).
  CellAnchor? _dragWordBegin;
  CellAnchor? _dragWordEnd;

  /// [seance fork] Edge-autoscroll state: while a drag sits near (or past)
  /// the top/bottom edge, scroll the viewport a proportional step per tick
  /// and re-extend the selection to the latest pointer position. Without
  /// this, selecting past the visible screen meant selecting blind.
  Timer? _autoScrollTimer;
  Offset? _lastDragLocalPosition;

  static const _autoScrollEdge = 24.0;
  static const _autoScrollTick = Duration(milliseconds: 50);
  static const _maxAutoScrollStepPx = 200.0;

  @override
  void dispose() {
    _stopAutoScroll();
    _disposeDragAnchors();
    super.dispose();
  }

  void _disposeDragAnchors() {
    _dragStartAnchor?.dispose();
    _dragStartAnchor = null;
    _dragWordBegin?.dispose();
    _dragWordBegin = null;
    _dragWordEnd?.dispose();
    _dragWordEnd = null;
  }

  @override
  Widget build(BuildContext context) {
    return TerminalGestureDetector(
      child: widget.child,
      onTapUp: onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      // [seance fork] Upstream wired tertiary taps to the *secondary*
      // handlers, reporting middle clicks as right clicks.
      onTertiaryTapDown: onTertiaryTapDown,
      onTertiaryTapUp: onTertiaryTapUp,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      onLongPressUp: onLongPressUp,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDragEnd: onDragEnd,
      onDragCancel: onDragCancel,
      onDoubleTapDown: onDoubleTapDown,
      onTripleTapDown: onTripleTapDown,
    );
  }

  /// [seance fork] Shift-clicks always select locally — the standard terminal
  /// convention for reaching local selection while a remote app (vim, less…)
  /// has mouse reporting enabled.
  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      !HardwareKeyboard.instance.isShiftPressed &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap);

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap down event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap up event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details, int tapCount) {
    // onTapDown is special, as it will always call the supplied callback.
    // The TerminalView depends on it to bring the terminal into focus.
    _tapDown(
      (details) => widget.onTapDown?.call(details, tapCount),
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  /// [seance fork] Button-up used to be reported only for *single* taps
  /// (via onSingleTapUp), leaving mouse-reporting remotes with a stuck button
  /// after a double click. Every tap-up now reports exactly once, here.
  void onTapUp(TapUpDetails details) {
    _tapUp(widget.onTapUp, details, TerminalMouseButton.left);
  }

  void onSingleTapUp(TapUpDetails details) {
    widget.onSingleTapUp?.call(details);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    // [seance fork] Was reported as TerminalMouseButton.right upstream.
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.middle);
  }

  void onDoubleTapDown(TapDownDetails details) {
    renderTerminal.selectWord(details.localPosition);
  }

  /// [seance fork] Triple-click selects the full logical line (following
  /// soft-wrap continuations). Upstream had no triple-click at all — the
  /// third tap looked like a fresh first tap and *cleared* whatever the
  /// double-click had just selected.
  void onTripleTapDown(TapDownDetails details) {
    renderTerminal.selectLine(details.localPosition);
  }

  void onLongPressStart(LongPressStartDetails details) {
    _disposeDragAnchors();
    final anchors = renderTerminal.createWordAnchorsAt(details.localPosition);
    if (anchors != null) {
      _dragWordBegin = anchors.$1;
      _dragWordEnd = anchors.$2;
    }
    renderTerminal.selectWord(details.localPosition);
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final begin = _dragWordBegin;
    final end = _dragWordEnd;
    if (begin == null || end == null) return;
    _lastDragLocalPosition = details.localPosition;
    renderTerminal.selectWordTo(begin, end, details.localPosition);
    _updateAutoScroll(details.localPosition);
  }

  void onLongPressUp() {
    _endSelectionGesture();
  }

  void onDragStart(DragStartDetails details) {
    _disposeDragAnchors();
    _lastDragLocalPosition = details.localPosition;

    if (details.kind == PointerDeviceKind.mouse) {
      _dragStartAnchor = renderTerminal.createAnchorAt(details.localPosition);
      renderTerminal.selectCharacters(details.localPosition);
    } else {
      final anchors = renderTerminal.createWordAnchorsAt(details.localPosition);
      if (anchors != null) {
        _dragWordBegin = anchors.$1;
        _dragWordEnd = anchors.$2;
      }
      renderTerminal.selectWord(details.localPosition);
    }
  }

  void onDragUpdate(DragUpdateDetails details) {
    _lastDragLocalPosition = details.localPosition;
    _extendSelectionTo(details.localPosition);
    _updateAutoScroll(details.localPosition);
  }

  void onDragEnd(DragEndDetails details) {
    _endSelectionGesture();
  }

  void onDragCancel() {
    _endSelectionGesture();
  }

  void _endSelectionGesture() {
    _stopAutoScroll();
    _disposeDragAnchors();
    _lastDragLocalPosition = null;
  }

  void _extendSelectionTo(Offset localPosition) {
    final start = _dragStartAnchor;
    if (start != null) {
      renderTerminal.selectCharactersTo(start, localPosition);
      return;
    }
    final begin = _dragWordBegin;
    final end = _dragWordEnd;
    if (begin != null && end != null) {
      renderTerminal.selectWordTo(begin, end, localPosition);
    }
  }

  void _updateAutoScroll(Offset localPosition) {
    final height = renderTerminal.size.height;
    final overshoot = localPosition.dy < _autoScrollEdge
        ? localPosition.dy - _autoScrollEdge
        : localPosition.dy > height - _autoScrollEdge
            ? localPosition.dy - (height - _autoScrollEdge)
            : 0.0;

    if (overshoot == 0.0) {
      _stopAutoScroll();
      return;
    }

    _autoScrollTimer ??= Timer.periodic(_autoScrollTick, (_) {
      final position = _lastDragLocalPosition;
      if (position == null) {
        _stopAutoScroll();
        return;
      }
      final height = renderTerminal.size.height;
      final overshoot = position.dy < _autoScrollEdge
          ? position.dy - _autoScrollEdge
          : position.dy > height - _autoScrollEdge
              ? position.dy - (height - _autoScrollEdge)
              : 0.0;
      if (overshoot == 0.0) {
        _stopAutoScroll();
        return;
      }
      // Scroll proportionally to how far past the edge the pointer sits.
      final step = overshoot.clamp(-_maxAutoScrollStepPx, _maxAutoScrollStepPx);
      terminalView.autoScrollBy(step);
      _extendSelectionTo(position);
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }
}
