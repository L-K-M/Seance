import 'dart:io';

import 'package:flutter/foundation.dart';

/// What [SandboxMigration.run] did.
enum SandboxMigrationOutcome {
  /// This install already has data where the app now looks. Nothing to do —
  /// the overwhelmingly common case, on every platform and every launch after
  /// the first unsandboxed one.
  notNeeded,

  /// Nothing was left behind by a sandboxed build: a fresh install, or any
  /// platform that never had a container.
  noLegacyData,

  /// A sandboxed build's data was copied out of its container.
  migrated,

  /// The copy was attempted and failed. Startup must not continue: see
  /// [SandboxMigrationFailure].
  failed,
}

/// Thrown when the container copy failed, to stop startup dead.
///
/// Carrying on would be the worst of the available outcomes. The app would
/// find an empty support directory, mint a `deviceId`, write `settings.json`
/// — and that write is enough to make the next launch believe the directory
/// is already in use, so the retry this failure needs could never happen. The
/// container would be stranded for good by the very attempt to recover it.
///
/// Refusing to start leaves every byte where it was and makes "quit and
/// reopen" true rather than reassuring.
class SandboxMigrationFailure implements Exception {
  final Directory container;
  final Object cause;

  const SandboxMigrationFailure(this.container, this.cause);

  @override
  String toString() =>
      'Séance could not move your data out of its old macOS app container, so '
      'it stopped rather than start empty and leave the data stranded there. '
      'Nothing has been deleted — it is all still in ${container.path}. This '
      'is usually a full disk or a permissions problem; fix that and reopen '
      'Séance. (Underlying error: $cause)';
}

/// Moves an install's data out of the macOS App Sandbox container it used to
/// live in.
///
/// Dropping `com.apple.security.app-sandbox` relocates `NSHomeDirectory()`,
/// which relocates everything `getApplicationSupportDirectory()` returns:
///
/// ```text
/// ~/Library/Containers/<bundle id>/Data/Library/Application Support/<bundle id>   (sandboxed)
/// ~/Library/Application Support/<bundle id>                                       (not)
/// ```
///
/// Without this an existing install launches looking like a fresh one — no
/// servers, no snippets, no sync, and a newly minted `deviceId` that re-enters
/// sync as a stranger. Nothing would be lost, but nothing would be reachable
/// either.
///
/// The whole tree is copied to a staging directory *beside* the destination
/// and then put in place with a single directory rename. That makes the
/// visible result all-or-nothing: the destination is either untouched or
/// complete, never partly filled. It matters because "partly filled" is
/// indistinguishable from "already in use" on the next launch, which would
/// strand whatever had not been copied yet — permanently, and silently.
///
/// The container is copied, never moved. If any of this is wrong, the original
/// is still exactly where a sandboxed build would look for it.
class SandboxMigration {
  /// Where the app reads its data now.
  final Directory support;

  /// Where a sandboxed build of this app would have kept it.
  final Directory legacySupport;

  /// Scratch space beside [support] — not inside it, so [support] stays empty
  /// right up to the rename that fills it in one step.
  final Directory staging;

  /// How one file is copied.
  ///
  /// Injectable only so a mid-copy failure — the case this whole design exists
  /// for — can be exercised. It cannot be provoked with permissions, because
  /// CI and the dev container run as root, where a `chmod` keeps nothing out.
  @visibleForTesting
  final Future<void> Function(File from, String to) copyFile;

  SandboxMigration({
    required this.support,
    required this.legacySupport,
    @visibleForTesting Future<void> Function(File from, String to)? copyFile,
  })  : staging = Directory(
          '${support.parent.path}${Platform.pathSeparator}$stagingName',
        ),
        copyFile = copyFile ?? _copyOneFile;

  static Future<void> _copyOneFile(File from, String to) async {
    await from.copy(to);
  }

  static const String stagingName = '.seance-sandbox-migration';

