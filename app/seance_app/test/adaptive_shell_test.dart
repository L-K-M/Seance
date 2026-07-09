import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/adaptive_shell.dart';

void main() {
  test('allocation preserves the terminal after oversized pane requests', () {
    final widths = allocateAdaptivePaneWidths(
      availableWidth: 960,
      requestedListWidth: AdaptiveShell.maximumListWidth,
      requestedUtilityWidth: AdaptiveShell.maximumUtilityWidth,
    )!;

    expect(widths.list, AdaptiveShell.minimumListWidth);
    expect(widths.terminal, AdaptiveShell.minimumTerminalWidth);
    expect(widths.utility, AdaptiveShell.minimumUtilityWidth);
    expect(
      widths.list +
          widths.terminal +
          widths.utility +
          AdaptiveShell.resizeHandleWidth * 2,
      closeTo(960, 0.01),
    );
  });

  test('allocation proportionally scales oversized panes', () {
    final widths = allocateAdaptivePaneWidths(
      availableWidth: 1100,
      requestedListWidth: AdaptiveShell.maximumListWidth,
      requestedUtilityWidth: AdaptiveShell.maximumUtilityWidth,
    )!;

    expect(widths.list, closeTo(256, 0.01));
    expect(widths.utility, closeTo(344, 0.01));
    expect(widths.terminal, AdaptiveShell.minimumTerminalWidth);
    expect(
      (widths.list - AdaptiveShell.minimumListWidth) /
          (widths.utility - AdaptiveShell.minimumUtilityWidth),
      closeTo(2 / 3, 0.01),
    );
  });

  Widget testLayout() {
    return const MaterialApp(
      home: AdaptivePaneLayout(
        listPane: ColoredBox(color: Colors.red),
        terminalPane: ColoredBox(color: Colors.green),
        utilityPane: ColoredBox(color: Colors.blue),
        narrowPane: ColoredBox(color: Colors.orange),
      ),
    );
  }

  Future<void> setWidth(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(testLayout());
  }

  for (final width in <double>[720, 800, 959]) {
    testWidgets('uses the narrow layout at ${width.toInt()} pixels', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await setWidth(tester, width);

      expect(find.byKey(AdaptivePaneLayout.narrowPaneKey), findsOneWidget);
      expect(find.byKey(AdaptivePaneLayout.terminalPaneKey), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in <double>[960, 1023, 1024, 1180]) {
    testWidgets('fits three usable panes at ${width.toInt()} pixels', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await setWidth(tester, width);

      final list = tester.getSize(find.byKey(AdaptivePaneLayout.listPaneKey));
      final terminal = tester.getSize(
        find.byKey(AdaptivePaneLayout.terminalPaneKey),
      );
      final utility = tester.getSize(
        find.byKey(AdaptivePaneLayout.utilityPaneKey),
      );

      expect(find.byKey(AdaptivePaneLayout.narrowPaneKey), findsNothing);
      expect(list.width, greaterThanOrEqualTo(AdaptiveShell.minimumListWidth));
      expect(
        terminal.width,
        greaterThanOrEqualTo(AdaptiveShell.minimumTerminalWidth),
      );
      expect(
        utility.width,
        greaterThanOrEqualTo(AdaptiveShell.minimumUtilityWidth),
      );
      expect(
        list.width +
            terminal.width +
            utility.width +
            AdaptiveShell.resizeHandleWidth * 2,
        closeTo(width, 0.01),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large dragged panes are clamped when the window shrinks', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await setWidth(tester, 1800);

    await tester.drag(
      find.byKey(AdaptivePaneLayout.listResizeHandleKey),
      const Offset(1000, 0),
    );
    await tester.pump();
    await tester.drag(
      find.byKey(AdaptivePaneLayout.utilityResizeHandleKey),
      const Offset(-1000, 0),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(AdaptivePaneLayout.listPaneKey)).width,
      AdaptiveShell.maximumListWidth,
    );
    expect(
      tester.getSize(find.byKey(AdaptivePaneLayout.utilityPaneKey)).width,
      AdaptiveShell.maximumUtilityWidth,
    );

    tester.view.physicalSize = const Size(960, 800);
    await tester.pump();

    final list = tester.getSize(find.byKey(AdaptivePaneLayout.listPaneKey));
    final terminal = tester.getSize(
      find.byKey(AdaptivePaneLayout.terminalPaneKey),
    );
    final utility = tester.getSize(
      find.byKey(AdaptivePaneLayout.utilityPaneKey),
    );
    expect(list.width, greaterThanOrEqualTo(AdaptiveShell.minimumListWidth));
    expect(
      terminal.width,
      greaterThanOrEqualTo(AdaptiveShell.minimumTerminalWidth),
    );
    expect(
      utility.width,
      greaterThanOrEqualTo(AdaptiveShell.minimumUtilityWidth),
    );
    expect(
      list.width +
          terminal.width +
          utility.width +
          AdaptiveShell.resizeHandleWidth * 2,
      closeTo(960, 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag deltas accumulate from live widths after a shrink', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await setWidth(tester, 1800);

    await tester.drag(
      find.byKey(AdaptivePaneLayout.listResizeHandleKey),
      const Offset(1000, 0),
    );
    await tester.pump();
    await tester.drag(
      find.byKey(AdaptivePaneLayout.utilityResizeHandleKey),
      const Offset(-1000, 0),
    );
    await tester.pump();
    tester.view.physicalSize = const Size(1180, 800);
    await tester.pump();

    final handle = find.byKey(AdaptivePaneLayout.listResizeHandleKey);
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(-25, 0));
    await tester.pump();
    final listBefore = tester
        .getSize(find.byKey(AdaptivePaneLayout.listPaneKey))
        .width;
    final terminalBefore = tester
        .getSize(find.byKey(AdaptivePaneLayout.terminalPaneKey))
        .width;
    final utilityBefore = tester
        .getSize(find.byKey(AdaptivePaneLayout.utilityPaneKey))
        .width;

    // Deliver two updates without a frame between them. Both must contribute.
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.up();
    await tester.pump();
    final listAfter = tester
        .getSize(find.byKey(AdaptivePaneLayout.listPaneKey))
        .width;
    final terminalAfter = tester
        .getSize(find.byKey(AdaptivePaneLayout.terminalPaneKey))
        .width;
    expect(listBefore - listAfter, closeTo(40, 0.01));
    expect(terminalAfter - terminalBefore, closeTo(40, 0.01));
    expect(
      tester.getSize(find.byKey(AdaptivePaneLayout.utilityPaneKey)).width,
      closeTo(utilityBefore, 0.01),
    );
  });
}
