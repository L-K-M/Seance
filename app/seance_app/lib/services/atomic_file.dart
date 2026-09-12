import 'dart:io';

import 'file_permissions.dart';

final _pendingWrites = <String, Future<void>>{};

/// Durable, crash-safe helpers for the JSON-file stores.
///
/// The stores used to write with a bare `file.writeAsString(...)`, which
/// truncates the file and then writes — so a crash or power-loss mid-write left
/// a truncated, unparseable file (including `vault.json`, which holds secrets).
/// These helpers make that impossible.

/// Who may read a file written atomically.
enum AtomicFilePrivacy {
  /// The process's default file-creation mode — today's behavior, kept by
  /// every ordinary store write.
  processDefault,

  /// Owner-only mode bits on desktop POSIX; other platforms keep their
  /// storage ACLs.
  ownerOnly,
}

/// Write [contents] to [file] atomically: write a sibling temp file, flush it to
/// disk, then rename it over the target. `rename` replaces the destination in a
/// single filesystem operation on POSIX, so a reader (or a crash) can only ever
/// see the old file or the new one, never a half-written one. The parent
/// directory is created if needed. Pass [privacy] to restrict who may read the
/// result; the default preserves the ordinary stores' behavior.
Future<void> writeStringAtomically(File file, String contents,
    {AtomicFilePrivacy privacy = AtomicFilePrivacy.processDefault}) {
  final path = file.absolute.uri.normalizePath().toFilePath();
  // Concurrent host-key approvals and history saves share this helper. Queue
  // snapshots by path so one write cannot rename another's temporary file or
  // replace a newer snapshot with an older one that finished writing later.
  final previous = _pendingWrites[path] ?? Future<void>.value();
  final write = previous.then(
    (_) => _writeStringAtomically(file, contents, privacy),
  );
  late final Future<void> tail;
  tail = write.then<void>((_) {}, onError: (Object _, StackTrace __) {})
      .whenComplete(() {
    if (identical(_pendingWrites[path], tail)) _pendingWrites.remove(path);
  });
  _pendingWrites[path] = tail;
  return write;
}

Future<void> _writeStringAtomically(
    File file, String contents, AtomicFilePrivacy privacy) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  // Create the file empty first so a restricted write never materializes its
  // contents under the default mode first.
  await tmp.create();
  if (privacy == AtomicFilePrivacy.ownerOnly) {
    restrictFileToOwner(tmp);
  }
  await tmp.writeAsString(contents, flush: true);
  try {
    await tmp.rename(file.path);
  } on FileSystemException {
    if (!Platform.isWindows) rethrow;
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
