import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_core/seance_core.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:xterm/xterm.dart';

void main() {
  // Regression: the xterm widget owns the terminal size (autoResize). When it
  // resizes, `terminal.onResize` fires and the app forwards the new size to the
  // remote PTY. That handler must NOT resize the terminal again — doing so
  // re-fires onResize and recurses until the stack overflows, which left the
  // grid stuck at its initial 80 columns (blank space on wide screens, cut-off
  // text on narrow ones).
  testWidgets('autoResize reaches the remote once, without recursing',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final engine = XtermTerminalEngine();
    final remote = <TerminalSize>[];
    // Mirror SshSession's wiring exactly.
    engine.terminal.onResize = (w, h, pw, ph) {
      engine.resize(TerminalSize(w, h)); // engine bookkeeping — must not recurse
      remote.add(TerminalSize(w, h)); // stand-in for shell.resizeTerminal
    };

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TerminalView(engine.terminal))),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // The grid fitted to the widget, the remote was told, and everyone agrees.
    expect(remote, isNotEmpty);
    expect(engine.terminal.viewWidth, greaterThan(1));
    expect(engine.size.cols, engine.terminal.viewWidth);
    expect(remote.last.cols, engine.terminal.viewWidth);
  });
}
