/// Raised when text cannot be pasted safely into the prompt line.
class UnsafePasteException implements Exception {
  final String reason;
  const UnsafePasteException(this.reason);
  @override
  String toString() => 'UnsafePasteException: $reason';
}

/// Makes "paste into the prompt but never run it" actually true.
///
/// The load-bearing rule is that a newline *is* an Enter keypress: if the
/// assistant (or injected scrollback) hands us text containing a line break,
/// pasting it verbatim would execute it. So [sanitize] rejects any CR/LF and
/// strips other control characters, leaving a single editable line the user
/// must press Enter on themselves.
class PasteSanitizer {
  /// Returns cleaned single-line text, or throws [UnsafePasteException] if the
  /// input contains a line break.
  static String sanitize(String input) {
    if (input.contains('\n') || input.contains('\r')) {
      throw const UnsafePasteException(
        'Refusing to paste multi-line text: a line break would execute the '
        'command. Paste one line at a time.',
      );
    }
    return _stripControlChars(input);
  }

  /// Like [sanitize] but collapses a multi-line block to its first line rather
  /// than throwing — used when the user explicitly asks to paste only the first
  /// command of a suggested block.
  static String sanitizeFirstLine(String input) {
    final firstLine = input.split(RegExp(r'\r?\n')).first;
    return _stripControlChars(firstLine);
  }

  static String _stripControlChars(String s) {
    final buffer = StringBuffer();
    for (final rune in s.runes) {
      // Drop C0 controls (0x00–0x1F) and DEL (0x7F). Tab (0x09) is allowed
      // because it is legitimately used on the command line.
      final isC0 = rune < 0x20 && rune != 0x09;
      final isDel = rune == 0x7f;
      if (!isC0 && !isDel) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }
}
