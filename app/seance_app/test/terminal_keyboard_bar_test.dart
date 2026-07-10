import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/terminal_keyboard_bar.dart';

void main() {
  late XtermTerminalEngine engine;
  late List<Uint8List> output;
  late StreamSubscription<Uint8List> subscription;

  setUp(() {
    engine = XtermTerminalEngine();
    output = [];
    subscription = engine.userInput.listen(output.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await engine.dispose();
  });

  Future<void> pumpBar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TerminalKeyboardBar(engine: engine),
          ),
        ),
      ),
    );
  }

  Future<List<int>> tapKey(WidgetTester tester, String semanticsLabel) async {
    output.clear();
    await tester.tap(find.bySemanticsLabel(semanticsLabel));
    await tester.pump();
    return output.expand((chunk) => chunk).toList();
  }

  testWidgets('cursor controls emit normal cursor sequences', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpBar(tester);

    expect(await tapKey(tester, 'Left arrow'), [0x1b, 0x5b, 0x44]);
    expect(await tapKey(tester, 'Up arrow'), [0x1b, 0x5b, 0x41]);
    expect(await tapKey(tester, 'Down arrow'), [0x1b, 0x5b, 0x42]);
    expect(await tapKey(tester, 'Right arrow'), [0x1b, 0x5b, 0x43]);
    expect(await tapKey(tester, 'Home'), [0x1b, 0x5b, 0x48]);
    expect(await tapKey(tester, 'End'), [0x1b, 0x5b, 0x46]);
    semantics.dispose();
  });

  testWidgets('cursor controls emit application cursor sequences', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpBar(tester);
    engine.feed(Uint8List.fromList([0x1b, 0x5b, 0x3f, 0x31, 0x68]));
    expect(engine.terminal.cursorKeysMode, isTrue);

    expect(await tapKey(tester, 'Left arrow'), [0x1b, 0x4f, 0x44]);
    expect(await tapKey(tester, 'Up arrow'), [0x1b, 0x4f, 0x41]);
    expect(await tapKey(tester, 'Down arrow'), [0x1b, 0x4f, 0x42]);
    expect(await tapKey(tester, 'Right arrow'), [0x1b, 0x4f, 0x43]);
    expect(await tapKey(tester, 'Home'), [0x1b, 0x4f, 0x48]);
    expect(await tapKey(tester, 'End'), [0x1b, 0x4f, 0x46]);
    semantics.dispose();
  });

  testWidgets('cursor keys leave armed Ctrl and pending input unchanged', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpBar(tester);
    engine.injectInput('echo');
    await tester.pump();
    engine.toggleCtrl();

    expect(await tapKey(tester, 'Left arrow'), [0x1b, 0x5b, 0x44]);
    expect(engine.ctrlArmed.value, isTrue);
    expect(engine.pendingInput, 'echo');

    output.clear();
    engine.terminal.onOutput!('c');
    await tester.pump();
    expect(output.expand((chunk) => chunk).toList(), [0x03]);
    expect(engine.ctrlArmed.value, isFalse);
    semantics.dispose();
  });

  testWidgets('raw control, page, and punctuation keys stay unchanged', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpBar(tester);

    expect(await tapKey(tester, 'Escape'), [0x1b]);
    expect(await tapKey(tester, 'Tab'), [0x09]);
    expect(await tapKey(tester, 'Control C'), [0x03]);
    expect(await tapKey(tester, 'Page up'), [0x1b, 0x5b, 0x35, 0x7e]);
    expect(await tapKey(tester, 'Page down'), [0x1b, 0x5b, 0x36, 0x7e]);
    expect(await tapKey(tester, 'Pipe'), utf8.encode('|'));
    expect(await tapKey(tester, 'Slash'), utf8.encode('/'));
    expect(await tapKey(tester, 'Hyphen'), utf8.encode('-'));
    expect(await tapKey(tester, 'Tilde'), utf8.encode('~'));
    semantics.dispose();
  });

  testWidgets('key controls expose useful semantics and icon tooltips', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpBar(tester);

    for (final label in [
      'Escape',
      'Tab',
      'Control modifier',
      'Control C',
      'Left arrow',
      'Up arrow',
      'Down arrow',
      'Right arrow',
      'Home',
      'End',
      'Page up',
      'Page down',
      'Pipe',
      'Slash',
      'Hyphen',
      'Tilde',
      'Hide keyboard',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget);
    }

    expect(find.byTooltip('Left arrow'), findsOneWidget);
    expect(find.byTooltip('Up arrow'), findsOneWidget);
    expect(find.byTooltip('Down arrow'), findsOneWidget);
    expect(find.byTooltip('Right arrow'), findsOneWidget);
    expect(find.byTooltip('Hide keyboard'), findsOneWidget);
    semantics.dispose();
  });
}
