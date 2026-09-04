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

### Hardening from the adversarial review round (same regression file)

15. **Cross-buffer anchor safety** (`core/buffer/buffer.dart#ownsAnchor`,
    `utils/circular_buffer.dart#attachedTo`, `terminal_view.dart`,
    `ui/render.dart`): every anchor captured for shift-click or a drag is now
    validated against the ACTIVE buffer before being resolved. An anchor
    captured in the main buffer and resolved against the alt buffer (vim/less
    opened between clicks, or a buffer switch mid-drag — the autoscroll
    ticker keeps extending without new pointer events) threw a RangeError:
    main-buffer rows can exceed the alt buffer's height. The view also drops
    its recorded click when the widget's Terminal instance is swapped
    (reconnect).

16. **Left button-up reaches mouse-reporting remotes again**
    (`ui/gesture/gesture_detector.dart`, `ui/gesture/gesture_handler.dart`):
    the first fork cut moved up-reporting to an onTapUp path the detector
    never invoked, so remotes saw downs with no ups (upstream at least
    reported singles). Every tap-up now reports exactly once, routed the way
    its down was routed (the down's shift/readOnly decision is remembered —
    releasing shift mid-press no longer strands the remote's button state).

17. **Long-press end/cancel wired** (`gesture_detector.dart`,
    `gesture_handler.dart`): a cancelled long-press (system gesture stealing
    the pointer) previously left the edge-autoscroll ticker running forever
    and the word anchors alive. Tap-cancel (a press that becomes a drag) also
    resets the multi-click sequence so it can't pollute a later click's
    count.

18. **Anchor-eviction coverage widened**
    (`utils/circular_buffer.dart#insert`): the full-buffer eviction inside
    `insert()` — hit by IND margin scrolls with top=0 and a bottom margin
    above the last row (status-line layouts) — now migrates anchors exactly
    like `push()`. Known remaining gap, accepted: `replaceWith()` after a
    reflow that overflows maxLines drops the overflowed head lines without
    migration (a width-resize of a full scrollback degrades to upstream's
    detach behavior there).

19. **Anchor-loop hygiene** (`core/buffer/line.dart`): `removeCells`,
    `insertCells`, and `BufferLine.dispose` iterated `_anchors` while
    `CellAnchor.dispose()`/`reparent` mutate it — skipping anchors (stale
    selection endpoints after DCH/ICH) or throwing
    ConcurrentModificationError. All three now iterate a snapshot.

20. **Controller disposal releases selection anchors**
    (`ui/controller.dart#dispose`): a controller disposed mid-selection
    leaked its two anchors; with anchor migration (patch 9) they would have
    been kept alive by the buffer indefinitely.

21. **Trim scroll-anchoring respects bounce overscroll**
    (`ui/render.dart#_correctForTrimmedLines`): the correction is skipped
    while `_scrollOffset <= 0` so it cannot fight BouncingScrollPhysics'
    rubber-banding at the top.

### Input round (Option dead keys, multi-click drags)

22. **Option/Alt composes on Apple platforms** (`core/input/handler.dart`
    `#AltInputHandler`, `terminal.dart#charInput`; regressions:
    `test/src/core/input/handler_test.dart`): the alt-sends-Meta guard now
    covers `ios` as well as `macos` — iPad hardware keyboards compose with
    Option exactly like a Mac. On Apple platforms an alt-modified letter
    falls through **unconsumed**, which is what lets the OS IME run the
    dead-key composition (`~` is Option-N on Swiss layouts; `@` is Option-G
    on German ones). Consuming it emitted `ESC N` instead and — because the
    key event was marked handled — the composition never started. (The `:`
    users saw was remote readline: `M-n`/`M-N` open its non-incremental
    history search, whose prompt character is `:`.) Note the app must pass
    `platform:` when constructing `Terminal` — the default `unknown` takes
    the non-Apple path; see App-layer notes.

    Two deliberate knock-on effects of a real platform reaching the keytab:
    - **Option-Arrow word-jumps on Apple platforms**: the keytab's `+Mac`
      records now match, so Option-Right/Left send `ESC f`/`ESC b` (what
      Terminal.app and iTerm2 send) instead of the ctrl-arrow encoding
      `CSI 1;5C/D`. Regression-tested in `handler_test.dart`. A remote vim
      user who relied on the old (unintended) ctrl-arrow encoding will see
      native-Mac behavior instead.
    - The keytab's `macos:` flag counts `ios` as Mac too — an iPad hardware
      keyboard is an Apple keyboard, consistent with the two gates above.

23. **Alt-as-Meta sends the lowercase letter**
    (`core/input/handler.dart#AltInputHandler`, `terminal.dart#charInput`):
    alt+n now emits `ESC n`, matching xterm and Konsole. Upstream emitted
    the uppercase letter unconditionally, which remote readline binds
    differently (`M-n` is history search; `M-N` is unbound).

24. **Double- and triple-click drags extend by words and lines**
    (`ui/gesture/gesture_detector.dart`, `ui/gesture/gesture_handler.dart`,
    `ui/render.dart#selectLineTo`/`#createLineAnchorsAt`; regressions:
    `test/src/ui/selection_gesture_test.dart` "multi-click drag"): a drag
    now inherits the tap count of the press it grew out of — click-click-
    drag extends by whole words from the origin word, click-click-click-
    drag by whole logical lines, matching every native terminal. Two layers
    were missing:
    - The press count is now recorded at the **raw pointer layer**
      (a `Listener` under the recognizers). The tap recognizer reports a
      tap-down only at its 100ms deadline, so a press that starts moving
      earlier never registered — and by the time the pan recognizer won the
      arena, the tap's rejection had already reset the sequence counter.
      One source of truth now serves taps, deadline-fired holds, and
      immediate drags alike (and multi-touch chords reset the chain).
    - `onDragStart` carries that count and picks the drag's granularity:
      ≤1 → characters (unchanged), 2 → the existing word-anchor machinery,
      ≥3 → new line anchors + `selectLineTo`, which follows soft-wrap
      continuations exactly like triple-click `selectLine`. When the drag
      began inside the tap deadline (no `onDoubleTapDown` ever fired), the
      drag start performs the initial word/line selection itself.
    - The raw layer counts only primary-button presses (chain state keyed by
      pointer id): right/middle clicks never fed the old recognizer-based
      counter, so they must neither advance nor reset the chain — else
      click, right-click, click read as a triple. Multi-touch chords still
      reset it.
    - A word-drag whose origin has no word (blank line, the void past the
      end of text — `getWordBoundary` returns null there) falls back to a
      character drag instead of leaving the whole gesture inert.

25. **`trimStart` does the same anchor/index bookkeeping as eviction**
    (`utils/circular_buffer.dart#trimStart`; regressions:
    `circular_buffer_test.dart`, `selection_gesture_test.dart` "CSI 3J"):
    the one trim path patches 8/9 never covered. `Buffer.clearScrollback`
    (CSI 3J — what the remote `clear` command emits) reaches it, and
    upstream's implementation only moved the ring's start index: trimmed
    lines stayed attached (so `ownsAnchor` guards passed on anchors whose
    rows no longer existed → RangeError from the next selection op), every
    surviving line's `index` went stale by the trimmed count (so even
    freshly created anchors were wrong for the rest of the session), and
    `absoluteStartIndex` never advanced (so the viewport was never told how
    much content vanished). It now migrates trimmed lines' anchors to the
    first survivor, detaches the trimmed slots, and advances
    `absoluteStartIndex` — exactly like a ring-buffer eviction.

