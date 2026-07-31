import 'terminal_engine.dart';

/// What carries one terminal session's bytes: an SSH channel, or a local
/// pseudo-terminal.
///
/// The app's session model owns a transport and never needs to know which kind
/// it holds — the four members here are everything it does with a live
/// session. `SshSession` already had exactly this shape; lifting it into a
/// named contract is what lets a local shell reuse the whole tab, status, and
/// teardown machinery instead of growing a parallel copy of it.
///
/// **Ownership:** [close] disposes the session's [TerminalEngine]. The app
/// relies on this — it only disposes an engine itself for a session that never
/// got a transport at all — so an implementation that skips it leaks the
/// engine and its notifiers.
abstract class SessionTransport {
  /// Resize the engine and tell the far end (remote PTY or local pty).
  void resize(TerminalSize size);

  /// Tear the session down and dispose the engine. Idempotent.
  Future<void> close();

  bool get isClosed;

  /// Fired exactly once when the far end goes away on its own — a remote
  /// logout, a dropped connection, a local shell exiting. Assigning after the
  /// fact still fires, so a caller that wires this up late doesn't miss it.
  set onClosed(void Function()? callback);

  void Function()? get onClosed;
}
