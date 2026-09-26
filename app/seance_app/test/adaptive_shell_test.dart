import 'dart:ui' show SemanticsAction, SemanticsActionEvent;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/adaptive_shell.dart';

void main() {
  Future<void> pumpResizable(
    WidgetTester tester, {
    TextDirection direction = TextDirection.ltr,
    double width = 1800,
    double list = AdaptiveShell.defaultListWidth,
    double utility = AdaptiveShell.defaultUtilityWidth,
    void Function(double, double)? onChanged,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: direction,
          child: AdaptivePaneLayout(
            initialListWidth: list,
            initialUtilityWidth: utility,
            onPaneWidthsChanged: onChanged,
            listPane: const SizedBox.expand(),
            terminalPane: const SizedBox.expand(),
            utilityPane: const SizedBox.expand(),
            narrowPane: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  double paneWidth(WidgetTester tester, Key key) =>
      tester.getSize(find.byKey(key)).width;

  Future<void> focusHandle(WidgetTester tester, Key key) async {
    final handle = find.byKey(key);
    expect(
      find.descendant(of: handle, matching: find.byType(Focus)),
      findsOneWidget,
    );
    Focus.of(
      tester.element(
        find.descendant(of: handle, matching: find.byType(GestureDetector)),
      ),
    ).requestFocus();
    await tester.pump();
  }

  for (final direction in TextDirection.values) {
    testWidgets('keyboard resize follows physical arrows in $direction', (
      tester,
    ) async {
      final reports = <(double, double)>[];
      await pumpResizable(
        tester,
        direction: direction,
        onChanged: (list, utility) => reports.add((list, utility)),
      );
      final sign = direction == TextDirection.ltr ? 1 : -1;
      await focusHandle(tester, AdaptivePaneLayout.listResizeHandleKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        paneWidth(tester, AdaptivePaneLayout.listPaneKey),
        300 + sign * 16,
      );
      expect(reports, [(300.0 + sign * 16, 340.0)]);
      await focusHandle(tester, AdaptivePaneLayout.utilityResizeHandleKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        paneWidth(tester, AdaptivePaneLayout.utilityPaneKey),
        340 - sign * 16,
      );
      expect(reports.length, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('successive keyboard steps accumulate before a new frame', (
    tester,
  ) async {
    final reports = <(double, double)>[];
    await pumpResizable(
      tester,
      onChanged: (list, utility) => reports.add((list, utility)),
    );
    await focusHandle(tester, AdaptivePaneLayout.listResizeHandleKey);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(paneWidth(tester, AdaptivePaneLayout.listPaneKey), 332);
    expect(reports, [(316.0, 340.0), (332.0, 340.0)]);
  });

  testWidgets('a rapid direction reversal uses the current bound', (
    tester,
  ) async {
    await pumpResizable(tester, list: 480);
    await focusHandle(tester, AdaptivePaneLayout.listResizeHandleKey);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(paneWidth(tester, AdaptivePaneLayout.listPaneKey), 480);
  });

  testWidgets('screen reader adjustments name and resize the owned pane', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpResizable(tester);
      var node = tester.getSemantics(
        find.bySemanticsLabel('Resize server list'),
      );
      expect(node.getSemanticsData().flagsCollection.isSlider, isTrue);
      expect(node.getSemanticsData().value, '300 pixels');
      expect(node.getSemanticsData().increasedValue, '316 pixels');
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.increase,
          nodeId: node.id,
          viewId: tester.view.viewId,
        ),
      );
      await tester.pump();
      expect(paneWidth(tester, AdaptivePaneLayout.listPaneKey), 316);
      node = tester.getSemantics(find.bySemanticsLabel('Resize utility panel'));
      expect(node.getSemanticsData().value, '340 pixels');
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.increase,
          nodeId: node.id,
          viewId: tester.view.viewId,
        ),
      );
      await tester.pump();
      expect(paneWidth(tester, AdaptivePaneLayout.utilityPaneKey), 356);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('adjustment actions respect both pane bounds', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpResizable(tester, list: 480, utility: 260);
      var node = tester.getSemantics(
        find.bySemanticsLabel('Resize server list'),
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.increase),
        isFalse,
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.decrease),
        isTrue,
      );
      node = tester.getSemantics(find.bySemanticsLabel('Resize utility panel'));
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.decrease),
        isFalse,
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.increase),
        isTrue,
      );
      await focusHandle(tester, AdaptivePaneLayout.listResizeHandleKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(paneWidth(tester, AdaptivePaneLayout.listPaneKey), 480);
      await focusHandle(tester, AdaptivePaneLayout.utilityResizeHandleKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(paneWidth(tester, AdaptivePaneLayout.utilityPaneKey), 260);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('keyboard resizing starts at visible width after a shrink', (
    tester,
  ) async {
    await pumpResizable(tester, list: 480, utility: 680);
    tester.view.physicalSize = const Size(1180, 800);
    await tester.pump();
    final before = paneWidth(tester, AdaptivePaneLayout.listPaneKey);
    await focusHandle(tester, AdaptivePaneLayout.listResizeHandleKey);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(paneWidth(tester, AdaptivePaneLayout.listPaneKey), lessThan(before));
    expect(
      paneWidth(tester, AdaptivePaneLayout.terminalPaneKey),
      greaterThanOrEqualTo(AdaptiveShell.minimumTerminalWidth),
    );
    tester.view.physicalSize = const Size(1800, 800);
    await tester.pump();
    expect(paneWidth(tester, AdaptivePaneLayout.utilityPaneKey), 680);
  });

  testWidgets('Tab reaches both dividers and paints their focus cue', (
    tester,
  ) async {
    await pumpResizable(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    for (final key in [
      AdaptivePaneLayout.listResizeHandleKey,
      AdaptivePaneLayout.utilityResizeHandleKey,
    ]) {
      final handle = find.byKey(key);
      final line = tester.widget<Container>(
        find.descendant(of: handle, matching: find.byType(Container)),
      );
      expect(line.constraints!.maxWidth, 3);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
  });

  testWidgets('announced adjustment matches reallocation after shrink', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpResizable(tester, width: 1180, list: 480, utility: 680);
      final node = tester.getSemantics(
        find.bySemanticsLabel('Resize server list'),
      );
      final announced = node.getSemanticsData().decreasedValue;
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.decrease,
          nodeId: node.id,
          viewId: tester.view.viewId,
        ),
      );
      await tester.pump();
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Resize server list'))
            .getSemanticsData()
            .value,
        announced,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('RTL pointer drag follows the visible divider', (tester) async {
    await pumpResizable(tester, direction: TextDirection.rtl);
    await tester.drag(
      find.byKey(AdaptivePaneLayout.listResizeHandleKey),
      const Offset(60, 0),
    );
    await tester.pump();
    expect(paneWidth(tester, AdaptivePaneLayout.listPaneKey), 240);
    await tester.drag(
      find.byKey(AdaptivePaneLayout.utilityResizeHandleKey),
      const Offset(60, 0),
    );
    await tester.pump();
    expect(paneWidth(tester, AdaptivePaneLayout.utilityPaneKey), 400);
  });

  test('breakpoint and allocation minimums stay aligned', () {
    expect(
      AdaptiveShell.breakpoint,
      AdaptiveShell.minimumListWidth +
          AdaptiveShell.minimumTerminalWidth +
          AdaptiveShell.minimumUtilityWidth +
          AdaptiveShell.resizeHandleWidth * 2,
    );

    final widths = allocateAdaptivePaneWidths(
      availableWidth: AdaptiveShell.breakpoint,
      requestedListWidth: 0,
      requestedUtilityWidth: 0,
    )!;
    expect(widths.list, AdaptiveShell.minimumListWidth);
    expect(widths.terminal, AdaptiveShell.minimumTerminalWidth);
    expect(widths.utility, AdaptiveShell.minimumUtilityWidth);
  });

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
    await gesture.up();
    await tester.pump();
  });

  testWidgets('sibling max preference returns after drag and regrow', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await setWidth(tester, 1800);

    await tester.drag(
      find.byKey(AdaptivePaneLayout.utilityResizeHandleKey),
      const Offset(-1000, 0),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(AdaptivePaneLayout.utilityPaneKey)).width,
      AdaptiveShell.maximumUtilityWidth,
    );

    tester.view.physicalSize = const Size(1180, 800);
    await tester.pump();
    expect(
      tester.getSize(find.byKey(AdaptivePaneLayout.utilityPaneKey)).width,
      lessThan(AdaptiveShell.maximumUtilityWidth),
    );
    await tester.drag(
      find.byKey(AdaptivePaneLayout.listResizeHandleKey),
      const Offset(-40, 0),
    );
    await tester.pump();

    tester.view.physicalSize = const Size(1800, 800);
    await tester.pump();
    expect(
      tester.getSize(find.byKey(AdaptivePaneLayout.utilityPaneKey)).width,
      AdaptiveShell.maximumUtilityWidth,
    );
  });

  testWidgets('initial pane widths from persisted values are rendered', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1800, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      const MaterialApp(
        home: AdaptivePaneLayout(
          initialListWidth: 420,
          initialUtilityWidth: 520,
          listPane: ColoredBox(color: Colors.red),
          terminalPane: ColoredBox(color: Colors.green),
          utilityPane: ColoredBox(color: Colors.blue),
          narrowPane: ColoredBox(color: Colors.orange),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(AdaptivePaneLayout.listPaneKey)).width,
      420,
    );
    expect(
      tester.getSize(find.byKey(AdaptivePaneLayout.utilityPaneKey)).width,
      520,
    );
  });

  testWidgets('a finished resize drag reports both requested widths', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1800, 800);
    tester.view.devicePixelRatio = 1;
    final reported = <(double, double)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AdaptivePaneLayout(
          onPaneWidthsChanged: (list, utility) => reported.add((list, utility)),
          listPane: const ColoredBox(color: Colors.red),
          terminalPane: const ColoredBox(color: Colors.green),
          utilityPane: const ColoredBox(color: Colors.blue),
          narrowPane: const ColoredBox(color: Colors.orange),
        ),
      ),
    );

    await tester.drag(
      find.byKey(AdaptivePaneLayout.listResizeHandleKey),
      const Offset(60, 0),
    );
    await tester.pump();
    expect(reported, [
      (AdaptiveShell.defaultListWidth + 60, AdaptiveShell.defaultUtilityWidth),
    ]);

    await tester.drag(
      find.byKey(AdaptivePaneLayout.utilityResizeHandleKey),
      const Offset(-80, 0),
    );
    await tester.pump();
    expect(reported.last, (
      AdaptiveShell.defaultListWidth + 60,
      AdaptiveShell.defaultUtilityWidth + 80,
    ));
  });
}
