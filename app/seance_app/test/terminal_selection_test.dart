import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  // Guards the terminal copy path: the right-click "Select all" sets a
  // selection on our controller, and Copy reads it back via
  // buffer.getText(selection). If the xterm API for either drifts, this breaks.
  testWidgets('select-all includes scrollback, not just the visible screen',
      (tester) async {
    final terminal = Terminal(maxLines: 500);
    final controller = TerminalController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalView(terminal, controller: controller)),
      ),
    );
    await tester.pump();

    // Write far more lines than fit on screen, so early lines scroll off.
    for (var i = 0; i < 100; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pump();

    final buffer = terminal.buffer;
    // Sanity: there really is scrollback (more lines than the visible page).
    expect(buffer.height, greaterThan(terminal.viewHeight));

    // Mirror terminalSelectAll: anchor at row 0 so scrollback is included.
    controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
    );
    final text = terminal.buffer.getText(controller.selection);
    expect(text, contains('line 0')); // earliest line, scrolled off screen
    expect(text, contains('line 99')); // latest line

    // The old behavior (start at the top of the visible page) would have
    // dropped the scrolled-off lines.
    controller.setSelection(
      buffer.createAnchor(0, buffer.height - terminal.viewHeight),
      buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
    );
    expect(terminal.buffer.getText(controller.selection), isNot(contains('line 0')));
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
