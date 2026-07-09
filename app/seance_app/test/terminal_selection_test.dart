import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  // Guards the terminal copy path: the right-click "Select all" sets a
  // selection on our controller, and Copy reads it back via
  // buffer.getText(selection). If the xterm API for either drifts, this breaks.
  testWidgets('select-all yields a selection that reads back as text',
      (tester) async {
    final terminal = Terminal(maxLines: 200);
    final controller = TerminalController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalView(terminal, controller: controller)),
      ),
    );
    await tester.pump();

    terminal.write('hello world\r\nsecond line\r\n');
    await tester.pump();

    // Mirror _SessionViewState._selectAll.
    final buffer = terminal.buffer;
    controller.setSelection(
      buffer.createAnchor(0, buffer.height - terminal.viewHeight),
      buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
    );

    final selection = controller.selection;
    expect(selection, isNotNull);
    final text = terminal.buffer.getText(selection);
    expect(text, contains('hello world'));
    expect(text, contains('second line'));
  });

  // Guards the double-click path: we reach the render object through a
  // GlobalKey<TerminalViewState> and call selectWord (xterm's public API).
  testWidgets('selectWord via the render object selects a single word',
      (tester) async {
    final terminal = Terminal(maxLines: 100);
    final controller = TerminalController();
    final key = GlobalKey<TerminalViewState>();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, key: key, controller: controller),
        ),
      ),
    );
    await tester.pump();
    terminal.write('hello world\r\n');
    await tester.pump();

    // Click near the start of the first line ("hello").
    key.currentState!.renderTerminal.selectWord(const Offset(6, 6));

    final selection = controller.selection;
    expect(selection, isNotNull);
    final word = terminal.buffer.getText(selection).trim();
    expect(word, isNotEmpty);
    expect(word, isNot(contains(' '))); // a word, not the whole line
  });
}