26. **Clickable web URLs** (`core/buffer/buffer.dart#getLinkAt`,
    `terminal_view.dart#onLinkTap`; regressions: `link_test.dart`,
    `link_gesture_test.dart`): HTTP(S) detection follows soft wraps and maps
    wide characters to display cells. Prose punctuation is trimmed; credentials
    and non-web schemes are rejected. Logical lines exceeding 16K cells are
    skipped to bound hover work. Links show a hand cursor and activate on
    Ctrl-click (Cmd-click on Apple platforms) or touch tap. Plain clicks,
    shift-clicks, drags, and remote mouse reporting keep their existing behavior.
    The app launches links externally and reports browser failures.

### App-layer notes (outside this package)

- The app passes `shortcuts: {}` and instead routes ⌘C/⌘V/⌘A on
  macOS/iPadOS and Ctrl+Shift+C/V/A elsewhere through its own key handler —
  plain Ctrl+A/Ctrl+V flow to the shell (readline line-home / literal ^V).
- The app constructs `Terminal(platform: ...)` from the host OS
  (`XtermTerminalEngine.detectPlatform`). Leaving the default
  `TerminalTargetPlatform.unknown` re-introduces the Option-dead-key bug of
  patch 22 — `unknown` takes the non-Apple, alt-sends-Meta path.

