import 'dart:io';

/// Durable, crash-safe helpers for the JSON-file stores.
///
/// The stores used to write with a bare `file.writeAsString(...)`, which
/// truncates the file and then writes — so a crash or power-loss mid-write left
/// a truncated, unparseable file (including `vault.json`, which holds secrets).
/// These helpers make that impossible.

/// Write [contents] to [file] atomically: write a sibling temp file, flush it to
/// disk, then rename it over the target. `rename` replaces the destination in a
/// single filesystem operation on POSIX, so a reader (or a crash) can only ever
/// see the old file or the new one, never a half-written one. The parent
/// directory is created if needed.
Future<void> writeStringAtomically(File file, String contents) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(contents, flush: true);
  try {
    await tmp.rename(file.path);
  } on FileSystemException {
    // Some Windows configurations refuse to rename over an existing file; fall
    // back to replace-then-rename. Slightly less atomic there, but still far
    // safer than an in-place truncating write, and POSIX takes the fast path.
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }
}

/// Move a file that failed to parse aside (to `*.corrupt`) so a single bad byte
/// can't wedge startup on every launch. Best-effort — any failure is swallowed
/// and the caller simply starts from an empty store.
Future<void> quarantineCorruptFile(File file) async {
  try {
    final dest = File('${file.path}.corrupt');
    if (await dest.exists()) await dest.delete();
    await file.rename(dest.path);
  } catch (_) {
    // Best effort: if we can't move it aside, the caller still starts empty.
  }
}
