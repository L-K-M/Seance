import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

/// [seance fork] Regression tests for the selection overhaul. Each test pins
/// one of the defects that motivated forking upstream 4.0.0:
///
/// 1. Triple-click line selection was cleared ~100ms later (the third tap
///    read as a fresh first tap and force-cleared the selection).
/// 2. Slow double-clicks (300–400ms) selected a word that was then cleared.
/// 3. Shift-click extension did not exist — worse, it destroyed an existing
///    selection.
/// 4. A drag's start was re-converted from its raw pixel every update, so the
///    selection slid through content when the viewport moved mid-drag.
/// 5. Selection anchors silently detached when the scrollback trimmed their
///    line — select-all (anchored at row 0) broke as soon as output streamed.
/// 6. While scrolled up, a full scrollback's trim made content crawl under a
///    stationary viewport.
/// 7. Dragging through the blank rows under the shell prompt painted a
///    selection band over them and copied their newlines — the buffer keeps a
///    real line per row, so nothing stopped a gesture there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpTerminal(
    WidgetTester tester,
    Terminal terminal,
    TerminalController controller, {
    ScrollController? scrollController,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
            scrollController: scrollController,
            autofocus: true,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  RenderTerminal render(WidgetTester tester) =>
      tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;

  /// Global pixel position of the center of cell ([col], [row]).
  Offset cellCenter(WidgetTester tester, int col, int row) {
    final r = render(tester);
    final cell = r.cellSize;
    return r.localToGlobal(
      r.getOffset(CellOffset(col, row)) +
          Offset(cell.width / 2, cell.height / 2),
    );
  }

  /// Taps [times] at [position] with [gap] between clicks, then settles all
  /// gesture timers (kPressTimeout, kDoubleTapTimeout, …) so any deferred
  /// clear — the pre-fork failure mode — would have fired.
  Future<void> multiClick(
    WidgetTester tester,
    Offset position,
    int times, {
    Duration gap = const Duration(milliseconds: 120),
  }) async {
    for (var i = 0; i < times; i++) {
      await tester.tapAt(position, kind: PointerDeviceKind.mouse);
      await tester.pump(gap);
    }
    await tester.pump(const Duration(milliseconds: 600));
  }

  group('multi-click', () {
    testWidgets('triple-click selects the line and it stays selected',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('first line\r\nsecond line target\r\nthird line');
      await tester.pump();

      await multiClick(tester, cellCenter(tester, 4, 1), 3);

      final selection = controller.selection;
      expect(selection, isNotNull,
          reason: 'triple-click line selection must survive the tap timers');
      expect(selection!.begin.x, 0);
      expect(selection.begin.y, 1);
      expect(selection.end.y, 1);
      expect(terminal.buffer.getText(selection), contains('second line'));
    });

    testWidgets('slow double-click (350ms gap) still selects the word',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha bravo charlie');
      await tester.pump();

      await multiClick(
        tester,
        cellCenter(tester, 2, 0),
        2,
        gap: const Duration(milliseconds: 350),
      );

      final selection = controller.selection;
      expect(selection, isNotNull,
          reason: 'a 350ms double-click sits in the old 300–400ms dead zone');
      expect(terminal.buffer.getText(selection!).trim(), 'alpha');
    });

    testWidgets('double-click selects the word and it stays selected',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha bravo charlie');
      await tester.pump();

      await multiClick(tester, cellCenter(tester, 2, 0), 2);

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(terminal.buffer.getText(selection!).trim(), 'alpha');
    });
  });

  group('shift-click', () {
    testWidgets('click then shift-click selects the range between the points',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('0123456789abcdefghij');
      await tester.pump();

      await tester.tapAt(cellCenter(tester, 2, 0),
          kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.selection, isNull);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(cellCenter(tester, 12, 0),
          kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      final selection = controller.selection;
      expect(selection, isNotNull,
          reason: 'shift-click must create a selection from the prior click');
      expect(terminal.buffer.getText(selection!).trim(), contains('456789ab'));
    });

    testWidgets(
        'shift-click extends an existing selection instead of clearing it',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha bravo charlie delta');
      await tester.pump();

      // Double-click "alpha".
      await multiClick(tester, cellCenter(tester, 2, 0), 2);
      expect(terminal.buffer.getText(controller.selection!).trim(), 'alpha');

      // Shift-click inside "charlie" — the selection must extend, not die.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(cellCenter(tester, 15, 0),
          kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      final selection = controller.selection;
      expect(selection, isNotNull,
          reason: 'pre-fork, shift-click force-cleared the selection');
      expect(terminal.buffer.getText(selection!), contains('bravo'));
    });
  });

  group('drag anchoring', () {
    testWidgets('drag start stays glued to its text while output streams',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('anchor-me here');
      await tester.pump();

      final gesture = await tester.startGesture(
        cellCenter(tester, 0, 0), // the "a" of "anchor-me"
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(cellCenter(tester, 8, 0));
      await tester.pump();

      // Stream output mid-drag: the buffer scrolls and stick-to-bottom
      // re-pins the viewport. Pre-fork the drag start was re-converted from
      // its raw pixel and slid onto different content.
      for (var i = 0; i < 5; i++) {
        terminal.write('\r\nnoise line $i');
      }
      await tester.pump();

      await gesture.moveTo(cellCenter(tester, 12, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 600));

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(
        terminal.buffer.getText(selection!),
        contains('anchor-me'),
        reason: 'the selection start must stay on the originally dragged text',
      );
    });
  });

  group('trim survival', () {
    testWidgets('select-all selection survives scrollback trimming',
        (tester) async {
      final terminal = Terminal(maxLines: 200);
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      for (var i = 0; i < 150; i++) {
        terminal.write('line $i\r\n');
      }
      await tester.pump();

      // Select-all, anchored at row 0 — the first line to be trimmed.
      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(
          terminal.viewWidth,
          terminal.buffer.height - 1,
        ),
      );
      expect(controller.selection, isNotNull);

      // Push past maxLines so the ring buffer trims the anchored line.
      for (var i = 0; i < 100; i++) {
        terminal.write('overflow $i\r\n');
      }
      await tester.pump();

      final selection = controller.selection;
      expect(selection, isNotNull,
          reason: 'pre-fork the anchor detached and the selection vanished');
      expect(selection!.begin.y, 0,
          reason: 'the base must migrate to the new oldest line');
    });

    testWidgets('scrolled-up viewport stays glued to content across trims',
        (tester) async {
      final terminal = Terminal(maxLines: 200);
      final controller = TerminalController();
      final scrollController = ScrollController();
      await pumpTerminal(
        tester,
        terminal,
        controller,
        scrollController: scrollController,
      );
      for (var i = 0; i < 260; i++) {
        terminal.write('history $i\r\n');
      }
      await tester.pump();

      // Scroll up into the scrollback (not stick-to-bottom).
      scrollController.jumpTo(scrollController.position.maxScrollExtent / 2);
      await tester.pump();
      final offsetBefore = scrollController.offset;
      expect(offsetBefore, greaterThan(0));

      // Each new line trims one off the front (buffer is at maxLines).
      const trims = 4;
      for (var i = 0; i < trims; i++) {
        terminal.write('new $i\r\n');
      }
      await tester.pump();

      final lineHeight = render(tester).lineHeight;
      expect(
        scrollController.offset,
        closeTo(offsetBefore - trims * lineHeight, 0.5),
        reason: 'the offset must shift by exactly the trimmed pixels so the '
            'same content stays under the viewport',
      );
    });
  });

  group('review-fleet regressions', () {
    testWidgets('shift-click after switching to the alt buffer does not throw',
        (tester) async {
      final terminal = Terminal(maxLines: 200);
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      // Build real scrollback so main-buffer rows exceed alt-buffer height.
      for (var i = 0; i < 120; i++) {
        terminal.write('scrollback $i\r\n');
      }
      await tester.pump();

      // Plain click records _lastTapAnchor at a large absolute row.
      await tester.tapAt(cellCenter(tester, 2, terminal.buffer.height - 2),
          kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 600));

      // Switch to the alt buffer (vim/less do this) — far fewer rows.
      terminal.write('\x1b[?1049h');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(cellCenter(tester, 5, 3),
          kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      // Pre-fix this threw a RangeError resolving the main-buffer row
      // against the alt buffer. Now the stale anchor is ignored.
      expect(tester.takeException(), isNull);
    });

    testWidgets('TerminalView.onTapUp fires for a plain click', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      var tapUps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              controller: controller,
              onTapUp: (details, offset) => tapUps++,
            ),
          ),
        ),
      );
      await tester.pump();
      terminal.write('hello');
      await tester.pump();

      await tester.tapAt(cellCenter(tester, 1, 0),
          kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 600));

      // Upstream declared the callback but never invoked it.
      expect(tapUps, 1);
    });

    testWidgets(
        'disposing a controller with a live selection releases its '
        'anchors', (tester) async {
      final terminal = Terminal(maxLines: 50);
      final controller = TerminalController();
      for (var i = 0; i < 40; i++) {
        terminal.write('line $i\r\n');
      }
      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(5, 5),
      );
      final anchoredLine = terminal.buffer.lines[0];
      expect(anchoredLine.anchors, isNotEmpty);
      controller.dispose();
      // Pre-fix the two selection anchors stayed registered on the line
      // forever (and anchor migration would have kept them alive across
      // trims indefinitely).
      expect(anchoredLine.anchors, isEmpty);
    });

    testWidgets(
        'select-all survives a margin scroll on a full buffer '
        '(insert eviction path)', (tester) async {
      final terminal = Terminal(maxLines: 120);
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      for (var i = 0; i < 150; i++) {
        terminal.write('fill $i\r\n');
      }
      await tester.pump();

      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(
          terminal.viewWidth,
          terminal.buffer.height - 1,
        ),
      );
      expect(controller.selection, isNotNull);

      // DECSTBM with top=0 and a bottom margin ABOVE the last row (the
      // status-line layout): IND at the bottom margin then runs
      // lines.insert(absoluteMarginBottom + 1, ...) on a full buffer —
      // the insert() eviction path, not push().
      final marginBottom = terminal.viewHeight - 1;
      terminal.write('\x1b[1;${marginBottom}r');
      terminal.write('\x1b[$marginBottom;1H'); // cursor to the bottom margin
      for (var i = 0; i < 10; i++) {
        terminal.write('\x1bD'); // IND: margin scroll via insert()
      }
      await tester.pump();

      expect(controller.selection, isNotNull,
          reason: 'insert()-path evictions must migrate anchors like push()');
    });
  });

  group('multi-click drag', () {
    /// Press at [origin] as the Nth click of a chain ([precedingClicks]
    /// full clicks first), keep the button down, and return the live
    /// gesture so the caller can drag.
    Future<TestGesture> chainedPress(
      WidgetTester tester,
      Offset origin, {
      required int precedingClicks,
      Duration hold = const Duration(milliseconds: 150),
    }) async {
      for (var i = 0; i < precedingClicks; i++) {
        await tester.tapAt(origin, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 120));
      }
      final gesture = await tester.startGesture(
        origin,
        kind: PointerDeviceKind.mouse,
      );
      // Hold past the tap recognizer's deadline (100ms) so the deferred
      // tap-down — and with it onDouble/TripleTapDown — fires before the
      // drag begins, like an unhurried double-click-drag does.
      await tester.pump(hold);
      return gesture;
    }

    Future<void> release(WidgetTester tester, TestGesture gesture) async {
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('double-click-drag extends the selection by words',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha bravo charlie delta');
      await tester.pump();

      // Click, then press-and-hold on "bravo" (click 2), then drag into
      // the middle of "charlie".
      final gesture = await chainedPress(
        tester,
        cellCenter(tester, 7, 0), // inside "bravo"
        precedingClicks: 1,
      );
      await gesture.moveTo(cellCenter(tester, 15, 0)); // inside "charlie"
      await tester.pump();
      await release(tester, gesture);

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(
        terminal.buffer.getText(selection!).trim(),
        'bravo charlie',
        reason: 'both endpoints must snap to word boundaries: the origin '
            'word stays whole and the word under the pointer joins whole',
      );
    });

    testWidgets(
        'a drag that starts inside the tap deadline still extends by words',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha bravo charlie delta');
      await tester.pump();

      // No hold at all: the pointer starts moving before the 100ms tap
      // deadline, so onDoubleTapDown never fires and the initial word
      // selection must be made by the drag itself.
      final gesture = await chainedPress(
        tester,
        cellCenter(tester, 7, 0), // inside "bravo"
        precedingClicks: 1,
        hold: Duration.zero,
      );
      await gesture.moveTo(cellCenter(tester, 15, 0)); // inside "charlie"
      await tester.pump();
      await release(tester, gesture);

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(terminal.buffer.getText(selection!).trim(), 'bravo charlie');
    });

    testWidgets('double-click-drag backward keeps the origin word whole',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha bravo charlie delta');
      await tester.pump();

      final gesture = await chainedPress(
        tester,
        cellCenter(tester, 15, 0), // inside "charlie"
        precedingClicks: 1,
      );
      await gesture.moveTo(cellCenter(tester, 2, 0)); // inside "alpha"
      await tester.pump();
      await release(tester, gesture);

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(terminal.buffer.getText(selection!).trim(), 'alpha bravo charlie');
    });

    testWidgets('triple-click-drag extends the selection by whole lines',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('first line\r\nsecond line\r\nthird line\r\nfourth');
      await tester.pump();

      final gesture = await chainedPress(
        tester,
        cellCenter(tester, 4, 1), // inside "second line"
        precedingClicks: 2,
      );
      await gesture.moveTo(cellCenter(tester, 3, 2)); // inside "third line"
      await tester.pump();
      await release(tester, gesture);

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(selection!.begin.x, 0, reason: 'line drags span full lines');
      final text = terminal.buffer.getText(selection);
      expect(text, contains('second line'));
      expect(text, contains('third line'));
      expect(text, isNot(contains('first')));
      expect(text, isNot(contains('fourth')));
    });

    testWidgets('a plain drag still selects by characters', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha bravo charlie');
      await tester.pump();

      final gesture = await tester.startGesture(
        cellCenter(tester, 2, 0), // inside "alpha"
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.moveTo(cellCenter(tester, 8, 0)); // inside "bravo"
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 600));

      final selection = controller.selection;
      expect(selection, isNotNull);
      final text = terminal.buffer.getText(selection!);
      expect(
        text,
        isNot(contains('alpha')),
        reason: 'a single-click drag must NOT snap to word boundaries — it '
            'starts mid-word at the pressed cell',
      );
      expect(text, startsWith('pha'));
    });

    testWidgets('a right-click between clicks does not advance the chain',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha bravo charlie');
      await tester.pump();

      final origin = cellCenter(tester, 7, 0); // inside "bravo"
      // Left click, right click, left click — the old recognizer-based
      // counter never saw secondary buttons, so the raw layer must not
      // count them either: the second LEFT click is a double (word select),
      // not a triple (line select).
      await tester.tapAt(origin, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(
        origin,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(origin, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 600));

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(
        terminal.buffer.getText(selection!).trim(),
        'bravo',
        reason: 'left-right-left must read as a double-click (word), '
            'not a triple-click (line)',
      );
    });

    testWidgets('a click after a double-click-drag starts a fresh selection',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha bravo charlie delta');
      await tester.pump();

      final gesture = await chainedPress(
        tester,
        cellCenter(tester, 7, 0),
        precedingClicks: 1,
      );
      await gesture.moveTo(cellCenter(tester, 15, 0));
      await tester.pump();
      await release(tester, gesture);

      // The next click must not chain onto the drag's presses — it is a
      // plain single click, which clears the selection.
      await tester.tapAt(cellCenter(tester, 2, 0), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.selection, isNull);
    });
    testWidgets('double-click-drag from empty space falls back to characters',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha bravo');
      await tester.pump();

      // Origin: the void well past the end of the text, where there is no
      // word boundary at all. The drag must degrade to a character
      // selection, not go inert for the whole gesture.
      final gesture = await chainedPress(
        tester,
        cellCenter(tester, 30, 0),
        precedingClicks: 1,
      );
      await gesture.moveTo(cellCenter(tester, 8, 0)); // into "bravo"
      await tester.pump();
      await release(tester, gesture);

      final selection = controller.selection;
      expect(selection, isNotNull,
          reason: 'a wordless origin must not leave the drag inert');
      expect(terminal.buffer.getText(selection!), contains('avo'));
    });

    testWidgets('a clear (CSI 3J) mid-drag does not break the selection',
        (tester) async {
      final terminal = Terminal(maxLines: 200);
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      for (var i = 0; i < 40; i++) {
        terminal.write('scrollback line $i\r\n');
      }
      terminal.write('alpha bravo charlie');
      await tester.pump();

      // Drag on the last buffer row: its pre-fix stale index (40 in a
      // viewport-sized list) is out of range, so the failure is a hard
      // RangeError, not just a silently shifted selection.
      final lastRow = terminal.buffer.lines.length - 1;
      final gesture = await chainedPress(
        tester,
        cellCenter(tester, 1, lastRow), // inside "alpha"
        precedingClicks: 1,
      );
      await gesture.moveTo(cellCenter(tester, 8, lastRow)); // into "bravo"
      await tester.pump();

      // The remote runs `clear`: CSI 3J trims the whole scrollback out from
      // under the live drag. Anchors must migrate, surviving lines must keep
      // correct indices, and the drag must keep tracking its text.
      terminal.write('\x1b[3J');
      await tester.pump();

      final newLastRow = terminal.buffer.lines.length - 1;
      await gesture.moveTo(cellCenter(tester, 15, newLastRow)); // "charlie"
      await tester.pump();
      await release(tester, gesture);

      expect(tester.takeException(), isNull,
          reason: 'extending a drag across a scrollback trim must not throw');
      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(
        terminal.buffer.getText(selection!).trim(),
        'alpha bravo charlie',
        reason: 'the drag must stay glued to its row across the trim',
      );
    });
  });

  /// [seance fork] The void past the end of the content. A terminal buffer is
  /// created with one blank [BufferLine] per viewport row, so a drag below the
  /// last line of output lands on real, addressable rows: pre-fix it painted a
  /// band across them and copied a newline for each. Selection gestures now
  /// clamp to [Buffer.contentEnd]; mouse reporting and links deliberately do
  /// not, which `mouse_report_test.dart` and `link_gesture_test.dart` pin.
  group('void past the content', () {
    /// Drags from [from] to [to] with a plain primary press, then settles the
    /// gesture timers.
    Future<void> drag(
      WidgetTester tester,
      Offset from,
      Offset to,
    ) async {
      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('a drag that never leaves the void selects nothing',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha\r\nbravo\r\ncharlie');
      await tester.pump();

      // Three rows hold text; drag across rows well below them, the way the
      // pointer lands when you sweep the empty area under a shell prompt.
      await drag(
        tester,
        cellCenter(tester, 30, 8),
        cellCenter(tester, 4, 10),
      );

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(
        terminal.buffer.getText(selection!),
        isEmpty,
        reason: 'pre-fix this copied one newline per blank row crossed',
      );
      expect(
        selection.begin,
        selection.end,
        reason: 'an empty range paints no band over the void',
      );
    });

    testWidgets('a drag that starts in the void and sweeps up takes the output',
        (tester) async {
      // The mirror of the case below: the *press* lands past every row, so the
      // drag's start anchor is the clamped one and `to` lands before it. The
      // reversed range has to normalize, or sweeping up from under the prompt
      // selects nothing.
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha\r\nbravo');
      await tester.pump();

      await drag(tester, cellCenter(tester, 30, 9), cellCenter(tester, 0, 0));

      expect(tester.takeException(), isNull);
      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(
        terminal.buffer.getText(selection!),
        'alpha\nbravo',
        reason: 'the clamped start anchor is the far end of a reversed range',
      );
    });

    testWidgets('a drag out of the output ends where the output does',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha\r\nbravo');
      await tester.pump();

      // From the first character, down past the end of the buffer's content.
      await drag(
        tester,
        cellCenter(tester, 0, 0),
        cellCenter(tester, 30, 12),
      );

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(
        terminal.buffer.getText(selection!),
        'alpha\nbravo',
        reason: 'pre-fix every blank row below "bravo" added a newline',
      );
      expect(selection.end.y, 1, reason: 'the last row holding text');
      expect(selection.end.x, 5, reason: 'one past the "o" of "bravo"');
    });

    testWidgets('a drag past the end of the last line stops at its last cell',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha');
      await tester.pump();

      // Rightward along the only row of text, well past its end. The copied
      // text was always 'alpha' (blank cells contribute nothing); what was
      // wrong is the *band*, which ran to the edge of the terminal.
      await drag(
        tester,
        cellCenter(tester, 0, 0),
        cellCenter(tester, 40, 0),
      );

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(terminal.buffer.getText(selection!), 'alpha');
      expect(
        selection.end.x,
        5,
        reason: 'pre-fix the range ran to the right edge of the viewport',
      );
    });

    testWidgets('triple-clicking the void takes the last line of output',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha\r\nbravo');
      await tester.pump();

      await multiClick(tester, cellCenter(tester, 6, 9), 3);

      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(
        terminal.buffer.getText(selection!),
        'bravo',
        reason: 'pre-fix a blank row was selected, copying nothing',
      );
      expect(selection.begin.y, 1);
    });

    testWidgets('double-clicking the void selects no blank cells',
        (tester) async {
      // The word paths are the only clamped callers that hand contentEnd —
      // one cell *past* the last written cell — to getWordBoundary, so what
      // that returns at the end of content is load-bearing and was unpinned.
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha\r\nbravo');
      await tester.pump();

      await multiClick(tester, cellCenter(tester, 6, 9), 2);

      expect(tester.takeException(), isNull);
      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(
        terminal.buffer.getText(selection!),
        'bravo',
        reason: 'pre-fix a word of blank cells was taken, copying nothing',
      );
      expect(selection.begin.y, 1, reason: 'the last row holding text');
    });

    /// [clicks] taps at [at], then holds one more press there and drags it to
    /// [to] — so the drag runs as the (clicks+1)-th click of the chain, which
    /// is what puts it on the line or word *continuation* path.
    Future<void> holdDragFrom(
      WidgetTester tester,
      int clicks,
      Offset at,
      Offset to,
    ) async {
      for (var i = 0; i < clicks; i++) {
        await tester.tapAt(at, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 100));
      }
      final gesture = await tester.startGesture(at,
          kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('a held line drag into the void keeps the line it started on',
        (tester) async {
      // dragLineSelection's clamped `to`, which nothing else here exercised:
      // the group otherwise only pins presses and plain character drags.
      // Verified to have teeth — unclamped this copies 'bravo\n', absorbing a
      // blank row.
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha\r\nbravo');
      await tester.pump();

      await holdDragFrom(
        tester, 2, cellCenter(tester, 1, 1), cellCenter(tester, 20, 10));

      expect(tester.takeException(), isNull);
      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(
        terminal.buffer.getText(selection!),
        'bravo',
        reason: 'dragging the band into the void must absorb no blank rows',
      );
    });

    testWidgets('a held word drag into the void keeps the word it started on',
        (tester) async {
      // The same gesture on the word path. This pins the observable contract
      // rather than the clamp: getWordBoundary returns null for a void cell,
      // so selectWordTo returns early and the initial word stands whether or
      // not `to` was clamped. Kept because the contract is what users see.
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);
      terminal.write('alpha\r\nbravo');
      await tester.pump();

      await holdDragFrom(
        tester, 1, cellCenter(tester, 1, 1), cellCenter(tester, 20, 10));

      expect(tester.takeException(), isNull);
      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(terminal.buffer.getText(selection!), 'bravo');
    });

    testWidgets('an untouched terminal cannot be selected into', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      await pumpTerminal(tester, terminal, controller);

      // Nothing has ever been written: Buffer.contentEnd is null and every
      // gesture has to collapse rather than index a line that holds nothing.
      await drag(
        tester,
        cellCenter(tester, 2, 2),
        cellCenter(tester, 20, 7),
      );

      expect(tester.takeException(), isNull);
      final selection = controller.selection;
      expect(selection, isNotNull);
      expect(terminal.buffer.getText(selection!), isEmpty);
      expect(selection.begin, selection.end);
    });
  });
}