  /// The migration implied by an application-support directory, or null when
  /// this platform has no container to migrate from.
  ///
  /// The bundle identifier is read off [support]'s own last path segment
  /// rather than a platform channel or a constant: `path_provider` builds that
  /// directory as `…/Application Support/<bundle id>`, so it is already the
  /// answer, and a hard-coded copy could silently drift from the Xcode config.
  static SandboxMigration? forSupportDirectory(
    Directory support, {
    String? home,
    bool? isMacOS,
  }) {
    if (!(isMacOS ?? Platform.isMacOS)) return null;
    final realHome = home ?? Platform.environment['HOME'] ?? '';
    if (realHome.isEmpty) return null;
    final bundleId = support.path.split(Platform.pathSeparator).last;
    if (bundleId.isEmpty) return null;
    return SandboxMigration(
      support: support,
      legacySupport: Directory(
        '$realHome/Library/Containers/$bundleId/Data'
        '/Library/Application Support/$bundleId',
      ),
    );
  }

  /// The error behind a [SandboxMigrationOutcome.failed] run. Null otherwise.
  Object? get error => _error;
  Object? _error;

  Future<SandboxMigrationOutcome> run() async {
    try {
      // A leftover staging directory means a previous run died before its
      // rename. Its contents are a partial copy of the container, so they are
      // dropped rather than trusted.
      if (await staging.exists()) await staging.delete(recursive: true);

      if (await _hasData(support)) return SandboxMigrationOutcome.notNeeded;
      if (!await _hasData(legacySupport)) {
        return SandboxMigrationOutcome.noLegacyData;
      }

      await staging.create(recursive: true);
      await _copyInto(legacySupport, staging);

      // Anything already sitting in the destination is not ours — a stray
      // .DS_Store is the realistic case — but `rename` onto a directory needs
      // that directory empty, so carry it across rather than delete it.
      //
      // Listed to completion first. `list` streams `readdir`, and removing
      // entries mid-stream can silently skip others: with two dot-files, one
      // could be left behind, the rename below would fail ENOTEMPTY, and a
      // migration that was about to succeed would instead refuse to launch.
      //
      // Guarded on existence because listing a directory that is not there
      // throws. `getApplicationSupportDirectory` documents that it creates the
      // directory, so this should be unreachable — but the cost of being wrong
      // is that nobody can start the app, and the cost of the guard is a line.
      // The rename below handles a missing destination on its own: its parent
      // exists, because staging was created in it.
      if (await support.exists()) {
        final strays = await support.list(followLinks: false).toList();
        for (final entry in strays) {
          final name = entry.path.split(Platform.pathSeparator).last;
          await entry.rename('${staging.path}${Platform.pathSeparator}$name');
        }
      }
      // The one step that changes what the app can see. POSIX `rename` over an
      // empty directory is atomic, so there is no moment at which the support
      // directory holds half an install.
      //
      // Something appearing in the destination between that listing and this
      // line — Finder writing a .DS_Store as the user watches the folder —
      // fails it with ENOTEMPTY. That is caught below and reported as a
      // failure, and the next launch treats the newcomer as one more stray and
      // carries it across, so the race costs a relaunch rather than the data.
      await staging.rename(support.path);
      return SandboxMigrationOutcome.migrated;
    } catch (error, stackTrace) {
      _error = error;
      debugPrint('Sandbox-container migration failed: $error\n$stackTrace');
      // Leave nothing half-done behind; the container still holds everything.
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {
        // Best effort — a stale staging directory is dropped on the next run.
      }
      return SandboxMigrationOutcome.failed;
    }
  }

  /// Whether [directory] holds anything the app put there.
  ///
  /// Dot-entries do not count: a `.DS_Store` from someone opening the folder
  /// in Finder must not read as "this install is in use" and block a migration
  /// forever. Nothing Séance writes starts with a dot.
  static Future<bool> _hasData(Directory directory) async {
    if (!await directory.exists()) return false;
    await for (final entry in directory.list(followLinks: false)) {
      if (!entry.path.split(Platform.pathSeparator).last.startsWith('.')) {
        return true;
      }
    }
    return false;
  }

  Future<void> _copyInto(Directory from, Directory to) async {
    await for (final entry in from.list(followLinks: false)) {
      final name = entry.path.split(Platform.pathSeparator).last;
      final target = '${to.path}${Platform.pathSeparator}$name';
      if (entry is Directory) {
        await Directory(target).create(recursive: true);
        await _copyInto(entry, Directory(target));
      } else if (entry is File) {
        await copyFile(entry, target);
      }
      // Links are skipped deliberately: nothing in this tree creates one, and
      // following an unexpected link would copy from outside the container.
    }
  }
}
