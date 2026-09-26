import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('TerminalController', () {
    testWidgets('setSelectionRange works', (tester) async {
      final terminal = Terminal();
      final terminalView = TerminalController();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: terminalView,
          ),
        ),
      ));

      terminalView.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(2, 2),
      );

      await tester.pump();

      expect(terminalView.selection, isNotNull);
    });

    testWidgets('setSelectionMode changes BufferRange type', (tester) async {
      final terminal = Terminal();
      final terminalView = TerminalController();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: terminalView,
          ),
        ),
      ));

      terminalView.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(2, 2),
      );

      expect(terminalView.selection, isA<BufferRangeLine>());

      terminalView.setSelectionMode(SelectionMode.block);

      expect(terminalView.selection, isA<BufferRangeBlock>());
    });

    testWidgets('clearSelection works', (tester) async {
      final terminal = Terminal();
      final terminalView = TerminalController();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: terminalView,
          ),
        ),
      ));

      terminalView.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(2, 2),
      );

      expect(terminalView.selection, isNotNull);

      terminalView.clearSelection();

      expect(terminalView.selection, isNull);
    });
  });

  group('TerminalController.highlight', () {
    test('works', () {
      final terminal = Terminal();
      final controller = TerminalController();

      final highlight = controller.highlight(
        p1: terminal.buffer.createAnchor(5, 5),
        p2: terminal.buffer.createAnchor(5, 10),
        color: Colors.yellow,
      );
      assert(controller.highlights.length == 1);

      highlight.dispose();
      assert(controller.highlights.isEmpty);
    });

    const hitBackground = Color(0xFF204060);
    const hitForeground = Color(0xFFE0C080);

    Future<RenderTerminal> pumpTerminal(
      WidgetTester tester,
      Terminal terminal,
      TerminalController controller, {
      GlobalKey? boundary,
    }) async {
      final key = GlobalKey<TerminalViewState>();
      await tester.pumpWidget(MaterialApp(
        home: RepaintBoundary(
          key: boundary,
          child: TerminalView(
            terminal,
            key: key,
            controller: controller,
            textStyle: const TerminalStyle(fontSize: 20),
          ),
        ),
      ));
      return key.currentState!.renderTerminal;
    }

    // [seance fork] A highlight with a foreground recolours its cells: the
    // fill under the glyphs, the glyphs in the foreground. Painted over them
    // as upstream does, an opaque search-hit colour hid the text it marked.
    testWidgets('with a foreground paints under the text, in its colours',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final boundary = GlobalKey();
      final render = await pumpTerminal(
        tester,
        terminal,
        controller,
        boundary: boundary,
      );
      terminal.write('MMMM');
      controller.highlight(
        p1: terminal.buffer.createAnchor(1, 0),
        p2: terminal.buffer.createAnchor(3, 0),
        color: hitBackground,
        foreground: hitForeground,
      );
      await tester.pump();

      final pixels = await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary)
            .toImage();
        final bytes = await image.toByteData();
        return (image.width, bytes!);
      });
      final (width, bytes) = pixels!;
      Color pixel(Offset at) {
        final i = (at.dy.round() * width + at.dx.round()) * 4;
        return Color.fromARGB(
          bytes.getUint8(i + 3),
          bytes.getUint8(i),
          bytes.getUint8(i + 1),
          bytes.getUint8(i + 2),
        );
      }

      final cell = render.cellSize;
      Offset cellOrigin(int x) =>
          render.localToGlobal(render.getOffset(CellOffset(x, 0)));
      // The test font draws every glyph as a box in the middle of the cell,
      // with the line's leading above it.
      Offset glyph(int x) => cellOrigin(x) + cell.center(Offset.zero);
      Offset leading(int x) => cellOrigin(x) + Offset(cell.width / 2, 1);

      expect(pixel(glyph(1)), hitForeground);
      expect(pixel(leading(1)), hitBackground);
      expect(pixel(glyph(2)), hitForeground);
      // The end is exclusive, and cells outside keep their own colours.
      expect(pixel(glyph(3)), isNot(hitForeground));
      expect(pixel(leading(3)), isNot(hitBackground));
      expect(pixel(glyph(0)), isNot(hitForeground));
    });

    // [seance fork] Where recolouring highlights overlap, the newest wins,
    // as it does for overlay highlights, which paint in creation order.
    testWidgets('overlapping foregrounds: the newest highlight wins',
        (tester) async {
      const newerBackground = Color(0xFF602040);
      const newerForeground = Color(0xFF80E0C0);
      final terminal = Terminal();
      final controller = TerminalController();
      final boundary = GlobalKey();
      final render = await pumpTerminal(
        tester,
        terminal,
        controller,
        boundary: boundary,
      );
      terminal.write('MMMM');
      controller.highlight(
        p1: terminal.buffer.createAnchor(0, 0),
        p2: terminal.buffer.createAnchor(3, 0),
        color: hitBackground,
        foreground: hitForeground,
      );
      controller.highlight(
        p1: terminal.buffer.createAnchor(2, 0),
        p2: terminal.buffer.createAnchor(4, 0),
        color: newerBackground,
        foreground: newerForeground,
      );
      await tester.pump();

      final pixels = await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary)
            .toImage();
        final bytes = await image.toByteData();
        return (image.width, bytes!);
      });
      final (width, bytes) = pixels!;
      Color pixel(Offset at) {
        final i = (at.dy.round() * width + at.dx.round()) * 4;
        return Color.fromARGB(
          bytes.getUint8(i + 3),
          bytes.getUint8(i),
          bytes.getUint8(i + 1),
          bytes.getUint8(i + 2),
        );
      }

      final cell = render.cellSize;
      Offset glyph(int x) =>
          render.localToGlobal(render.getOffset(CellOffset(x, 0))) +
          cell.center(Offset.zero);

      expect(pixel(glyph(1)), hitForeground);
      expect(pixel(glyph(2)), newerForeground);
      expect(pixel(glyph(3)), newerForeground);
    });

    // [seance fork] Rows of the main buffer index nothing on the alternate
    // screen: a highlight anchored there must not paint over vim.
    testWidgets('anchored in the other buffer is not painted',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final render = await pumpTerminal(tester, terminal, controller);
      terminal.write('MMMM');
      controller.highlight(
        p1: terminal.buffer.createAnchor(0, 0),
        p2: terminal.buffer.createAnchor(3, 0),
        color: hitBackground,
        foreground: hitForeground,
      );
      await tester.pump();
      expect(render, paints..rect(color: hitBackground));

      terminal.write('\x1b[?1049h'); // Switch to the alternate screen.
      terminal.write('MMMM');
      await tester.pump();

      expect(render, isNot(paints..rect(color: hitBackground)));
    });
  });
}
