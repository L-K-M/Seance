import 'dart:async';
import 'dart:typed_data';

import 'session_transport.dart';
import 'terminal_engine.dart';

/// Where Séance is running, from the local shell's point of view.
///
/// Deliberately not `dart:io`'s `Platform`: the resolution rules below are
/// pure functions of platform and environment, so a test on one host can
/// exercise all of them. The app maps its own platform onto this.
enum LocalShellPlatform { linux, macos, windows, android, ios, unknown }

/// Whether a platform can host a local shell at all.
///
/// Three different reasons for "no", none of which the user can fix, which is
/// why the setting explains itself per platform rather than just greying out:
///
/// - **iOS** is a hard no and always will be. iOS apps may not spawn child
///   processes at all, so there is nothing to attach a pty to. (macOS's App
///   Sandbox restricts what a child may *do*; iOS forbids the child outright.)
/// - **Android** can technically fork a pty, but the only shell inside an
///   app's sandbox is toybox's `/system/bin/sh`, with no package manager, no
///   coreutils, no OpenSSH, and no view of anything but the app's own files.
///   That is not the local shell anyone means; Termux exists for a reason.
/// - **Windows** is capable — ConPTY works — but the pty package's
///   `build_command` writes the executable *and* the full argv (whose first
///   element is already the executable), so a spawn arrives as
///   `cmd.exe cmd.exe`, and it byte-casts the command line to UTF-16 so any
///   non-ASCII path is mangled. Enabling it means vendoring the package the
///   way `third_party/xterm` is vendored; until then this must not claim to
///   work.
///
/// `unknown` — web, or a platform added after this was written — is refused
/// for the same reason we cannot reason about it.
bool localShellSupportedOn(LocalShellPlatform platform) => switch (platform) {
      LocalShellPlatform.linux || LocalShellPlatform.macos => true,
      LocalShellPlatform.windows ||
      LocalShellPlatform.android ||
      LocalShellPlatform.ios ||
      LocalShellPlatform.unknown =>
        false,
    };

/// Why [localShellSupportedOn] said no, as one user-facing sentence. Empty for
/// a platform that does support it.
String localShellUnavailableReason(LocalShellPlatform platform) =>
    switch (platform) {
      LocalShellPlatform.linux || LocalShellPlatform.macos => '',
      LocalShellPlatform.ios =>
        'iOS does not let an app start another process, so there is no local '
            'shell to open.',
      LocalShellPlatform.android =>
        "Android only offers a minimal system shell inside the app's own "
            'sandbox, with no way to install tools into it.',
      LocalShellPlatform.windows =>
        'Not available on Windows yet — the pseudo-terminal package Séance '
            'uses builds a malformed command line there.',
      LocalShellPlatform.unknown =>
        'This platform has no pseudo-terminal Séance can open.',
    };

/// What to run, and in what environment, for one local shell.
class LocalShellCommand {
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;

  const LocalShellCommand({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
  });

  /// The shell to open on [platform], given the app process's [environment].
  ///
  /// `$SHELL` first: it is the login shell the user actually chose, and
  /// honouring it is the difference between "a shell" and "my shell". The
  /// per-platform fallbacks are the shells guaranteed to exist when it is
  /// unset — the normal case for a GUI app launched from Finder or a desktop
  /// launcher rather than from a terminal.
  ///
  /// [environment] is returned *whole*, not as a delta. The pty package does
  /// not inherit the process environment: it builds a fresh one containing
  /// `TERM`, `LANG`, and six copied variables (`LOGNAME`, `USER`, `DISPLAY`,
  /// `LC_TYPE` — its own typo for `LC_CTYPE` — `HOME`, and `PATH`), then
  /// merges the caller's map over it. Anything not passed here is silently
  /// missing from the child, so passing everything is the only way for the
  /// shell to start in the environment the app is actually running in.
  ///
  /// [terminalType] is forced in on top. A pty child with no `TERM` falls back
  /// to `dumb`, which turns off colour and cursor addressing and makes
  /// full-screen programs refuse to start — and a window-manager-launched app
  /// usually has no `TERM` of its own to inherit.
  static LocalShellCommand resolve({
    required LocalShellPlatform platform,
    required Map<String, String> environment,
    String terminalType = 'xterm-256color',
  }) {
    final executable = _executableFor(platform, environment);
    return LocalShellCommand(
      executable: executable,
      arguments: loginArgumentsFor(executable, platform),
      workingDirectory: _homeFor(platform, environment),
      environment: {
        ...environment,
        'TERM': terminalType,
        'COLORTERM': 'truecolor',
        // Let a shell profile — and anything the user runs — tell that it is
        // inside Séance, the way other terminals announce themselves.
        'TERM_PROGRAM': 'Seance',
        // The window size is the pty's, not the environment's. A stale pair
        // inherited from whatever launched the app would make programs that
        // trust it draw to the wrong width until the first resize.
      }..removeWhere((key, _) => key == 'LINES' || key == 'COLUMNS'),
    );
  }

