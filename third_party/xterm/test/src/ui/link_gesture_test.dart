import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  final url = Uri.parse('https://example.com');
  // Outlast the fork's 400 ms multi-click window between independent gestures.
  const gestureTimeout = Duration(milliseconds: 600);

  Future<Offset> pumpTerminal(
    WidgetTester tester,
    Terminal terminal,
    TerminalController controller,
    List<Uri> opened,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: TerminalView(
              terminal,
              controller: controller,
              onLinkTap: opened.add,
            ),
          ),
        ),
      ),
    );
    terminal.write(url.toString());
    await tester.pump();
    final render = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    return render.localToGlobal(
      render.getOffset(const CellOffset(5, 0)) +
          Offset(render.cellSize.width / 2, render.cellSize.height / 2),
    );
  }

  for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('$platform uses its link modifier, not plain clicks', (
      tester,
    ) async {
      final terminal = Terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      final opened = <Uri>[];
      final point = await pumpTerminal(tester, terminal, controller, opened);

      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(gestureTimeout);
      expect(opened, isEmpty);

      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump(gestureTimeout);
      expect(opened, [url]);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('touch opens links; double-click, shift-click and drag select', (
    tester,
  ) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final point = await pumpTerminal(tester, terminal, controller, opened);

    await tester.tapAt(point);
    await tester.pump(gestureTimeout);
    expect(opened, [url]);
    opened.clear();

    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.pump(gestureTimeout);
    expect(controller.selection, isNotNull);
    expect(opened, isEmpty);
    controller.clearSelection();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(point + const Offset(60, 0),
        kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(gestureTimeout);
    expect(controller.selection, isNotNull);
    expect(terminal.buffer.getText(controller.selection), isNotEmpty);
    controller.clearSelection();

    await tester.dragFrom(
      point,
      const Offset(60, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(gestureTimeout);
    expect(opened, isEmpty);
    expect(controller.selection, isNotNull);
  });

  const mouseReportingModes = {
    'click-only': ('\x1b[?9h', 1),
    'press/release': ('\x1b[?1000h', 2),
  };
  const sgrMouse = '\x1b[?1006h';
  for (final mode in mouseReportingModes.entries) {
    testWidgets('${mode.key} mouse reporting retains click ownership',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      final opened = <Uri>[];
      final point = await pumpTerminal(tester, terminal, controller, opened);
      terminal.write('${mode.value.$1}$sgrMouse');
      final output = <String>[];
      terminal.onOutput = output.add;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(gestureTimeout);
      expect(opened, isEmpty);
      expect(output, hasLength(mode.value.$2));
      expect(output.every((event) => event.startsWith('\x1b[<')), isTrue);
    });
  }

  for (final update in {
    'mouse reporting': '\x1b[?1000h',
    'rewritten output': '\r\x1b[2Kplain text',
  }.entries) {
    testWidgets('hover clears after ${update.key}', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      final opened = <Uri>[];
      final point = await pumpTerminal(tester, terminal, controller, opened);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(point);
      await tester.pump();

      terminal.write(update.value);
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widgetList<MouseRegion>(find.byType(MouseRegion))
            .any((region) => region.cursor == SystemMouseCursors.click),
        isFalse,
      );
      // Moving again must not advertise an inactive or erased link either.
      await mouse.moveTo(point + const Offset(1, 0));
      await tester.pump();
      expect(
        tester
            .widgetList<MouseRegion>(find.byType(MouseRegion))
            .any((region) => region.cursor == SystemMouseCursors.click),
        isFalse,
      );
      await mouse.removePointer();
    });
  }

  testWidgets('hover signals links without opening them', (tester) async {
    final terminal = Terminal();
    final controller = TerminalController();
    addTearDown(controller.dispose);
    final opened = <Uri>[];
    final point = await pumpTerminal(tester, terminal, controller, opened);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(point);
    await tester.pump();
    expect(
      tester
          .widgetList<MouseRegion>(find.byType(MouseRegion))
          .any((region) => region.cursor == SystemMouseCursors.click),
      isTrue,
    );
    expect(opened, isEmpty);
    await mouse.removePointer();
  });
}
