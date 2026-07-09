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
}
