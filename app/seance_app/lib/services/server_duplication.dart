import 'package:seance_core/seance_core.dart';

import 'app_settings.dart';

/// The label a copy of [label] should take, given the labels already [taken].
///
/// Duplicating a duplicate gives "web copy 2" rather than "web copy copy": the
/// suffix is parsed back off before it is re-applied, so a row of copies reads
/// as a numbered series instead of a stutter. Matching is case-insensitive
/// because the list sorts that way — two labels differing only in case are the
/// same name in the place the user reads them.
///
/// Nothing enforces unique labels; this only avoids handing the user two rows
/// they cannot tell apart, which is the whole reason a copy needs a new name.
String duplicateServerLabel(String label, Iterable<String> taken) {
  final used = {
    for (final name in taken) name.trim().toLowerCase(),
  };
  final base = _withoutCopySuffix(label.trim());
  // Trimmed because `base` is empty for a server named "copy" (and for an
  // unnamed one), which would otherwise leave the candidate leading-spaced.
  // Terminates: `used` is finite, so some `n` is free.
  for (var n = 1; ; n++) {
    final candidate = (n == 1 ? '$base copy' : '$base copy $n').trim();
    if (!used.contains(candidate.toLowerCase())) return candidate;
  }
}

/// The trailing "copy" / "copy 3" a previous duplication left behind. Anchored
/// at a word start as well as at a space so a server *named* "copy" is
/// recognized as one too — that leaves an empty base, which
/// [duplicateServerLabel] then numbers as "copy", "copy 2", … rather than
/// stuttering. `RegExp` has no inline `(?i)`; case-insensitivity is a flag.
final RegExp _copySuffix =
    RegExp(r'(^|\s+)copy(\s+\d+)?$', caseSensitive: false);

/// Strips repeatedly, because one pass leaves the stutter it exists to
/// prevent: a server hand-named "web copy 2 copy" reduces to "web copy 2",
/// whose first candidate is the taken name it started from, so the duplicate
/// lands on "web copy 2 copy 2". Stripping to "web" gives the next free
/// number instead. Terminating, since each pass either shortens the string
/// or returns.
String _withoutCopySuffix(String label) {
  var base = label.trim();
  while (true) {
    final stripped = base.replaceFirst(_copySuffix, '').trim();
    if (stripped == base) return base;
    base = stripped;
  }
}

/// [source] as a new server: its own id, its own timestamps, a [label] of its
/// own, and a [secretRef] pointing at its own copy of the credential.
///
/// Everything else is carried over deliberately, including
/// [ServerConfig.excludeFromSync] — a copy of a server the user keeps off the
/// sync server starts off it too, which is the direction that cannot surprise
/// anyone — and [ServerConfig.identityFilePath], which is a reference to a file
/// on disk rather than key material and is as valid for the copy as for the
/// original.
///
/// The credential is *copied*, never shared by pointing both configs at one
/// vault entry. Sharing would be cheaper and wrong in three separate ways:
/// deleting either server deletes the credential out from under the other
/// (nothing reference-counts vault entries), editing either rewrites it in
/// place, and the sync layer keys a secret record by the secret's id while
/// stamping it with the *server's* `updatedAt` — so two owners would push two
/// versions of one record, and one owner's "don't sync this credential" would
/// not stop the other from uploading it.
ServerConfig duplicateServerConfig(
  ServerConfig source, {
  required String id,
  required String label,
  required String? secretRef,
  required int now,
}) => ServerConfig(
  id: id,
  label: label,
  host: source.host,
  port: source.port,
  username: source.username,
  authMethod: source.authMethod,
  secretRef: secretRef,
  identityFilePath: source.identityFilePath,
  jumpHostId: source.jumpHostId,
  syncSecret: source.syncSecret,
  group: source.group,
  color: source.color,
  icon: source.icon,
  loginScript: source.loginScript,
  excludeFromSync: source.excludeFromSync,
  // A copy is new, not as old as what it was copied from: `createdAt` is what
  // "added on" would report, and the answer is today.
  createdAt: now,
  updatedAt: now,
);

/// A planned duplicate: the config to store, the vault entry to write first
/// when the source had a credential to copy, and the security-scope grant to
/// file under the copy's id.
class ServerDuplication {
  final ServerConfig config;
  final Secret? secret;

  /// The source's grant for its identity file, to be stored under the copy's
  /// id. Carried through the plan rather than read at the save site so the
  /// one line this feature's doc calls load-bearing is reachable by a test:
  /// without it a duplicate of a Browse…-picked key falls back to the raw
  /// path and cannot open a key outside `~/.ssh`.
  final IdentityFileBookmark? identityFileBookmark;

  const ServerDuplication({
    required this.config,
    this.secret,
    this.identityFileBookmark,
  });
}

/// Work out what duplicating [source] takes, without writing anything.
///
/// Separated from the notifier that saves it because this is the part that can
/// lose a credential, and orchestration left inside an `AppState` is
/// orchestration nothing can exercise — no test in this app can build an
/// `AppServices`, whose constructor is private. The ids and the clock are
/// arguments for the same reason.
///
/// A dangling [ServerConfig.secretRef] — the config points at a vault entry
/// that is gone — plans as "no credential" rather than failing: the original
/// is already in that state, and the copy is not the place to discover it. A
/// vault that *throws*, which is what a locked OS keyring does, propagates
/// instead: a duplicate that quietly lost its password would look identical in
/// the list and only admit it at connect time.
Future<ServerDuplication> planServerDuplication(
  ServerConfig source, {
  required SecretVault vault,
  required Iterable<String> takenLabels,
  required String id,
  required String secretId,
  required int now,
  IdentityFileBookmark? Function(String serverId)? bookmarkFor,
}) async {
  Secret? secret;
  final sourceRef = source.secretRef;
  if (sourceRef != null) {
    final original = await vault.getSecret(sourceRef);
    // copyWith rather than a fresh constructor: listing the fields here would
    // silently drop anything Secret gains later, which is the same failure
    // duplicateServerConfig's JSON-compared test exists to catch for configs.
    if (original != null) secret = original.copyWith(id: secretId);
  }
  return ServerDuplication(
    config: duplicateServerConfig(
      source,
      id: id,
      label: duplicateServerLabel(source.label, takenLabels),
      secretRef: secret?.id,
      now: now,
    ),
    secret: secret,
    identityFileBookmark: bookmarkFor?.call(source.id),
  );
}
