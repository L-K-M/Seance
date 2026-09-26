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
/// characters. The path is quoted with [quoteShellWord], so printable shell
/// syntax in a file name remains literal in every [shell]. The returned
/// command never includes a line terminator or escape character; callers can
/// show it for review and place it on an interactive prompt without executing
/// it.
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
    // One spelling for every dialect keeps spoofed shell metadata from ever
    // selecting a quoting that is unsafe in the shell actually running.
    RemoteShellKind.posix => quoteShellWord(absolutePath),
    RemoteShellKind.fish => quoteShellWord(absolutePath),
  };
  return 'cd $quotedPath';
}

/// Quotes [value] as one literal word for a remote shell, whether sh, bash,
/// zsh or fish parses it.
///
/// Everything goes inside single quotes except `'` and `\`, which go on
/// their own inside double quotes: every one of these shells reads `"'"` as
/// a quote and `"\\"` as a backslash. fish treats `\'` and `\\` as escapes
/// even inside single quotes, so the POSIX spelling `'it'"'"'s'` is not
/// enough there: a backslash before the closing quote escapes it, and the
/// rest of the command line runs as code. The remote shell is whatever the
/// account's login shell is, so no caller can pick a dialect safely.
///
/// An empty [value] becomes `''`. Control characters stay literal too, but
/// a caller typing the word into an interactive shell must reject them
/// itself (see [buildChangeDirectoryCommand]).
String quoteShellWord(String value) {
  if (value.isEmpty) return "''";
  return value.splitMapJoin(
    _escapedInFishSingleQuotes,
    onMatch: (match) => match[0] == r'\' ? r'"\\"' : '"\'"',
    onNonMatch: (run) => run.isEmpty ? '' : "'$run'",
  );
}

final _escapedInFishSingleQuotes = RegExp(r"['\\]");
