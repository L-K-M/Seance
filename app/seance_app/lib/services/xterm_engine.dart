import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

  /// Fired with each completed command line the user submits (Enter). Best
  /// effort — see [_pendingInput] — and used to suggest frequently-run
  /// commands as snippets. Never leaves the device on its own.
  final void Function(String command)? onCommand;

  // A best-effort reconstruction of the current, not-yet-submitted input line,
  // built from the keystrokes the user sends. Used to prefill the command
  // generator. It's an approximation — full readline editing (history, cursor
  // moves) isn't modelled — but covers the common "typed a partial command"
  // case.
  String _pendingInput = '';

  /// One-shot Ctrl modifier for the on-screen key row (mobile has no physical
  /// Ctrl): when armed, the next character the soft keyboard produces is sent
  /// as its control code (e.g. `c` → 0x03). Consumed after one keystroke.
  final ValueNotifier<bool> ctrlArmed = ValueNotifier<bool>(false);

  XtermTerminalEngine(
      {int maxLines = 10000, TerminalSize? initialSize, this.onCommand})
      : terminal = Terminal(maxLines: maxLines),
        _size = initialSize ?? const TerminalSize(80, 24) {
    // Keystrokes / paste / device replies produced by the terminal go to SSH.
    terminal.onOutput = (data) {
      final out = _applyCtrl(data);
      _trackPending(out);
      _input.add(Uint8List.fromList(utf8.encode(out)));
    };
  }

  /// The current, not-yet-submitted input line (best effort).
  String get pendingInput => _pendingInput;

  /// If the Ctrl modifier is armed, rewrite the first character of [data] to its
  /// control code and disarm. Escape sequences (device replies, function keys)
  /// start with ESC and are passed through unchanged.
  String _applyCtrl(String data) {
    if (!ctrlArmed.value) return data;
    ctrlArmed.value = false;
    if (data.isEmpty || data.codeUnitAt(0) == 0x1b) return data;
    final code = _controlCode(data.codeUnitAt(0));
    if (code == null) return data;
    return String.fromCharCode(code) + data.substring(1);
  }

  /// Map a printable ASCII key to the control code Ctrl+key would produce, or
  /// null if there's no sensible mapping. Covers letters (Ctrl-C, Ctrl-D, …)
  /// and the `@ [ \ ] ^ _` / space group.
  static int? _controlCode(int c) {
    if (c >= 0x61 && c <= 0x7a) return c - 0x60; // a-z → 1..26
    if (c >= 0x41 && c <= 0x5a) return c - 0x40; // A-Z → 1..26
    if (c == 0x20 || c == 0x40) return 0; // space / @ → NUL
    if (c >= 0x5b && c <= 0x5f) return c - 0x40; // [ \ ] ^ _ → 27..31
    return null;
  }

  /// Fold one outbound chunk into [_pendingInput]. Escape sequences (arrow
  /// keys, device replies) arrive as their own chunk starting with ESC and are
  /// ignored; Enter clears the line (and reports the command); backspace/kill
  /// trim it.
  void _trackPending(String data) {
    if (data.isEmpty || data.codeUnitAt(0) == 0x1b) return;
    for (final r in data.runes) {
      if (r == 0x0d || r == 0x0a) {
        _submitPending();
      } else if (r == 0x7f || r == 0x08) {
        if (_pendingInput.isNotEmpty) {
          _pendingInput =
              _pendingInput.substring(0, _pendingInput.length - 1);
        }
      } else if (r == 0x15 || r == 0x03) {
        _pendingInput = ''; // Ctrl-U (kill line) / Ctrl-C (interrupt)
      } else if (r >= 0x20) {
        _pendingInput += String.fromCharCode(r);
      }
    }
  }

  /// A line was submitted: report it (for command suggestions) and reset.
  void _submitPending() {
    final line = _pendingInput.trim();
    if (line.isNotEmpty) onCommand?.call(line);
    _pendingInput = '';
  }

  /// Type [text] into the session as if the user typed it — used by the
  /// assistant's paste-to-prompt tool. The remote shell echoes it back so it
  /// appears at the prompt; because it contains no newline it is never executed.
  void injectInput(String text) {
    _trackPending(text);
    _input.add(Uint8List.fromList(utf8.encode(text)));
  }

  /// Send raw [bytes] to the session — used by the on-screen key row for keys
  /// the soft keyboard lacks (Tab, arrows, Esc, Ctrl-C, …). Unlike
  /// [injectInput] this is allowed to carry control bytes such as Enter.
  void sendKey(List<int> bytes) {
    _trackPending(utf8.decode(bytes, allowMalformed: true));
    _input.add(Uint8List.fromList(bytes));
  }

  /// Toggle the one-shot Ctrl modifier (armed by the key row's Ctrl button).
  void toggleCtrl() => ctrlArmed.value = !ctrlArmed.value;

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
    // Only record the size — the xterm widget owns the on-screen terminal size
    // (autoResize) and calls terminal.resize itself, which is what fires
    // terminal.onResize. Since our onResize handler routes back here (to forward
    // the size to the remote PTY), calling terminal.resize again would re-fire
    // onResize and recurse until the stack overflows. So this is bookkeeping
    // only, mirroring HeadlessTerminalEngine.
    _size = size;
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
    ctrlArmed.dispose();
    await _input.close();
  }
}
