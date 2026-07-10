import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// [seance fork] Signature for tap-down callbacks that carry the position of
/// the tap in a chained multi-click sequence (1 = single, 2 = double,
/// 3 = triple; a fourth click starts a new sequence at 1).
typedef GestureCountedTapDownCallback = void Function(
  TapDownDetails details,
  int tapCount,
);

class TerminalGestureDetector extends StatefulWidget {
  const TerminalGestureDetector({
    super.key,
    this.child,
    this.onSingleTapUp,
    this.onTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressUp,
    this.onLongPressEnd,
    this.onLongPressCancel,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
    this.onDoubleTapDown,
    this.onTripleTapDown,
  });

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  /// [seance fork] Now carries the tap count so the view can decide whether
  /// this tap-down should clear the selection (single) or is the prelude to a
  /// word/line selection (double/triple).
  final GestureCountedTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onDoubleTapDown;

  /// [seance fork] Third chained tap — triple-click.
  final GestureTapDownCallback? onTripleTapDown;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final GestureLongPressStartCallback? onLongPressStart;

  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;

  final GestureLongPressUpCallback? onLongPressUp;

  /// [seance fork] End/cancel companions to the long-press callbacks —
  /// without them a cancelled long-press could never release per-gesture
  /// state (selection anchors, the edge-autoscroll ticker).
  final GestureLongPressEndCallback? onLongPressEnd;

  final GestureLongPressCancelCallback? onLongPressCancel;

  final GestureDragStartCallback? onDragStart;

  final GestureDragUpdateCallback? onDragUpdate;

  /// [seance fork] Upstream never wired drag end/cancel, so nothing could
  /// clean up per-drag state (selection anchors, autoscroll tickers).
  final GestureDragEndCallback? onDragEnd;

  final GestureDragCancelCallback? onDragCancel;

  @override
  State<TerminalGestureDetector> createState() =>
      _TerminalGestureDetectorState();
}

class _TerminalGestureDetectorState extends State<TerminalGestureDetector> {
  /// [seance fork] Multi-click state machine. Upstream hand-rolled a
  /// double-tap tracker that armed its timer only from a *single* tap-up, so
  /// the third click of a triple-click always looked like a fresh first tap
  /// (and slow doubles in the 300–400ms gap did too). This machine chains
  /// counts 1→2→3 with the standard [kDoubleTapTimeout] window anchored at
  /// every tap-up and [kDoubleTapSlop] positional tolerance.
  Timer? _tapSequenceTimer;

  /// [seance fork] Chain window between a tap-up and the next tap-down.
  /// Deliberately wider than Flutter's [kDoubleTapTimeout] (300ms): OS
  /// double-click timeouts run ~500ms, and the 300ms window made unhurried
  /// double-clicks read as two singles.
  static const _multiClickWindow = Duration(milliseconds: 400);

  Offset? _lastTapOffset;

  int _tapCount = 0;

  void _handleTapDown(TapDownDetails details) {
    if (_tapSequenceTimer != null &&
        _isWithinDoubleTapTolerance(details.globalPosition) &&
        _tapCount < 3) {
      _tapCount += 1;
    } else {
      _tapCount = 1;
    }
    _tapSequenceTimer?.cancel();
    _tapSequenceTimer = null;
    _lastTapOffset = details.globalPosition;

    widget.onTapDown?.call(details, _tapCount);

    if (_tapCount == 2) {
      widget.onDoubleTapDown?.call(details);
    } else if (_tapCount == 3) {
      widget.onTripleTapDown?.call(details);
    }
  }

  void _handleTapUp(TapUpDetails details) {
    // Every tap-up, regardless of count — mouse-reporting remotes need a
    // button-up for each button-down or they see a stuck button.
    widget.onTapUp?.call(details);
    if (_tapCount == 1) {
      widget.onSingleTapUp?.call(details);
    }
    // Re-arm the window from every tap-up so the next click can continue the
    // sequence (up₁→down₂ for doubles, up₂→down₃ for triples).
    _tapSequenceTimer?.cancel();
    _tapSequenceTimer = Timer(_multiClickWindow, _tapSequenceTimeout);
  }

  void _tapSequenceTimeout() {
    _tapSequenceTimer = null;
    _lastTapOffset = null;
    _tapCount = 0;
  }

  /// [seance fork] The tap lost the arena (the pointer became a drag). Reset
  /// the sequence so the drag's press — which already fired _handleTapDown at
  /// the deadline — can't count toward a later click's double/triple.
  void _handleTapCancel() {
    _tapSequenceTimer?.cancel();
    _tapSequenceTimeout();
  }

  bool _isWithinDoubleTapTolerance(Offset secondTapOffset) {
    if (_lastTapOffset == null) {
      return false;
    }

    final Offset difference = secondTapOffset - _lastTapOffset!;
    return difference.distance <= kDoubleTapSlop;
  }

  @override
  void dispose() {
    _tapSequenceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gestures = <Type, GestureRecognizerFactory>{};

    gestures[TapGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
      () => TapGestureRecognizer(debugOwner: this),
      (TapGestureRecognizer instance) {
        instance
          ..onTapDown = _handleTapDown
          ..onTapUp = _handleTapUp
          ..onTapCancel = _handleTapCancel
          ..onSecondaryTapDown = widget.onSecondaryTapDown
          ..onSecondaryTapUp = widget.onSecondaryTapUp
          ..onTertiaryTapDown = widget.onTertiaryTapDown
          ..onTertiaryTapUp = widget.onTertiaryTapUp;
      },
    );

    gestures[LongPressGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
      () => LongPressGestureRecognizer(
        debugOwner: this,
        supportedDevices: {
          PointerDeviceKind.touch,
          // PointerDeviceKind.mouse, // for debugging purposes only
        },
      ),
      (LongPressGestureRecognizer instance) {
        instance
          ..onLongPressStart = widget.onLongPressStart
          ..onLongPressMoveUpdate = widget.onLongPressMoveUpdate
          ..onLongPressUp = widget.onLongPressUp
          ..onLongPressEnd = widget.onLongPressEnd
          ..onLongPressCancel = widget.onLongPressCancel;
      },
    );

    gestures[PanGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
      () => PanGestureRecognizer(
        debugOwner: this,
        supportedDevices: <PointerDeviceKind>{PointerDeviceKind.mouse},
      ),
      (PanGestureRecognizer instance) {
        instance
          ..dragStartBehavior = DragStartBehavior.down
          ..onStart = widget.onDragStart
          ..onUpdate = widget.onDragUpdate
          ..onEnd = widget.onDragEnd
          ..onCancel = widget.onDragCancel;
      },
    );

    return RawGestureDetector(
      gestures: gestures,
      excludeFromSemantics: true,
      child: widget.child,
    );
  }
}
