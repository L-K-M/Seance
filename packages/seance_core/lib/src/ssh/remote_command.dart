/// The captured result of one command run on an SSH exec channel: decoded
/// streams plus the remote exit code. Both streams are bounded by the
/// producer ([SshSession.runCommand]); when a stream exceeded its cap the
/// excess was discarded and [truncated] is true.
class RemoteCommandResult {
  final String stdout;
  final String stderr;

  /// The remote process's exit code, or null when the channel ended without
  /// an exit-status message (killed by signal, or the transport dropped).
  final int? exitCode;

  final bool truncated;

  const RemoteCommandResult({
    this.stdout = '',
    this.stderr = '',
    this.exitCode,
    this.truncated = false,
  });

  bool get succeeded => exitCode == 0;
}

/// A transport-level failure of [SshSession.runCommand] — the channel never
/// produced a remote exit code (disconnected, refused, or timed out). Remote
/// *command* failures are not exceptions: they come back as a
/// [RemoteCommandResult] with a non-zero exit code.
class RemoteCommandException implements Exception {
  final String message;
  const RemoteCommandException(this.message);

  @override
  String toString() => message;
}

/// The seam remote-command users (git status, server probes) and their tests
/// use to run a remote shell command:
/// injectable so parsing and classification can be tested without a transport.
/// [timeout] overrides the runner's own default (a `git pull` over a slow link
/// outlives a status probe's).
typedef RemoteCommandRunner =
    Future<RemoteCommandResult> Function(String command, {Duration? timeout});
