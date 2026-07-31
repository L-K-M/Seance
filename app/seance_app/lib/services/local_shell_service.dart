import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:seance_core/seance_core.dart';

import 'macos_sandbox.dart';

/// Opens local shells for the app: decides whether this platform can host one,
/// resolves which shell to run, and binds `flutter_pty` to `seance_core`'s
/// [LocalPty] seam.
///
/// The launcher is injectable so tests exercise the whole session lifecycle
/// with no plugin and no child process — `flutter test` runs on the host Dart
/// VM, where the plugin's native library does not exist to be opened at all.
class LocalShellService {
  final LocalShellPlatform platform;
  final Map<String, String> environment;
  final LocalPtyLauncher launch;

  LocalShellService({
    LocalShellPlatform? platform,
    Map<String, String>? environment,
    LocalPtyLauncher? launch,
  })  : platform = platform ?? hostPlatform(),
        environment = environment ?? Platform.environment,
        launch = launch ?? _startFlutterPty;

  /// This build's platform, as the core's transport-agnostic enum.
  ///
  /// Reads Flutter's [defaultTargetPlatform] rather than `dart:io`'s
  /// `Platform`, so a test can pin it with `debugDefaultTargetPlatformOverride`
  /// the way the terminal engine's platform detection already is.
  static LocalShellPlatform hostPlatform() {
    if (kIsWeb) return LocalShellPlatform.unknown;
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux => LocalShellPlatform.linux,
      TargetPlatform.macOS => LocalShellPlatform.macos,
      TargetPlatform.windows => LocalShellPlatform.windows,
      TargetPlatform.android => LocalShellPlatform.android,
      TargetPlatform.iOS => LocalShellPlatform.ios,
      TargetPlatform.fuchsia => LocalShellPlatform.unknown,
    };
  }

  bool get supported => localShellSupportedOn(platform);

  /// Whether the local shell should be offered at all: the user asked for it
  /// *and* this platform can host one. Both halves are load-bearing — the
  /// settings file is device-local but portable, so a value enabled on a
  /// laptop must never put a row that cannot open into a phone's list.
  bool availableWhen({required bool enabledInSettings}) =>
      enabledInSettings && supported;

  /// One sentence saying why this platform has no local shell, or empty when
  /// it does. Shown in Settings instead of an unexplained disabled switch.
  String get unavailableReason => localShellUnavailableReason(platform);

  /// True when the shell would run inside macOS's App Sandbox — which the
  /// child inherits, so `$HOME` is Séance's container, anything outside it is
  /// unreadable, and the shell cannot take control of the terminal for job
  /// control.
  ///
  /// Normally false: Séance's macOS entitlements drop the sandbox precisely so
  /// this shell is a real one. The detection stays because it is cheap, it is
  /// the honest answer for anyone who puts the entitlement back, and a warning
  /// that only appears when it is true costs nothing when it is not.
  bool get sandboxed => macOsSandboxed(
    environment: environment,
    isMacOS: platform == LocalShellPlatform.macos,
  );

  /// What a fresh local shell should run here.
  ///
  /// Resolved once: a process's environment does not change under it, and
  /// [shellName] is read from the server list's builder on every rebuild —
  /// re-resolving would copy the whole environment map each frame.
  late final LocalShellCommand command = LocalShellCommand.resolve(
    platform: platform,
    environment: environment,
  );

  /// A short label for the shell being run — `zsh`, `bash` — for the tab and
  /// the status bar.
  late final String shellName = _basename(command.executable);

  static String _basename(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    return name.isEmpty ? 'shell' : name;
  }

  /// The banner fed into a sandboxed session's terminal before the shell's
  /// first output, or null when there is nothing to warn about.
  ///
  /// Written into the terminal rather than shown as app chrome because it
  /// describes *this shell*, scrolls away with it, and stays in the scrollback
  /// where the surprising `cd ~` is about to happen.
  String? get sandboxNotice => sandboxed
      ? 'Séance: this shell runs inside the macOS App Sandbox. '
          "\$HOME is Séance's container, files outside it are unreadable, "
          'and job control is unavailable.\r\n'
      : null;

  static Future<LocalPty> _startFlutterPty(
    LocalShellCommand command,
    TerminalSize size,
  ) async =>
      FlutterPtyLocalPty(command, size);
}

/// [LocalPty] over `flutter_pty`.
class FlutterPtyLocalPty implements LocalPty {
  final Pty _pty;
  bool _killed = false;

  /// `Pty.start` is a synchronous constructor that throws [StateError] when
  /// the fork fails; [LocalShellSession.start] turns that into a
  /// [LocalShellException] carrying a user-facing line.
  FlutterPtyLocalPty(LocalShellCommand command, TerminalSize size)
      : _pty = Pty.start(
          command.executable,
          arguments: command.arguments,
          workingDirectory: command.workingDirectory,
          // Passed whole, not as a delta — the plugin builds the child's
          // environment from a fixed six names plus this map, so anything
          // omitted here simply would not exist in the shell.
          environment: command.environment,
          rows: size.rows,
          columns: size.cols,
        );

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  Future<int> get exitCode => _pty.exitCode;

  @override
  void write(Uint8List data) => _pty.write(data);

  /// The plugin takes rows first; [TerminalSize] is columns-first. Going
  /// through the seam is what keeps that transposition in one place.
  @override
  void resize(TerminalSize size) => _pty.resize(size.rows, size.cols);

  @override
  void kill() {
    // Signalling a process that has already exited throws on some platforms,
    // and close() is allowed to run after the shell died on its own.
    if (_killed) return;
    _killed = true;
    try {
      _pty.kill();
    } catch (error) {
      debugPrint('Local shell was already gone when killed: $error');
    }
  }
}
