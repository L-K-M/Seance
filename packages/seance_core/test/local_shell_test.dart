import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// A [LocalPty] with no child process: the test drives what the "shell" says
/// and when it exits, and reads back everything that was written to it.
class FakeLocalPty implements LocalPty {
  final _output = StreamController<Uint8List>();
  final _exit = Completer<int>();
  final List<int> written = [];
  final List<TerminalSize> resizes = [];
  int killCount = 0;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(Uint8List data) => written.addAll(data);

  @override
  void resize(TerminalSize size) => resizes.add(size);

  @override
  void kill() {
    killCount++;
    // A real pty's child dies here: its output stream ends and its exit code
    // resolves. Leaving those hanging would let a future `close()` that awaits
    // the exit code hang silently instead of failing.
    if (!_output.isClosed) _output.close();
    if (!_exit.isCompleted) _exit.complete(-15); // SIGTERM
  }

  String get writtenText => utf8.decode(written, allowMalformed: true);

  void emit(String text) => _output.add(Uint8List.fromList(utf8.encode(text)));

  /// The child exits: the real pty closes its read port at the same moment.
  Future<void> exit(int status) async {
    await _output.close();
    if (!_exit.isCompleted) _exit.complete(status);
  }

  /// The child exits but its output never ends — the case that puts
  /// [LocalShellSession] into its drain wait and leaves it there.
  void exitWithoutDraining(int status) {
    if (!_exit.isCompleted) _exit.complete(status);
  }
}

Future<LocalShellSession> startWith(
  FakeLocalPty pty,
  HeadlessTerminalEngine engine, {
  LocalShellCommand command = const LocalShellCommand(executable: '/bin/zsh'),
}) => LocalShellSession.start(
      launcher: (_, __) async => pty,
      command: command,
      engine: engine,
    );

