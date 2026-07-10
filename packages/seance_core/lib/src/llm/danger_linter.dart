/// Severity of a flagged command pattern.
enum DangerSeverity { warning, critical }

class DangerFinding {
  final DangerSeverity severity;
  final String pattern;
  final String explanation;

  const DangerFinding({
    required this.severity,
    required this.pattern,
    required this.explanation,
  });
}

/// A client-side, model-independent check for obviously destructive commands.
/// It runs on every command the assistant proposes and on every paste, so a
/// dangerous suggestion is flagged even if the model failed to mark it — and
/// even if it was smuggled in via prompt injection.
///
/// This is a safety net, not a sandbox: it is intentionally conservative and
/// makes no attempt to fully parse shell grammar. Nothing is ever blocked
/// outright — findings are surfaced to the user, who still makes the call.
class DangerLinter {
  static final List<_Rule> _rules = [
    _Rule(
      // A recursive/forced rm whose target is an ABSOLUTE path (/, /etc,
      // /var/lib, …), a home path (~, $HOME), or a wildcard. The lookahead
      // requires an -r/-f flag; the target must start after whitespace so a
      // relative path like `a/b` isn't matched. (The old rule only fired on a
      // bare `/`, `~`, `*`, or `$HOME`, so `rm -rf /etc` slipped through.)
      RegExp(r'\brm\b(?=[^\n]*\s-{1,2}[a-zA-Z]*[rf])[^\n]*\s(/\S*|~\S*|\$HOME\S*|\*)(\s|$)'),
      DangerSeverity.critical,
      'Recursive/forced delete of an absolute, home, or wildcard path.',
    ),
    _Rule(
      RegExp(r'\bdd\b.*\bof=/dev/'),
      DangerSeverity.critical,
      'dd writing directly to a device node can destroy a disk.',
    ),
    _Rule(
      RegExp(r'\bmkfs(\.\w+)?\b'),
      DangerSeverity.critical,
      'Creates a filesystem, erasing the target device.',
    ),
    _Rule(
      RegExp(r'\bwipefs\b'),
      DangerSeverity.critical,
      'wipefs erases the filesystem signatures from a device.',
    ),
    _Rule(
      RegExp(r'>\s*/dev/(sd|nvme|vd|hd)\w+'),
      DangerSeverity.critical,
      'Redirecting output onto a block device overwrites it.',
    ),
    _Rule(
      RegExp(r':\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:'),
      DangerSeverity.critical,
      'Classic fork bomb.',
    ),
    _Rule(
      RegExp(r'\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b'),
      DangerSeverity.warning,
      'Piping a downloaded script straight into a shell runs unreviewed code.',
    ),
    _Rule(
      RegExp(r'\bchmod\s+(-R\s+)?0?777\b'),
      DangerSeverity.warning,
      'World-writable permissions (777) are almost never intended.',
    ),
    _Rule(
      RegExp(r'\bshred\b'),
      DangerSeverity.warning,
      'shred overwrites a file so it cannot be recovered.',
    ),
    _Rule(
      RegExp(r'\bfind\b[^\n]*\s-delete\b'),
      DangerSeverity.warning,
      'find -delete removes every matched file.',
    ),
    _Rule(
      RegExp(r'\btruncate\b[^\n]*-s\s*0\b'),
      DangerSeverity.warning,
      'truncate -s 0 discards a file\'s contents.',
    ),
    _Rule(
      RegExp(r'\bgit\s+clean\b[^\n]*\s-[a-zA-Z]*f'),
      DangerSeverity.warning,
      'git clean -f deletes untracked files (-x/-d widen the blast radius).',
    ),
    _Rule(
      RegExp(r'\b(shutdown|reboot|halt|poweroff)\b'),
      DangerSeverity.warning,
      'Powers down or reboots the host.',
    ),
    _Rule(
      RegExp(r'\biptables\s+-F\b'),
      DangerSeverity.warning,
      'Flushes firewall rules; can lock you out of a remote host.',
    ),
  ];

  /// Returns all findings for [command] (empty if it looks benign).
  static List<DangerFinding> scan(String command) {
    final normalized = command.trim();
    final findings = <DangerFinding>[];
    for (final rule in _rules) {
      if (rule.pattern.hasMatch(normalized)) {
        findings.add(DangerFinding(
          severity: rule.severity,
          pattern: rule.pattern.pattern,
          explanation: rule.explanation,
        ));
      }
    }
    return findings;
  }

  /// The most severe finding, or null if none.
  static DangerSeverity? worst(String command) {
    final findings = scan(command);
    if (findings.isEmpty) return null;
    return findings.any((f) => f.severity == DangerSeverity.critical)
        ? DangerSeverity.critical
        : DangerSeverity.warning;
  }
}

class _Rule {
  final RegExp pattern;
  final DangerSeverity severity;
  final String explanation;
  _Rule(this.pattern, this.severity, this.explanation);
}