  static String _executableFor(
    LocalShellPlatform platform,
    Map<String, String> environment,
  ) {
    if (platform == LocalShellPlatform.windows) {
      // ConPTY runs whatever this names; COMSPEC is how Windows itself says
      // "the command interpreter", and is `cmd.exe` on a stock install.
      final comspec = environment['COMSPEC'] ?? environment['ComSpec'] ?? '';
      return comspec.isNotEmpty ? comspec : 'cmd.exe';
    }
    final shell = environment['SHELL'] ?? '';
    // Only an absolute path: `$SHELL` is inherited, and a relative value would
    // resolve against whatever directory the app happens to be running in.
    if (shell.startsWith('/')) return shell;
    return switch (platform) {
      // Android has no bash and no /bin; the platform shell is toybox's.
      LocalShellPlatform.android => '/system/bin/sh',
      LocalShellPlatform.macos => '/bin/zsh',
      _ => '/bin/bash',
    };
  }

  static String? _homeFor(
    LocalShellPlatform platform,
    Map<String, String> environment,
  ) {
    final home = platform == LocalShellPlatform.windows
        ? environment['USERPROFILE'] ?? ''
        : environment['HOME'] ?? '';
    // Null means "inherit", which is the app bundle's directory — never
    // somewhere a user wants a prompt to open in.
    return home.isEmpty ? null : home;
  }

  /// The arguments that make [executable] a *login* shell — on macOS only.
  ///
  /// macOS starts GUI apps from launchd with a minimal `PATH` and none of the
  /// user's profile, so without `-l` the prompt opens with no `brew`, no
  /// version manager, and no `~/.zshrc`. Terminal.app and iTerm pass it for
  /// exactly this reason, and `zsh` — the macOS default — reads `.zshrc` as an
  /// interactive login shell, so nothing is lost by it.
  ///
  /// Deliberately *not* done on Linux, where it would be actively worse:
  /// `bash -l` reads `~/.bash_profile` and skips `~/.bashrc`, which is where
  /// aliases and prompts actually live. Desktop terminals there run a
  /// non-login interactive shell, and the session's environment is already set
  /// up by the display manager.
  ///
  /// Restricted to shells documented to accept the flag. `sh` is excluded on
  /// purpose: a shell that rejects it would exit immediately instead of
  /// degrading to a non-login shell.
  static List<String> loginArgumentsFor(
    String executable,
    LocalShellPlatform platform,
  ) {
    if (platform != LocalShellPlatform.macos) return const [];
    const loginShells = {'bash', 'zsh', 'fish', 'ksh', 'tcsh', 'csh'};
    final name = executable.split(RegExp(r'[/\\]')).last;
    return loginShells.contains(name) ? const ['-l'] : const [];
  }
}

/// The seam between Séance and a platform pseudo-terminal.
///
/// `seance_core` is pure Dart and a pty needs native code on every platform,
/// so the implementation lives in the app (over `flutter_pty`) and only this
/// contract lives here — the same shape as [TerminalEngine]. It also means
/// [LocalShellSession]'s wiring is testable against a fake with no plugin, no
/// Flutter binding, and no real child process.
abstract class LocalPty {
  /// Everything the child writes to the pty (its stdout and stderr are the
  /// same stream — that is what a pty *is*).
  Stream<Uint8List> get output;

  void write(Uint8List data);

  void resize(TerminalSize size);

  /// Completes when the child exits, with its exit status.
  Future<int> get exitCode;

  /// Signal the child to terminate. Safe to call more than once.
  void kill();
}

/// Opens a pty running [command], sized to [size].
typedef LocalPtyLauncher = Future<LocalPty> Function(
  LocalShellCommand command,
  TerminalSize size,
);

