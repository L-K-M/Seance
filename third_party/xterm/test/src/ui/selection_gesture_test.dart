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
}
