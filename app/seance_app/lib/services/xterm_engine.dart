import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

/// A [TerminalEngine] backed by xterm.dart's [Terminal]. This is the concrete
/// v1 terminal; a future libghostty engine drops in behind the same interface
/// (see the proposal's M10). Bytes from SSH are written to the terminal;
/// keystrokes it emits are forwarded to SSH as bytes.
class XtermTerminalEngine implements TerminalEngine {
  final Terminal terminal;
  final StreamController<Uint8List> _input =
      StreamController<Uint8List>.broadcast();
  TerminalSize _size;

  XtermTerminalEngine({int maxLines = 10000, TerminalSize? initialSize})
      : terminal = Terminal(maxLines: maxLines),
        _size = initialSize ?? const TerminalSize(80, 24) {
    // Keystrokes / paste / device replies produced by the terminal go to SSH.
    terminal.onOutput = (data) {
      _input.add(Uint8List.fromList(utf8.encode(data)));
    };
  }

  /// Type [text] into the session as if the user typed it — used by the
  /// assistant's paste-to-prompt tool. The remote shell echoes it back so it
  /// appears at the prompt; because it contains no newline it is never executed.
  void injectInput(String text) {
    _input.add(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  void feed(Uint8List data) {
    // Terminals are byte streams; SSH may split UTF-8 across packets, so decode
    // leniently. (A future libghostty backend consumes bytes directly.)
    terminal.write(utf8.decode(data, allowMalformed: true));
  }

  @override
  Stream<Uint8List> get userInput => _input.stream;

  @override
  TerminalSize get size => _size;

  @override
  void resize(TerminalSize size) {
    _size = size;
    terminal.resize(size.cols, size.rows);
  }

  /// Rendered scrollback text (no escape codes) for LLM context — the last
  /// [maxLines] lines. Uses xterm's own buffer so it matches what the user sees.
  String recentText({int maxLines = 200}) {
    final all = terminal.buffer.getText().split('\n');
    final start = all.length > maxLines ? all.length - maxLines : 0;
    return all.sublist(start).join('\n').trimRight();
  }

  @override
  Future<void> dispose() async {
    await _input.close();
  }
}