/// Thrown when a local shell could not be started. [message] is a one-line,
/// user-facing summary; [cause] is the original error.
class LocalShellException implements Exception {
  final String message;
  final Object cause;

  LocalShellException(this.message, this.cause);

  @override
  String toString() => message;
}

/// A live local shell wired to a [TerminalEngine] — the local counterpart of
/// `SshSession`, and deliberately the same shape: bytes from the child are fed
/// to the engine, the engine's user input is written back, resizes are
/// forwarded, and [onClosed] fires once when the child goes away.
class LocalShellSession implements SessionTransport {
  final LocalPty pty;
  final TerminalEngine engine;
  final LocalShellCommand command;

  final List<StreamSubscription<dynamic>> _subs = [];
  final Completer<void> _outputDone = Completer<void>();
  bool _closed = false;
  bool _exited = false;
  bool _closedNotified = false;
  int? _exitCode;
  void Function()? _onClosed;

  LocalShellSession._(this.pty, this.engine, this.command);

  /// Start [command] through [launcher] and wire it to [engine].
  static Future<LocalShellSession> start({
    required LocalPtyLauncher launcher,
    required LocalShellCommand command,
    required TerminalEngine engine,
  }) async {
    final LocalPty pty;
    try {
      pty = await launcher(command, engine.size);
    } catch (e) {
      throw LocalShellException(
        'Could not start ${command.executable} — $e',
        e,
      );
    }
    return LocalShellSession._(pty, engine, command).._wire();
  }

  /// Fired once when the shell exits (the user typed `exit`, the process was
  /// killed, it crashed). Lets the app flip the session's status dot.
  @override
  set onClosed(void Function()? callback) {
    _onClosed = callback;
    if (_exited && callback != null) scheduleMicrotask(_notifyClosed);
  }

  @override
  void Function()? get onClosed => _onClosed;

  /// The child's exit status once it has exited, or null while it runs.
  int? get exitCode => _exitCode;

  @override
  bool get isClosed => _closed;

  void _wire() {
    _subs.add(
      pty.output.listen(
        engine.feed,
        onDone: () => _complete(_outputDone),
        onError: (_) => _complete(_outputDone),
      ),
    );
    _subs.add(
      engine.userInput.listen((data) {
        if (_live) pty.write(Uint8List.fromList(data));
      }),
    );
    // Two-argument `then` on purpose: `onError` here handles a failure of the
    // exit-code future itself. `.then(_childExited).catchError(…)` would also
    // swallow anything teardown threw and re-enter _childExited, where
    // `_closed` makes it return — losing the original error entirely.
    pty.exitCode.then(_childExited, onError: (_) => _childExited(-1));
  }

  /// Whether the far end can still take bytes. [_exited] matters as well as
  /// [_closed]: between the child exiting and teardown finishing there is a
  /// drain window in which the pty is dead but the session is not yet closed,
  /// and `LocalPty` promises nothing about a write in it.
  bool get _live => !_closed && !_exited;

  @override
  void resize(TerminalSize size) {
    engine.resize(size);
    if (_live) pty.resize(size);
  }

  Future<void> _childExited(int status) async {
    if (_closed) return;
    _exited = true;
    _exitCode = status;
    // The exit future can complete before the last output has drained — the
    // farewell line of a `logout`, or the error a failed exec printed. Give
    // the stream a moment before teardown so the pane keeps what it said.
    try {
      await _outputDone.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // A pty whose read end never closes must not block teardown.
    }
    await _finish();
    _notifyClosed();
  }

  static void _complete(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }

  void _notifyClosed() {
    if (_closedNotified) return;
    final callback = _onClosed;
    if (callback == null) return;
    _closedNotified = true;
    callback();
  }

  @override
  Future<void> close() => _finish();

  Future<void> _finish() async {
    if (_closed) return;
    _closed = true;
    // Release anyone waiting on the drain. Cancelling a subscription does not
    // fire `onDone`, so a close() that lands while [_childExited] is waiting
    // out its two-second window would otherwise leave that wait to time out —
    // firing [onClosed] two seconds after the session was already torn down,
    // and holding the session and its engine alive until it did.
    _complete(_outputDone);
    for (final s in _subs) {
      await s.cancel();
    }
    // Killing an already-exited child is a no-op in every implementation; the
    // ordering here mirrors SshSession.close (drop the plumbing, drop the
    // transport, then the engine).
    pty.kill();
    await engine.dispose();
  }
}
