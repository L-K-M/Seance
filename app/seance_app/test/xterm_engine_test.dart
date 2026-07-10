import 'dart:convert';
import 'dart:typed_data';

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

  test('onCommand fires with the completed line on Enter, not on interrupt', () {
    final commands = <String>[];
    final e = XtermTerminalEngine(onCommand: commands.add);

    e.injectInput('echo hi');
    e.injectInput('\r');
    expect(commands, ['echo hi']);

    // A line abandoned with Ctrl-C is not reported as a command.
    e.injectInput('secret');
    e.sendKey([0x03]); // Ctrl-C
    expect(e.pendingInput, '');
    expect(commands, ['echo hi']);
  });

  test('sendKey forwards raw bytes to the session input', () async {
    final e = XtermTerminalEngine();
    final got = <int>[];
    final sub = e.userInput.listen(got.addAll);
    e.sendKey([0x1b, 0x5b, 0x41]); // up arrow
    await Future<void>.delayed(Duration.zero);
    expect(got, [0x1b, 0x5b, 0x41]);
    await sub.cancel();
  });

  test('an armed Ctrl converts the next typed char to its control code', () async {
    final e = XtermTerminalEngine();
    final got = <int>[];
    final sub = e.userInput.listen(got.addAll);

    e.toggleCtrl();
    expect(e.ctrlArmed.value, isTrue);

    // Simulate the soft keyboard producing 'c'.
    e.terminal.onOutput!('c');
    await Future<void>.delayed(Duration.zero);

    expect(got, [0x03]); // Ctrl-C
    expect(e.ctrlArmed.value, isFalse); // one-shot: disarms after one key
    await sub.cancel();
  });

  test(
    'feed preserves UTF-8 characters split at every byte boundary',
    () async {
      for (final character in ['¢', '€', '😀']) {
        final bytes = utf8.encode(character);
        for (var split = 1; split < bytes.length; split++) {
          final e = XtermTerminalEngine();

          e.feed(Uint8List.fromList(bytes.sublist(0, split)));
          expect(
            e.recentText(),
            isEmpty,
            reason: '$character emitted before split $split completed',
          );

          e.feed(Uint8List.fromList(bytes.sublist(split)));
          expect(
            e.recentText(),
            character,
            reason: '$character failed at byte boundary $split',
          );
          await e.dispose();
        }
      }
    },
  );

  test(
    'feed replaces malformed bytes and flushes an incomplete character',
    () async {
      final e = XtermTerminalEngine();

      e.feed(Uint8List.fromList([0x61, 0xff, 0x62]));
      expect(e.recentText(), 'a\uFFFDb');

      e.feed(Uint8List.fromList([0xe2, 0x82]));
      expect(e.recentText(), 'a\uFFFDb');
      await e.dispose();
      expect(e.recentText(), 'a\uFFFDb\uFFFD');
    },
  );
  test('dispose is idempotent', () async {
    // With per-server tabs, closeTab/reconnect can dispose an engine that a
    // closing SshSession also disposes. A second dispose must not re-dispose
    // the ValueNotifier (a debug assertion) or throw.
    final e = XtermTerminalEngine();
    await e.dispose();
    await e.dispose(); // no throw
  });

  test('OSC 7 reports a decoded absolute working directory', () async {
    final e = XtermTerminalEngine();

    e.feed(
      Uint8List.fromList(
        utf8.encode('\x1b]7;file://server/home/test/My%20Files\x07'),
      ),
    );

    expect(e.workingDirectory.value, '/home/test/My Files');
    await e.dispose();
  });

  test('malformed and relative OSC 7 paths are ignored', () async {
    final e = XtermTerminalEngine();

    e.feed(Uint8List.fromList(utf8.encode('\x1b]7;not-a-file-uri\x07')));
    expect(e.workingDirectory.value, isNull);

    e.feed(Uint8List.fromList(utf8.encode('\x1b]7;file:relative\x07')));
    expect(e.workingDirectory.value, isNull);
    await e.dispose();
  });

  test('OSC 0 preserves the shell title for cwd fallback', () async {
    final e = XtermTerminalEngine();

    e.feed(Uint8List.fromList(
      utf8.encode('\x1b]0;root@server: ~/docker\x07'),
    ));

    expect(e.terminalTitle.value, 'root@server: ~/docker');
    await e.dispose();
  });
}
