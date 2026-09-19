/// Naming for one terminal session, derived from what the remote shell tells
/// us: the command it is running, the OSC 7 working directory, and the
/// OSC 0/2 terminal title.
///
/// Kept free of Flutter so the rules can be unit-tested directly. Everything
/// here treats remote metadata as untrusted display text: control and
/// invisible formatting characters are stripped, whitespace is collapsed, and
/// truncation walks extended grapheme clusters so a multi-byte glyph is never
/// split in half.
library;

import 'package:characters/characters.dart' as characters;

const String _ellipsis = '…';

/// C0/C1 control characters, plus the invisible formatting characters a
/// hostile title could use to reorder or hide text: the zero-width space, the
/// left-to-right and right-to-left marks (LRM/RLM), the line and paragraph
/// separators, the bidi overrides and isolates, and the byte-order mark.
///
/// Deliberately keeps U+200C/U+200D (the zero-width non-joiner and joiner):
/// they cannot reorder or conceal anything on their own, and dropping them
/// would break Persian and Arabic text and shatter ZWJ emoji into their parts.
final RegExp _invisible = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b\u200e\u200f\u2028\u2029'
  r'\u202a-\u202e\u2066-\u2069\ufeff]',
);

/// Make remote-supplied text safe to show in one line of chrome.
String sanitizeRemoteLabel(String value) =>
    value.replaceAll(_invisible, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Shorten [value] to [maxLength] grapheme clusters, ellipsising the *front*
/// so the distinguishing tail survives — the useful half of a path, or of a
/// title like `user@host: /very/long/path`, is at the end.
String shortenLabelHead(String value, int maxLength) {
  final graphemes = characters.Characters(value).toList(growable: false);
  if (graphemes.length <= maxLength) return value;
  final keep = maxLength - 1;
  if (keep <= 0) return _ellipsis;
  // Trimmed so a cut at a word boundary doesn't strand a space against the
  // ellipsis (`… foo` → `…foo`).
  return '$_ellipsis${graphemes.skip(graphemes.length - keep).join().trimLeft()}';
}

/// Shorten [value] to [maxLength] grapheme clusters, ellipsising the *end* —
/// the mirror of [shortenLabelHead], for commands, whose distinguishing half
/// is the front: the program name and its leading arguments.
String shortenLabelTail(String value, int maxLength) {
  final graphemes = characters.Characters(value).toList(growable: false);
  if (graphemes.length <= maxLength) return value;
  final keep = maxLength - 1;
  if (keep <= 0) return _ellipsis;
  // Trimmed so a cut at an argument boundary doesn't strand a space against
  // the ellipsis (`rsync -avz …` → `rsync -avz…`).
  return '${graphemes.take(keep).join().trimRight()}$_ellipsis';
}

/// The last segment of an absolute POSIX [path], or `/` for the root itself.
/// Returns null when [path] doesn't look like an absolute path.
String? posixBasename(String path) {
  if (!path.startsWith('/')) return null;
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? '/' : segments.last;
}

/// The label shown on a session's tab chip.
///
/// Preference order, most to least informative:
/// 1. a name the user gave the tab — an explicit choice always wins; the
///    roles behind three tabs on one box are not inferable,
/// 2. the command the session is running — what the tab is *doing* beats
///    where it is; two tabs on one host usually exist to run different
///    things, so this is both the best name and a natural disambiguator,
/// 3. the working directory's last segment (OSC 7) — the server is already
///    identified by the selected row, so *where* on it is the useful part,
/// 4. the terminal title (OSC 0/2), which many Bash setups carry even when
///    they do not emit OSC 7,
/// 5. `Session N` — the original behavior, when the shell reports nothing.
String sessionTabLabel({
  required int ordinal,
  String? customName,
  String? workingDirectory,
  String? terminalTitle,
  String? runningCommand,
  int maxLength = 18,
}) {
  // Tail-truncated like a command: the user typed the front, so that is the
  // half worth keeping. Sanitized again although `renameSession` already did
  // it on the way in — this function is pure and takes strings from anywhere,
  // so it cannot assume a caller cleaned them.
  final custom = customName == null ? '' : sanitizeRemoteLabel(customName);
  if (custom.isNotEmpty) return shortenLabelTail(custom, maxLength);
  final command = runningCommand == null
      ? ''
      : sanitizeRemoteLabel(runningCommand);
  if (command.isNotEmpty) return shortenLabelTail(command, maxLength);
  final cwd = workingDirectory == null
      ? null
      : posixBasename(sanitizeRemoteLabel(workingDirectory));
  if (cwd != null && cwd.isNotEmpty) return shortenLabelHead(cwd, maxLength);
  final title = terminalTitle == null ? '' : sanitizeRemoteLabel(terminalTitle);
  if (title.isNotEmpty) return shortenLabelHead(title, maxLength);
  return 'Session $ordinal';
}

/// The label shown on a file-editing tab: the file's basename, made safe for
/// chrome. An editor is named by what it edits — a custom name would say
/// less than the path does — so unlike [sessionTabLabel] there is no
/// user-named variant.
String editorTabLabel(String remotePath, {int maxLength = 18}) {
  final base = posixBasename(sanitizeRemoteLabel(remotePath));
  return shortenLabelHead(
    base == null || base.isEmpty || base == '/' ? 'File' : base,
    maxLength,
  );
}

/// The tooltip for an editor's tab chip: the full remote path — the chip
/// truncates it to a basename — the session it belongs to, and whether the
/// buffer holds unsaved edits.
String editorTabTooltip({
  required String remotePath,
  required String target,
  bool dirty = false,
}) {
  final lines = <String>[
    sanitizeRemoteLabel(remotePath),
    target,
    if (dirty) 'Unsaved changes',
  ];
  return lines.join('\n');
}

/// Suffix duplicate labels with a small stable ordinal (`~ ·1`, `~ ·2`) so
/// same-server tabs sitting in the same place stay tellable-apart — the floor
/// under the whole naming scheme. Unique labels pass through untouched, and a
/// suffix disappears on its own the moment the underlying labels diverge.
/// Numbering follows tab order, so it never depends on which tab changed.
List<String> disambiguateTabLabels(List<String> labels) {
  final counts = <String, int>{};
  for (final label in labels) {
    counts[label] = (counts[label] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return [
    for (final label in labels)
      if (counts[label]! > 1)
        '$label ·${seen[label] = (seen[label] ?? 0) + 1}'
      else
        label,
  ];
}

/// The tooltip for a session's tab chip: everything the label had to drop.
String sessionTabTooltip({
  required int ordinal,
  required String target,
  String? customName,
  String? workingDirectory,
  String? terminalTitle,
  String? runningCommand,
}) {
  final lines = <String>['Session $ordinal · $target'];
  // First, and in full: the chip truncates a long name, and this is the only
  // other place it is shown — so the untruncated text has to be reachable
  // here or it is not reachable at all.
  final custom = customName == null ? '' : sanitizeRemoteLabel(customName);
  if (custom.isNotEmpty) lines.add(custom);
  final command = runningCommand == null
      ? ''
      : sanitizeRemoteLabel(runningCommand);
  if (command.isNotEmpty) lines.add('Running: $command');
  final cwd = workingDirectory == null
      ? ''
      : sanitizeRemoteLabel(workingDirectory);
  if (cwd.isNotEmpty) lines.add(cwd);
  final title = terminalTitle == null ? '' : sanitizeRemoteLabel(terminalTitle);
  if (title.isNotEmpty && title != cwd) lines.add(title);
  return lines.join('\n');
}
