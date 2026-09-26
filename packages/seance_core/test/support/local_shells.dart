import 'dart:convert';
import 'dart:io';

/// The shells Séance quotes remote commands for, each with the flags that run
/// one command line without reading user startup files (which could print
/// into the captured output).
const localShells = <String, List<String>>{
  'sh': ['-c'],
  'bash': ['-c'],
  'zsh': ['-f', '-c'],
  'fish': ['--no-config', '-c'],
};

/// A `skip:` value for a test that needs [shell]: a reason when it is not
/// installed here, false when it is. Only `sh` is expected everywhere the
/// suite runs; the others are exercised wherever a developer has them.
Object shellSkipReason(String shell) {
  // The tests compare POSIX `pwd` output, which a Windows sh.exe prints in
  // MSYS form (/c/Users/...), so say so rather than blame a missing shell.
  if (Platform.isWindows) return 'POSIX shell output differs on Windows';
  final path = Platform.environment['PATH'] ?? '';
  for (final directory in path.split(':')) {
    if (directory.isEmpty) continue;
    if (File('$directory/$shell').existsSync()) return false;
  }
  return '$shell is not on PATH';
}

/// Runs [commandLine] the way sshd hands an exec request to a login shell:
/// as the single argument of `<shell> -c`.
Future<ProcessResult> runInShell(
  String shell,
  String commandLine, {
  required String workingDirectory,
}) => Process.run(
  shell,
  [...localShells[shell]!, commandLine],
  workingDirectory: workingDirectory,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);