void main() {
  group('localShellSupportedOn', () {
    test('only the two platforms with a usable shell say yes', () {
      expect(localShellSupportedOn(LocalShellPlatform.linux), isTrue);
      expect(localShellSupportedOn(LocalShellPlatform.macos), isTrue);
      // Each of these is refused for its own reason; see the doc comment.
      expect(localShellSupportedOn(LocalShellPlatform.windows), isFalse);
      expect(localShellSupportedOn(LocalShellPlatform.android), isFalse);
      expect(localShellSupportedOn(LocalShellPlatform.ios), isFalse);
      expect(localShellSupportedOn(LocalShellPlatform.unknown), isFalse);
    });

    test('every unsupported platform explains itself, supported ones do not',
        () {
      for (final platform in LocalShellPlatform.values) {
        final reason = localShellUnavailableReason(platform);
        if (localShellSupportedOn(platform)) {
          expect(reason, isEmpty, reason: '$platform');
        } else {
          expect(reason, isNotEmpty, reason: '$platform');
        }
      }
    });
  });

  group('LocalShellCommand.resolve', () {
    test('an absolute \$SHELL wins on every POSIX platform', () {
      for (final platform in [
        LocalShellPlatform.linux,
        LocalShellPlatform.macos,
        LocalShellPlatform.android,
      ]) {
        final command = LocalShellCommand.resolve(
          platform: platform,
          environment: {'SHELL': '/usr/bin/fish'},
        );
        expect(command.executable, '/usr/bin/fish', reason: '$platform');
      }
    });

    test('a relative or empty \$SHELL falls back to the platform default', () {
      for (final shell in ['', 'zsh', '../zsh']) {
        expect(
          LocalShellCommand.resolve(
            platform: LocalShellPlatform.macos,
            environment: {'SHELL': shell},
          ).executable,
          '/bin/zsh',
          reason: 'SHELL=$shell',
        );
      }
    });

    test('platform defaults when \$SHELL is unset', () {
      String shellOn(LocalShellPlatform platform) =>
          LocalShellCommand.resolve(platform: platform, environment: const {})
              .executable;
      expect(shellOn(LocalShellPlatform.macos), '/bin/zsh');
      expect(shellOn(LocalShellPlatform.linux), '/bin/bash');
      expect(shellOn(LocalShellPlatform.android), '/system/bin/sh');
    });

    test('Windows takes COMSPEC, in either casing, else cmd.exe', () {
      String shellFor(Map<String, String> env) => LocalShellCommand.resolve(
            platform: LocalShellPlatform.windows,
            environment: env,
          ).executable;
      expect(shellFor({'COMSPEC': r'C:\Windows\System32\cmd.exe'}),
          r'C:\Windows\System32\cmd.exe');
      expect(shellFor({'ComSpec': r'C:\alt\cmd.exe'}), r'C:\alt\cmd.exe');
      expect(shellFor(const {}), 'cmd.exe');
    });

    test('the shell opens in \$HOME, and nowhere when there is none', () {
      expect(
        LocalShellCommand.resolve(
          platform: LocalShellPlatform.linux,
          environment: {'HOME': '/home/ada'},
        ).workingDirectory,
        '/home/ada',
      );
      expect(
        LocalShellCommand.resolve(
          platform: LocalShellPlatform.windows,
          environment: {'USERPROFILE': r'C:\Users\ada'},
        ).workingDirectory,
        r'C:\Users\ada',
      );
      expect(
        LocalShellCommand.resolve(
          platform: LocalShellPlatform.linux,
          environment: const {},
        ).workingDirectory,
        isNull,
      );
    });

    test('-l only on macOS, and only for shells that accept it', () {
      List<String> argsFor(LocalShellPlatform platform, String shell) =>
          LocalShellCommand.resolve(
            platform: platform,
            environment: {'SHELL': shell},
          ).arguments;
      expect(argsFor(LocalShellPlatform.macos, '/bin/zsh'), ['-l']);
      expect(argsFor(LocalShellPlatform.macos, '/bin/bash'), ['-l']);
      // dash/toybox `sh` would exit rather than ignore the flag.
      expect(argsFor(LocalShellPlatform.macos, '/bin/sh'), isEmpty);
      // On Linux `bash -l` skips ~/.bashrc, which is where everything lives.
      expect(argsFor(LocalShellPlatform.linux, '/bin/bash'), isEmpty);
      expect(argsFor(LocalShellPlatform.android, '/system/bin/sh'), isEmpty);
    });

    test('the whole environment is carried, not a delta', () {
      // The pty package rebuilds the environment from six hard-coded names, so
      // anything not returned here never reaches the child.
      final command = LocalShellCommand.resolve(
        platform: LocalShellPlatform.linux,
        environment: {
          'PATH': '/usr/bin',
          'HOME': '/home/ada',
          'LC_CTYPE': 'en_GB.UTF-8',
          'SSH_AUTH_SOCK': '/tmp/agent.sock',
          'XDG_RUNTIME_DIR': '/run/user/1000',
        },
      );
      expect(command.environment['SSH_AUTH_SOCK'], '/tmp/agent.sock');
      expect(command.environment['XDG_RUNTIME_DIR'], '/run/user/1000');
      expect(command.environment['LC_CTYPE'], 'en_GB.UTF-8');
      expect(command.environment['PATH'], '/usr/bin');
    });

    test('TERM is forced even when the app inherited a useless one', () {
      final command = LocalShellCommand.resolve(
        platform: LocalShellPlatform.linux,
        environment: {'TERM': 'dumb'},
      );
      expect(command.environment['TERM'], 'xterm-256color');
      expect(command.environment['COLORTERM'], 'truecolor');
      expect(command.environment['TERM_PROGRAM'], 'Seance');
    });

    test('a stale inherited window size is dropped', () {
      final command = LocalShellCommand.resolve(
        platform: LocalShellPlatform.linux,
        environment: {'LINES': '24', 'COLUMNS': '80', 'PATH': '/usr/bin'},
      );
      expect(command.environment.containsKey('LINES'), isFalse);
      expect(command.environment.containsKey('COLUMNS'), isFalse);
      expect(command.environment['PATH'], '/usr/bin');
    });
  });

  group('LocalShellSession', () {
    test('pipes bytes in both directions', () async {
      final pty = FakeLocalPty();
      final engine = HeadlessTerminalEngine();
      final session = await startWith(pty, engine);

      pty.emit('ada@laptop ~ % ');
      await pumpEventQueue();
      expect(engine.receivedText, 'ada@laptop ~ % ');

      engine.type('uptime\r');
      await pumpEventQueue();
      expect(pty.writtenText, 'uptime\r');

      await session.close();
    });

    test('resize reaches both the engine and the pty', () async {
      final pty = FakeLocalPty();
      final engine = HeadlessTerminalEngine();
      final session = await startWith(pty, engine);

      session.resize(const TerminalSize(120, 40));
      expect(engine.size, const TerminalSize(120, 40));
      // Carried as a size, not a pair of ints — the pty API takes rows first
      // and the transposition is invisible until something draws wrong.
      expect(pty.resizes.single.cols, 120);
      expect(pty.resizes.single.rows, 40);

      await session.close();
    });

    test('a resize after close is not forwarded to a dead pty', () async {
      final pty = FakeLocalPty();
      final session = await startWith(pty, HeadlessTerminalEngine());
      await session.close();
      session.resize(const TerminalSize(100, 30));
      expect(pty.resizes, isEmpty);
    });

    test('the shell exiting fires onClosed once and records the status',
        () async {
      final pty = FakeLocalPty();
      final session = await startWith(pty, HeadlessTerminalEngine());
      var closedCalls = 0;
      session.onClosed = () => closedCalls++;

      await pty.exit(0);
      await pumpEventQueue();

      expect(closedCalls, 1);
      expect(session.exitCode, 0);
      expect(session.isClosed, isTrue);
    });

    test('onClosed assigned after a fast exit still fires', () async {
      final pty = FakeLocalPty();
      final session = await startWith(pty, HeadlessTerminalEngine());
      await pty.exit(130);
      await pumpEventQueue();

      var closedCalls = 0;
      session.onClosed = () => closedCalls++;
      await pumpEventQueue();
      expect(closedCalls, 1);
    });

    test('a farewell line printed as the shell exits is not lost', () async {
      final pty = FakeLocalPty();
      final engine = HeadlessTerminalEngine();
      final session = await startWith(pty, engine);

      pty.emit('logout\r\n');
      await pty.exit(0);
      await pumpEventQueue();

      expect(engine.receivedText, contains('logout'));
      expect(session.exitCode, 0);
    });

    test('close kills the pty and disposes the engine, and is idempotent',
        () async {
      final pty = FakeLocalPty();
      final engine = HeadlessTerminalEngine();
      final session = await startWith(pty, engine);

      await session.close();
      await session.close();

      expect(pty.killCount, 1);
      expect(session.isClosed, isTrue);
      // The app relies on the transport disposing the engine: a second dispose
      // of the engine's notifiers would assert, so this must happen once.
      expect(() => engine.type('x'), throwsStateError);
    });

    test('closing after the shell exited does not tear down twice', () async {
      final pty = FakeLocalPty();
      final session = await startWith(pty, HeadlessTerminalEngine());
      var closedCalls = 0;
      session.onClosed = () => closedCalls++;

      await pty.exit(0);
      await pumpEventQueue();
      await session.close();

      expect(closedCalls, 1);
      expect(pty.killCount, 1);
    });

    test('an exiting shell tears itself down before anyone is told', () async {
      // The app's onClosed only nulls its reference to the transport; it does
      // not close it. That is correct *because* teardown has already happened
      // by the time the callback runs — this is the test that says so.
      final pty = FakeLocalPty();
      final engine = HeadlessTerminalEngine();
      final session = await startWith(pty, engine);
      var engineDisposedWhenNotified = false;
      session.onClosed = () {
        engineDisposedWhenNotified = engine.isDisposed;
      };

      await pty.exit(0);
      await pumpEventQueue();

      expect(session.isClosed, isTrue);
      expect(pty.killCount, 1);
      expect(engineDisposedWhenNotified, isTrue,
          reason: 'the engine must be disposed before onClosed fires');
    });

    test('a keystroke racing the exit never reaches the dead pty', () async {
      final pty = FakeLocalPty();
      final engine = HeadlessTerminalEngine();
      await startWith(pty, engine);

      // Between the child exiting and teardown finishing there is a drain
      // window; nothing typed in it may be written to a pty with no child.
      await pty.exit(0);
      engine.type('rm -rf /\r');
      await pumpEventQueue();

      expect(pty.writtenText, isEmpty);
      // And once teardown is done the engine itself is gone, so there is no
      // path left from a keystroke to the pty at all.
      expect(() => engine.type('ls\r'), throwsStateError);
    });

    test('closing during the drain wait does not sit out the timeout',
        () async {
      final pty = FakeLocalPty();
      final session = await startWith(pty, HeadlessTerminalEngine());
      var closedCalls = 0;
      session.onClosed = () => closedCalls++;

      // The child is gone but its output stream never ends, so the session is
      // now inside its two-second drain window.
      pty.exitWithoutDraining(0);
      await pumpEventQueue();
      expect(closedCalls, 0, reason: 'still draining');

      // Cancelling the output subscription does not fire onDone, so without
      // _finish releasing the drain this would only resolve two seconds of
      // real time later — long after the session was torn down.
      await session.close();
      await pumpEventQueue();

      expect(closedCalls, 1);
      expect(session.isClosed, isTrue);
    });

    test('a shell that cannot be spawned surfaces one readable line', () async {
      final engine = HeadlessTerminalEngine();
      await expectLater(
        LocalShellSession.start(
          launcher: (_, __) async => throw StateError('Failed to create PTY'),
          command: const LocalShellCommand(executable: '/bin/nope'),
          engine: engine,
        ),
        throwsA(
          isA<LocalShellException>().having(
            (e) => e.message,
            'message',
            allOf(contains('/bin/nope'), contains('Failed to create PTY')),
          ),
        ),
      );
      await engine.dispose();
    });
  });

  group('SessionTransport', () {
    test('a local shell is usable through the shared contract', () async {
      final pty = FakeLocalPty();
      final SessionTransport transport =
          await startWith(pty, HeadlessTerminalEngine());
      expect(transport.isClosed, isFalse);
      transport.resize(const TerminalSize(90, 30));
      await transport.close();
      expect(transport.isClosed, isTrue);
    });
  });
}
