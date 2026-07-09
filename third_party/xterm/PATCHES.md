# Séance's xterm fork — divergences from upstream 4.0.0

This package is a vendored copy of [xterm.dart] 4.0.0 (MIT, see LICENSE),
taken verbatim from pub.dev and then patched. The fork exists because the
selection defects it fixes live in private `State`/render wiring that no
public API reaches — the app cannot fix them from outside, and upstream has
no seam to inject behavior (PROPOSAL.md M2 planned this vendoring; the
libghostty engine eventually replaces the whole package behind seance_core's
`TerminalEngine` seam).

Keep this file exhaustive: every behavioral divergence from upstream 4.0.0
gets an entry, so a future upgrade (or the libghostty swap) knows exactly
what must be preserved.

[xterm.dart]: https://github.com/TerminalStudio/xterm.dart

## Patches

1. **Test goldens regenerated** (`test/src/_goldens/*.png`): upstream's golden
   images were rendered under an older Flutter; the SDK this project pins
   renders text a fraction of a percent differently (0.06–0.13% pixel diff),
   failing the two `TerminalView.textScaler` golden tests. Regenerated with
   `flutter test --update-goldens` — a test-asset refresh, zero library-code
   change.

### Selection overhaul (regressions: `test/src/ui/selection_gesture_test.dart`)

2. **Multi-click state machine** (`ui/gesture/gesture_detector.dart`):
   upstream's hand-rolled double-tap tracker armed its window only from a
   *single* tap-up, so the third click of a triple always read as a fresh
   first tap, and slow doubles (300–400ms) read as two singles. Replaced with
   a 1→2→3 tap-count machine (400ms window — wider than `kDoubleTapTimeout`
   on purpose; OS double-click timeouts run ~500ms), `onTripleTapDown`, and
   `onDragEnd`/`onDragCancel` wiring (upstream never wired pan end/cancel).
   `onTapDown` callbacks now carry the tap count.

3. **Clear-on-tap only for plain single taps**
   (`terminal_view.dart#_onTapDown`): upstream cleared the selection on
   *every* primary tap-down — which destroyed the word/line selection that a
   double/triple-click was about to make (the selection lived ~100ms).

4. **Triple-click line selection** (`ui/render.dart#selectLine`): selects the
   full logical line under the click, following soft-wrap continuations.

5. **Shift-click extension** (`terminal_view.dart`,
   `ui/controller.dart#extendSelectionTo`): shift-click extends the live
   selection from its base, or selects between the last plain click and the
   shift-click when no selection exists. The last plain click is remembered
   as a content-glued `CellAnchor`. Shift-clicks also bypass mouse reporting
   (`ui/gesture/gesture_handler.dart#_shouldSendTapEvent`) — the standard
   escape hatch for local selection while vim/less own the mouse.

6. **Anchored drag selection** (`ui/gesture/gesture_handler.dart`,
   `ui/render.dart#selectCharactersTo`/`selectWordTo`): the drag origin is
   captured once as a `CellAnchor` (word drags pin their origin word's
   boundary anchors). Upstream re-converted the raw start *pixel* on every
   update, so the selection start slid through content whenever the viewport
   moved mid-drag (streaming output, wheel scroll, stick-to-bottom re-pin).

7. **Drag edge-autoscroll** (`ui/gesture/gesture_handler.dart`,
   `terminal_view.dart#autoScrollBy`): dragging within 24px of (or past) the
   top/bottom edge scrolls the viewport proportionally and keeps extending
   the selection — selecting across the scroll border used to mean selecting
   blind, since nothing ever scrolled.

8. **Scroll anchoring across scrollback trims**
   (`ui/render.dart#_correctForTrimmedLines`,
   `utils/circular_buffer.dart#absoluteStartIndex`): when scrolled up and the
   full ring buffer trims a line per newline, the scroll offset now shifts by
   the trimmed pixels so content no longer crawls up under a stationary
   viewport (which also made click coordinates land on moving targets).

9. **Selection anchors survive trims**
   (`utils/circular_buffer.dart#migrateOnEvict`,
   `core/buffer/line.dart`): a trimmed line hands its anchors to the new
   oldest line (clamped to its start) instead of detaching them — a
   select-all (anchored at row 0, the first line to trim) used to silently
   vanish the moment output streamed.

10. **Keyboard-show no longer yanks a scrolled-up viewport**
    (`terminal_view.dart#_onKeyboardShow`, `ui/render.dart#stickToBottom`):
    the jump-to-bottom on soft-keyboard show now only happens when already
    at the bottom; tapping a scrolled-up terminal on touch used to rip the
    viewport to the bottom mid-selection.

11. **Mouse-report hygiene** (`ui/render.dart#mouseEvent`,
    `ui/gesture/gesture_handler.dart`, `terminal_view.dart`): click reports
    to mouse-enabled remote apps now use viewport-relative rows (upstream
    sent buffer-absolute rows — off by the scrollback length); clicks landing
    in scrollback fall through to local handling; button-up is reported for
    every tap (upstream only reported it for single taps, leaving remotes
    with a stuck button after a double-click); middle clicks report as
    middle, not right; tertiary taps route to the tertiary callbacks; the
    alt-buffer wheel handler converts global→local coordinates before cell
    conversion.

12. **Forward-drag end-inclusion uses position order**
    (`ui/render.dart#selectCharacters`): the “include the cell under the
    pointer” +1 fired on `to.x >= from.x` alone (ignoring y), mis-shaping
    up-and-left drags by one cell.

13. **Select-all includes scrollback** (`ui/shortcut/actions.dart`): the
    built-in `SelectAllTextIntent` selected only the visible page.

14. **`TerminalView.onTapUp` actually fires** (via
    `gesture_handler.dart#onTapUp`): upstream declared the public callback
    but never invoked it.
