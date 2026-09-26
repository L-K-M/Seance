/// Redacts obvious secrets from any text before it leaves the machine toward an
/// LLM provider — session context *and* generated web-search queries. Modeled
/// on Warp's secret-redaction list. It is a best-effort filter, not a guarantee
/// (running against a local model is the real privacy story), and is
/// user-extensible via [extraPatterns].
class SecretRedactor {
  static const String _mask = '«redacted»';

  final List<RegExp> _extraPatterns;

  /// When false, [redact] is a pass-through. This lets the app honor the
  /// user's "Redact secrets before sending" toggle (the safe default is on);
  /// the redactor is still constructed the same way at every call site.
  final bool enabled;

  SecretRedactor({List<RegExp> extraPatterns = const [], this.enabled = true})
    : _extraPatterns = List.unmodifiable(extraPatterns);

  static final List<RegExp> _builtin = [
    // Whole private-key blocks (PEM / OpenSSH).
    RegExp(
      r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
    ),
    // Provider API keys / tokens.
    RegExp(r'\bsk-ant-[A-Za-z0-9_\-]{20,}'), // Anthropic
    RegExp(r'\bsk-proj-[A-Za-z0-9_\-]{20,}'), // OpenAI project keys
    RegExp(r'\bsk-[A-Za-z0-9]{20,}'), // OpenAI-style
    RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}'), // GitHub tokens
    RegExp(r'\bgithub_pat_[A-Za-z0-9_]{20,}'), // GitHub fine-grained PATs
    RegExp(r'\bglpat-[A-Za-z0-9_\-]{20,}'), // GitLab tokens
    RegExp(r'\bxox[baprs]-[A-Za-z0-9\-]{10,}'), // Slack tokens
    RegExp(r'\bAKIA[0-9A-Z]{16}\b'), // AWS access key id
    RegExp(r'\bAIza[0-9A-Za-z_\-]{35}\b'), // Google API key
    // JWTs.
    RegExp(r'\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}'),
    // Bearer tokens. Assignments need a separate value scanner below.
    RegExp(r'\bbearer\s+[A-Za-z0-9._\-]{16,}', caseSensitive: false),
  ];

  // A closing quote permits JSON/YAML keys; the opening quote stays in the
  // copied prefix. This also recognizes DB_PASSWORD without notpassword.
  static final RegExp _assignment = RegExp(
    r'''(?<![A-Za-z0-9])(password|passwd|secret|api[_-]?key|token)["']?\s*[=:]\s*''',
    caseSensitive: false,
  );
  // Punctuation may be part of a shell credential; only whitespace/quotes
  // ended an unquoted value in the original filter, so keep that boundary.
  static final RegExp _unquotedEnd = RegExp(r'''[\s'"]''');

  static String _redactAssignments(String text) {
    final out = StringBuffer();
    var copiedThrough = 0;
    for (final match in _assignment.allMatches(text)) {
      if (match.start < copiedThrough || match.end == text.length) continue;
      final first = text.codeUnitAt(match.end);
      final quoted = first == 0x22 || first == 0x27;
      final valueStart = match.end + (quoted ? 1 : 0);
      var valueEnd = valueStart;
      while (valueEnd < text.length) {
        final unit = text.codeUnitAt(valueEnd);
        if (!quoted) {
          if (_unquotedEnd.matchAsPrefix(text, valueEnd) != null) break;
        } else if (unit == 0x5c) {
          // An escaped quote is part of the value, not its end. If truncated,
          // consume the available tail instead of leaking it after the mask.
          valueEnd += valueEnd + 1 < text.length ? 2 : 1;
          continue;
        } else if (unit == first) {
          // YAML single-quoted strings escape a quote by doubling it.
          if (first == 0x27 &&
              valueEnd + 1 < text.length &&
              text.codeUnitAt(valueEnd + 1) == first) {
            valueEnd += 2;
            continue;
          }
          break;
        }
        valueEnd++;
      }
      if (valueEnd == valueStart) continue;
      out
        ..write(text.substring(copiedThrough, valueStart))
        ..write(_mask);
      copiedThrough = valueEnd;
      // Retain a closing quote without scanning assignment-like text inside
      // the value again. Unterminated values conservatively consume the tail.
      if (quoted && valueEnd < text.length) {
        out.writeCharCode(first);
        copiedThrough++;
      }
    }
    out.write(text.substring(copiedThrough));
    return out.toString();
  }

  /// Returns [text] with any matched secret spans replaced by a mask. When
  /// [enabled] is false this is a pass-through and returns [text] unchanged.
  String redact(String text) {
    if (!enabled) return text;
    var out = text;
    for (final p in _builtin) {
      out = out.replaceAll(p, _mask);
    }
    // Mask PEM blocks before scanning values so an unquoted assignment cannot
    // lose its PEM header and expose the remaining key. Mask assignments
    // before custom patterns, which might themselves obscure a secret's label.
    out = _redactAssignments(out);
    for (final p in _extraPatterns) {
      out = out.replaceAllMapped(p, (m) {
        // Keep an assignment's key visible, mask only the value.
        final match = m[0]!;
        final sep = RegExp(r'[=:]');
        if (p.pattern.contains('password') && sep.hasMatch(match)) {
          final idx = match.indexOf(sep);
          return '${match.substring(0, idx + 1)} $_mask';
        }
        return _mask;
      });
    }
    return out;
  }

  /// True if redaction changed anything — useful to warn the user.
  bool wouldRedact(String text) => redact(text) != text;
}
