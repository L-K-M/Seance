import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/xterm_engine.dart';

void main() {
  test('pendingInput tracks typing, backspace, submit, and ignores escapes',
      () {
    final del = String.fromCharCode(0x7f); // backspace / DEL
    final esc = String.fromCharCode(0x1b); // start of an escape sequence
    final ctrlU = String.fromCharCode(0x15); // kill line
    final cr = String.fromCharCode(0x0d); // Enter

    final e = XtermTerminalEngine();
    expect(e.pendingInput, '');

    e.injectInput('ls -l');
    expect(e.pendingInput, 'ls -l');

    e.injectInput(del);
    expect(e.pendingInput, 'ls -');

    e.injectInput('a');
    expect(e.pendingInput, 'ls -a');

    e.injectInput('$esc[C'); // arrow-right escape sequence: ignored
    expect(e.pendingInput, 'ls -a');

    e.injectInput(cr); // Enter submits — line clears
    expect(e.pendingInput, '');

    e.injectInput('foo');
    e.injectInput(ctrlU);
    expect(e.pendingInput, '');
  });
}
