import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:xterm/xterm.dart';

void main() {
  test(
    'pendingInput tracks typing, backspace, submit, and ignores escapes',
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
    },
  );

  test(
    'onCommand fires with the completed line on Enter, not on interrupt',
    () {
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
    },
  );

  test('sendKey forwards raw bytes to the session input', () async {
    final e = XtermTerminalEngine();
    final got = <int>[];
    final sub = e.userInput.listen(got.addAll);
    e.sendKey([0x1b, 0x5b, 0x41]); // up arrow
    await Future<void>.delayed(Duration.zero);
    expect(got, [0x1b, 0x5b, 0x41]);
    await sub.cancel();
  });

  test(
    'an armed Ctrl converts the next typed char to its control code',
    () async {
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
    },
  );

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

  test(
    'recentText includes the last display column of the final row',
    () async {
      final e = XtermTerminalEngine();
      addTearDown(e.dispose);
      e.terminal.resize(6, 2);
      e.feed(Uint8List.fromList(utf8.encode('first\r\n123456')));

      expect(e.recentText(maxLines: 1), '123456');

      e.feed(Uint8List.fromList(utf8.encode('\r1234界')));
      expect(e.recentText(maxLines: 1), '1234界');
    },
  );

  test(
    'device replies preserve an empty prompt and the armed Ctrl key',
    () async {
      final e = XtermTerminalEngine();
      addTearDown(e.dispose);
      final output = <int>[];
      final subscription = e.userInput.listen(output.addAll);
      addTearDown(subscription.cancel);
      e.toggleCtrl();
      e.feed(
        Uint8List.fromList(
          utf8.encode(
            '\x1b]1337;ShellIntegrationVersion=1;bash\x07'
            '\x1b]133;A\x07\x1b[5n\x1b]133;B\x07',
          ),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(utf8.decode(output), '\x1b[0n');
      expect(e.ctrlArmed.value, isTrue);
      expect(
        e.shellIntegration.value.phase,
        TerminalPromptPhase.acceptingInput,
      );
      expect(e.shellIntegration.value.inputSincePrompt, isFalse);
      expect(
        e.stageChangeDirectory('/srv/project'),
        TerminalStageResult.staged,
      );
    },
  );

  test(
    'late SSH output and a completed paste are harmless after disposal',
    () async {
      final e = XtermTerminalEngine();
      await e.dispose();

      expect(
        () => e.feed(
          Uint8List.fromList(
            utf8.encode('\x1b]0;late title\x07\x1b[6nlate output'),
          ),
        ),
        returnsNormally,
      );
      expect(() => e.terminal.paste('late clipboard text'), returnsNormally);
      expect(e.recentText(), isEmpty);
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

    e.feed(Uint8List.fromList(utf8.encode('\x1b]0;root@server: ~/docker\x07')));

    expect(e.terminalTitle.value, 'root@server: ~/docker');
    await e.dispose();
  });

  test('OSC 133 prompt metadata gates reviewed directory staging', () async {
    final e = XtermTerminalEngine();
    final input = <int>[];
    final subscription = e.userInput.listen(input.addAll);

    expect(
      e.stageChangeDirectory('/srv/project'),
      TerminalStageResult.shellIntegrationRequired,
    );
    e.feed(
      Uint8List.fromList(
        utf8.encode(
          '\x1b]1337;ShellIntegrationVersion=1;bash\x07'
          '\x1b]133;A\x07\x1b]133;B\x07',
        ),
      ),
    );

    expect(
      e.stageChangeDirectory("/srv/O'Reilly;\$(false)"),
      TerminalStageResult.staged,
    );
    await Future<void>.delayed(Duration.zero);
    final staged = utf8.decode(input);
    expect(staged, "cd '/srv/O'\"'\"'Reilly;\$(false)'");
    expect(staged, isNot(contains('\n')));
    expect(staged, isNot(contains('\r')));
    expect(
      e.stageChangeDirectory('/srv/other'),
      TerminalStageResult.pendingInput,
    );

    await subscription.cancel();
    await e.dispose();
  });

  test(
    'cursor input invalidates an otherwise empty integrated prompt',
    () async {
      final e = XtermTerminalEngine();
      e.feed(
        Uint8List.fromList(
          utf8.encode(
            '\x1b]1337;ShellIntegrationVersion=1;fish\x07'
            '\x1b]133;A\x07\x1b]133;B\x07',
          ),
        ),
      );
      e.sendCursorKey(TerminalCursorKey.arrowUp);

      expect(e.pendingInput, isEmpty);
      expect(
        e.stageChangeDirectory('/srv/project'),
        TerminalStageResult.pendingInput,
      );
      await e.dispose();
    },
  );

  test('replayed prompt markers cannot clear unsubmitted input', () async {
    final e = XtermTerminalEngine();
    e.feed(
      Uint8List.fromList(
        utf8.encode(
          '\x1b]1337;ShellIntegrationVersion=1;bash\x07'
          '\x1b]133;A\x07\x1b]133;B\x07',
        ),
      ),
    );
    e.injectInput('rm -rf ');

    e.feed(Uint8List.fromList(utf8.encode('\x1b]133;A\x07\x1b]133;B\x07')));

    expect(e.pendingInput, 'rm -rf ');
    expect(
      e.stageChangeDirectory('/srv/project'),
      TerminalStageResult.promptNotReady,
    );
    await e.dispose();
  });

  group('activeCommand', () {
    const integrated =
        '\x1b]1337;ShellIntegrationVersion=1;bash\x07'
        '\x1b]133;A\x07\x1b]133;B\x07';

    test('names the line submitted at an accepting prompt', () async {
      final e = XtermTerminalEngine();
      e.feed(Uint8List.fromList(utf8.encode(integrated)));
      e.injectInput('htop');
      e.sendKey([0x0d]);
      expect(e.activeCommand.value, 'htop');
      await e.dispose();
    });

    test('stays null without OSC 133 integration', () async {
      final e = XtermTerminalEngine();
      e.injectInput('htop');
      e.sendKey([0x0d]);
      // No 133;D will ever arrive to clear it, so it must never be set.
      expect(e.activeCommand.value, isNull);
      await e.dispose();
    });

    test('is cleared when the shell reports the command done', () async {
      final e = XtermTerminalEngine();
      e.feed(Uint8List.fromList(utf8.encode(integrated)));
      e.injectInput('sleep 60');
      e.sendKey([0x0d]);
      expect(e.activeCommand.value, 'sleep 60');
      e.feed(Uint8List.fromList(utf8.encode('\x1b]133;D;0\x07')));
      expect(e.activeCommand.value, isNull);
      await e.dispose();
    });

    test('is cleared by a fresh prompt even if D was lost', () async {
      final e = XtermTerminalEngine();
      e.feed(Uint8List.fromList(utf8.encode(integrated)));
      e.injectInput('make');
      e.sendKey([0x0d]);
      e.feed(Uint8List.fromList(utf8.encode('\x1b]133;A\x07')));
      expect(e.activeCommand.value, isNull);
      await e.dispose();
    });

    test('lines typed into a running program do not rename it', () async {
      final e = XtermTerminalEngine();
      e.feed(Uint8List.fromList(utf8.encode(integrated)));
      e.injectInput('cat > notes.txt');
      e.sendKey([0x0d]);
      // The shell is executing now; these lines belong to cat, not the shell.
      e.injectInput('dear diary');
      e.sendKey([0x0d]);
      expect(e.activeCommand.value, 'cat > notes.txt');
      await e.dispose();
    });

    test('an empty Enter at the prompt is not a command', () async {
      final e = XtermTerminalEngine();
      e.feed(Uint8List.fromList(utf8.encode(integrated)));
      e.sendKey([0x0d]);
      expect(e.activeCommand.value, isNull);
      await e.dispose();
    });
  });

  group('terminal platform', () {
    // Regression: the engine used to construct Terminal without `platform:`,
    // leaving TerminalTargetPlatform.unknown — which xterm's input handlers
    // treat as "Alt sends Meta". On macOS that consumed Option chords before
    // the IME could compose them, making ~ (Option-N on Swiss layouts) and
    // every other Option-composed character untypeable.
    test('the engine tells the terminal what platform it is on', () {
      expect(
        XtermTerminalEngine.detectPlatform(platform: TargetPlatform.macOS),
        TerminalTargetPlatform.macos,
      );
      expect(
        XtermTerminalEngine.detectPlatform(platform: TargetPlatform.linux),
        TerminalTargetPlatform.linux,
      );
      expect(
        XtermTerminalEngine.detectPlatform(
          platform: TargetPlatform.android,
          isWeb: true,
        ),
        TerminalTargetPlatform.web,
      );
      final e = XtermTerminalEngine();
      expect(e.terminal.platform, isNot(TerminalTargetPlatform.unknown));
      e.dispose();
    });

    test('on macOS an Option-modified letter is left to the IME', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final e = XtermTerminalEngine();
      final sent = <String>[];
      e.terminal.onOutput = sent.add;
      // Unconsumed is the contract: the key event must fall through so the
      // platform IME can turn Option-N into a dead tilde and compose ~.
      expect(e.terminal.keyInput(TerminalKey.keyN, alt: true), isFalse);
      expect(sent, isEmpty);
      e.dispose();
    });
  });
}
