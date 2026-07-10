/// The command syntax used by the remote interactive shell.
enum RemoteShellKind {
  /// POSIX-compatible shells such as sh, bash, and zsh.
  posix,

  /// The fish shell.
  fish,
}

/// Builds a change-directory command for review without an Enter keypress.
///
/// [absolutePath] must be an absolute POSIX path and cannot contain control
/// characters. The path is quoted for [shell], so printable shell syntax in a
/// file name remains literal. The returned command never includes a line
/// terminator or escape character; callers can show it for review and place it
/// on an interactive prompt without executing it.
String buildChangeDirectoryCommand(
  String absolutePath, {
  required RemoteShellKind shell,
}) {
  if (!absolutePath.startsWith('/')) {
    throw ArgumentError.value(
      absolutePath,
      'absolutePath',
      'Must be an absolute POSIX path.',
    );
  }

  for (final codePoint in absolutePath.runes) {
    if (codePoint <= 0x1f || (codePoint >= 0x7f && codePoint <= 0x9f)) {
      throw ArgumentError.value(
        absolutePath,
        'absolutePath',
        'Must not contain control characters.',
      );
    }
  }

  final quotedPath = switch (shell) {
    RemoteShellKind.posix => _quotePosix(absolutePath),
    // Adjacent single/double-quoted segments are accepted by fish as well as
    // POSIX shells. One representation keeps spoofed shell metadata from ever
    // selecting a quoting dialect that is unsafe in the actual shell.
    RemoteShellKind.fish => _quotePosix(absolutePath),
  };
  return 'cd $quotedPath';
}

String _quotePosix(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
