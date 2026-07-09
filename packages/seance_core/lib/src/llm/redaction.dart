/// Redacts obvious secrets from any text before it leaves the machine toward an
/// LLM provider — session context *and* generated web-search queries. Modeled
/// on Warp's secret-redaction list. It is a best-effort filter, not a guarantee
/// (running against a local model is the real privacy story), and is
/// user-extensible via [extraPatterns].
class SecretRedactor {
  static const String _mask = '«redacted»';

  final List<RegExp> _patterns;

  SecretRedactor({List<RegExp> extraPatterns = const []})
    : _patterns = [..._builtin, ...extraPatterns];

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
    // Bearer tokens and inline password/secret assignments. The lookbehind
    // (rather than \b) lets `DB_PASSWORD=...` match, since `_` is a word char.
    RegExp(r'\bbearer\s+[A-Za-z0-9._\-]{16,}', caseSensitive: false),
    RegExp(
      r'''(?<![A-Za-z0-9])(password|passwd|secret|api[_-]?key|token)\s*[=:]\s*['"]?[^\s'"]{6,}''',
      caseSensitive: false,
    ),
  ];

  /// Returns [text] with any matched secret spans replaced by a mask.
  String redact(String text) {
    var out = text;
    for (final p in _patterns) {
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
