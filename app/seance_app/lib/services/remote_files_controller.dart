import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

import 'managed_remote_file.dart';
import 'managed_remote_file_store.dart';

enum RemoteTransferDirection { upload, download }

enum RemoteTransferStatus { running, completed, failed, cancelled }

enum RemoteSortField { name, size, modifiedAt, type }

enum RemoteSortDirection { ascending, descending }

class RemoteTransferItem {
  final String id;
  final String name;
  final RemoteTransferDirection direction;
  int? total;
  final RemoteTransferCancellation cancellation;
  int transferred = 0;
  RemoteTransferStatus status = RemoteTransferStatus.running;
  String? error;

  RemoteTransferItem({
    required this.id,
    required this.name,
    required this.direction,
    required this.total,
    required this.cancellation,
  });

  double? get progress => total == null || total == 0
      ? null
      : (transferred / total!).clamp(0, 1).toDouble();
}

/// Session-scoped navigation and transfer state. Platform pickers and external
/// application launching stay in the Files UI; this controller only consumes
/// byte streams and local paths handed to it.
class RemoteFilesController extends ChangeNotifier {
  final Future<RemoteFileSystem> Function() _openRemoteFileSystem;
  final ValueListenable<String?> shellDirectory;
  final ValueListenable<String?> terminalTitle;
  final ValueListenable<String?> activeCommand;
  final ManagedRemoteFileStore managedFileStore;
  final String serverId;
  final String editSessionId;
  final Future<void> Function(List<String>)? saveBookmarks;
  final Future<void> Function(bool)? saveShowHidden;

  RemoteFilesController(
    this._openRemoteFileSystem, {
    required this.shellDirectory,
    required this.managedFileStore,
    required this.serverId,
    required this.editSessionId,
    Iterable<String> initialBookmarks = const [],
    this.saveBookmarks,
    bool initialShowHidden = true,
    this.saveShowHidden,
    ValueListenable<String?>? terminalTitle,
    ValueListenable<String?>? activeCommand,
    Map<String, ManagedRemoteFile>? initialLocalCopies,
  }) : terminalTitle = terminalTitle ?? const _EmptyStringListenable(),
       activeCommand = activeCommand ?? const _EmptyStringListenable() {
    if (initialLocalCopies != null) localCopies.addAll(initialLocalCopies);
    showHidden = initialShowHidden;
    bookmarks.addAll(initialBookmarks.where(_isAbsolutePath));
    shellDirectory.addListener(_followShellDirectory);
    this.terminalTitle.addListener(_followShellDirectory);
    this.activeCommand.addListener(_followActiveCommand);
  }

  RemoteFileSystem? _remoteFileSystem;
  Future<void>? _initializing;
  int _navigationGeneration = 0;
  int _nextTransferId = 0;
  bool _disposed = false;
  bool _localCopiesLoaded = false;
  final Map<String, StreamSubscription<FileSystemEvent>> _checkoutWatches = {};
  final Map<String, Timer> _checkoutDebounces = {};
  final Map<String, Future<ManagedRemoteFile>> _checkoutFlights = {};
  String? _lastCommand;
  Timer? _remoteSnapshotDebounce;
  int _remoteSnapshotGeneration = 0;

  /// Collapses a burst of finished shell commands (a pasted multi-line
  /// script) into one re-stat pass over the managed copies.
  static const Duration _remoteSnapshotDebounceDelay = Duration(
    milliseconds: 350,
  );

  bool initialized = false;
  bool loading = false;
  bool followTerminal = true;
  String? homePath;
  String? currentPath;
  String? error;
  List<RemoteFileEntry> _allEntries = const [];
  List<RemoteFileEntry> entries = const [];
  RemoteSortField sortField = RemoteSortField.name;
  RemoteSortDirection sortDirection = RemoteSortDirection.ascending;
  bool showHidden = true;
  String filterQuery = '';
  final Set<String> selectedPaths = {};
  final List<String> bookmarks = [];
  final List<RemoteTransferItem> transfers = [];
  final Map<String, ManagedRemoteFile> localCopies = {};

  /// The freshest server stat seen for each managed remote path: an entry
  /// when the file exists, null once it is known to be gone, absent until a
  /// check has looked. Compared against a copy's `remoteSnapshot` it answers
  /// [remoteChangedFor].
  final Map<String, RemoteFileEntry?> latestRemoteSnapshots = {};

  Future<void> initialize() {
    if (initialized) return Future.value();
    return _initializing ??= _initialize().whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize() async {
    loading = true;
    error = null;
    _notify();
    try {
      await _restoreLocalCopies();
      final remote = await _openRemoteFileSystem();
      if (_disposed) return;
      _remoteFileSystem = remote;
      homePath = await remote.canonicalize('.');
      if (_disposed) return;
      initialized = true;
      final shellPath = reportedShellDirectory;
      await navigate(
        followTerminal && _isAbsolutePath(shellPath) ? shellPath! : homePath!,
      );
    } catch (e) {
      if (_disposed) return;
      error = e.toString();
    } finally {
      if (!_disposed) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> navigate(String path) async {
    final remote = _remoteFileSystem;
    if (remote == null) {
      await initialize();
      return;
    }
    final generation = ++_navigationGeneration;
    loading = true;
    error = null;
    _notify();
    try {
      final canonical = await remote.canonicalize(path);
      final next = await remote.listDirectory(canonical);
      if (_disposed || generation != _navigationGeneration) return;
      currentPath = canonical;
      _allEntries = List.unmodifiable(next);
      selectedPaths.clear();
      // A fresh listing doubles as a freshness check for managed copies in
      // this directory — no extra round trips needed.
      for (final entry in next) {
        if (localCopies.containsKey(entry.path)) {
          latestRemoteSnapshots[entry.path] = entry;
        }
      }
      _applyEntryView();
    } catch (e) {
      if (_disposed || generation != _navigationGeneration) return;
      error = e.toString();
    } finally {
      if (!_disposed && generation == _navigationGeneration) {
        loading = false;
        _notify();
      }
    }
  }

  /// Whether [goUp] has somewhere to go: false at the root, and before the
  /// first listing has landed.
  bool get canGoUp {
    final path = currentPath;
    return path != null && remoteParent(path) != path;
  }

  Future<void> goUp() {
    final path = currentPath;
    return path == null ? Future.value() : navigate(remoteParent(path));
  }

  Future<void> goHome() {
    final path = homePath;
    return path == null ? Future.value() : navigate(path);
  }

  Future<void> refresh() {
    final path = currentPath;
    return path == null ? initialize() : navigate(path);
  }

  void setFilterQuery(String value) {
    if (filterQuery == value) return;
    filterQuery = value;
    _applyEntryView();
    _notify();
  }

  void setShowHidden(bool value) {
    if (showHidden == value) return;
    showHidden = value;
    _applyEntryView();
    _notify();
    unawaited(saveShowHidden?.call(value));
  }

  void setSort(RemoteSortField field, RemoteSortDirection direction) {
    if (sortField == field && sortDirection == direction) return;
    sortField = field;
    sortDirection = direction;
    _applyEntryView();
    _notify();
  }

  void toggleSelection(String path) {
    if (selectedPaths.remove(path)) {
      _notify();
      return;
    }
    if (_allEntries.any((entry) => entry.path == path)) {
      selectedPaths.add(path);
      _notify();
    }
  }

  void clearSelection() {
    if (selectedPaths.isEmpty) return;
    selectedPaths.clear();
    _notify();
  }

  List<RemoteFileEntry> get selectedEntries => [
    for (final entry in _allEntries)
      if (selectedPaths.contains(entry.path)) entry,
  ];

  bool get currentPathBookmarked => bookmarks.contains(currentPath);

  Future<void> toggleCurrentBookmark() async {
    final path = currentPath;
    if (!_isAbsolutePath(path)) return;
    if (!bookmarks.remove(path)) bookmarks.add(path!);
    bookmarks.sort();
    _notify();
    await saveBookmarks?.call(List.unmodifiable(bookmarks));
  }

  Future<void> removeBookmark(String path) async {
    if (!bookmarks.remove(path)) return;
    _notify();
    await saveBookmarks?.call(List.unmodifiable(bookmarks));
  }

  void setFollowTerminal(bool value) {
    if (followTerminal == value) return;
    followTerminal = value;
    _notify();
    if (value) _followShellDirectory();
  }

  /// OSC 7 is authoritative. Ubuntu/Debian's default Bash setup commonly emits
  /// only an OSC 0 title such as `root@host: ~/docker`, so resolve that against
  /// the SFTP home as a conservative fallback.
  String? get reportedShellDirectory {
    final oscDirectory = shellDirectory.value;
    if (_isAbsolutePath(oscDirectory)) return oscDirectory;

    final home = homePath;
    final title = terminalTitle.value?.trim();
    if (home == null || title == null) return null;
    final separator = title.indexOf(': ');
    if (separator < 1 || !title.substring(0, separator).contains('@')) {
      return null;
    }
    final location = title.substring(separator + 2).trim();
    if (location == '~' || location == '~/') return home;
    if (location.startsWith('~/')) {
      final relative = location.substring(2);
      return relative.isEmpty ? home : remoteJoin(home, relative);
    }
    return _isAbsolutePath(location) ? location : null;
  }

  Future<void> createDirectory(String name) async {
    final remote = _requireRemote();
    final path = remoteJoin(_requireCurrentPath(), _validateName(name));
    await remote.createDirectory(path);
    await refresh();
  }

  Future<void> createSymbolicLink(String name, String target) async {
    final linkPath = remoteJoin(_requireCurrentPath(), _validateName(name));
    if (target.isEmpty || target.contains('\u0000')) {
      throw const FormatException('Enter a valid symbolic-link target.');
    }
    await _requireRemote().createSymbolicLink(linkPath, target);
    await refresh();
  }

  Future<String> readSymbolicLink(RemoteFileEntry entry) {
    if (!entry.isSymbolicLink) {
      throw StateError('The remote item is not a symbolic link.');
    }
    return _requireRemote().readSymbolicLink(entry.path);
  }

  Future<void> setMode(RemoteFileEntry entry, int permissions) async {
    if (entry.isSymbolicLink) {
      throw StateError('SFTP cannot safely change a symbolic link mode.');
    }
    await _requireRemote().setMode(entry.path, permissions);
    await refresh();
  }

  Future<void> renameEntry(RemoteFileEntry entry, String newName) async {
    final remote = _requireRemote();
    final target = remoteJoin(remoteParent(entry.path), _validateName(newName));
    if (target == entry.path) return;
    await remote.rename(entry.path, target);
    final affected = localCopies.entries
        .where(
          (item) =>
              item.key == entry.path ||
              (entry.isDirectory && item.key.startsWith('${entry.path}/')),
        )
        .toList();
    for (final item in affected) {
      localCopies.remove(item.key);
      final nextPath = target + item.key.substring(entry.path.length);
      final updated = item.value.copyWith(
        remotePath: nextPath,
        remoteSnapshot: _copyEntry(item.value.remoteSnapshot, nextPath),
      );
      localCopies[nextPath] = updated;
      // A present-null means "known missing on the server" — containsKey
      // carries it across the rename where a != null check would drop it.
      if (latestRemoteSnapshots.containsKey(item.key)) {
        latestRemoteSnapshots[nextPath] = latestRemoteSnapshots.remove(
          item.key,
        );
      }
      await managedFileStore.update(updated);
    }
    await refresh();
  }

  Future<void> deleteEntry(RemoteFileEntry entry) async {
    await _requireRemote().delete(entry);
    // A managed checkout may contain the only copy of unuploaded edits. Keep it
    // recoverable; the user can explicitly discard or upload it again.
    await refresh();
  }

  Future<RemoteFileEntry> upload({
    required String name,
    required Stream<List<int>> content,
    required int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    String? directory,
  }) async {
    final path = remoteJoin(
      directory ?? _requireCurrentPath(),
      _validateName(name),
    );
    return _runUpload(
      path: path,
      displayName: name,
      content: content,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
    );
  }

  Future<RemoteFileEntry> _runUpload({
    required String path,
    required String displayName,
    required Stream<List<int>> content,
    required int? length,
    required bool overwrite,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
  }) async {
    final transfer = _startTransfer(
      name: displayName,
      direction: RemoteTransferDirection.upload,
      total: length,
    );
    try {
      final result = await _requireRemote().upload(
        path,
        content,
        length: length,
        overwrite: overwrite,
        preserveMode: preserveMode,
        expectedTarget: expectedTarget,
        cancellation: transfer.cancellation,
        onProgress: (done, total) => _updateProgress(transfer, done, total),
      );
      transfer.status = RemoteTransferStatus.completed;
      await refresh();
      return result;
    } catch (e) {
      _failTransfer(transfer, e);
      rethrow;
    } finally {
      _notify();
    }
  }

  Future<RemoteFileEntry> download(
    RemoteFileEntry entry,
    StreamSink<List<int>> destination,
  ) async {
    final transfer = _startTransfer(
      name: entry.name,
      direction: RemoteTransferDirection.download,
      total: entry.size,
    );
    try {
      final snapshot = await _requireRemote().download(
        entry.path,
        destination,
        cancellation: transfer.cancellation,
        onProgress: (done, total) => _updateProgress(transfer, done, total),
      );
      transfer.status = RemoteTransferStatus.completed;
      return snapshot;
    } catch (e) {
      _failTransfer(transfer, e);
      rethrow;
    } finally {
      _notify();
    }
  }

  /// Recursively uploads one local directory without following local symlinks.
  /// Completed files remain if cancellation or a later file fails; each file is
  /// still committed through the adapter's temporary-upload rename.
  Future<void> uploadDirectory(
    Directory source, {
    String? directory,
    bool overwriteExisting = false,
  }) async {
    final rootName = _validatePathComponent(
      source.absolute.path.split(Platform.pathSeparator).last,
    );
    final targetRoot = remoteJoin(directory ?? _requireCurrentPath(), rootName);
    final localRoot = source.absolute.path;
    final directories = <String>[];
    final files = <(File, String, int)>[];
    final transfer = _startTransfer(
      name: rootName,
      direction: RemoteTransferDirection.upload,
      total: null,
    );
    var completedBytes = 0;
    try {
      await for (final entity in source.list(
        recursive: true,
        followLinks: false,
      )) {
        transfer.cancellation.throwIfCancelled();
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.link) continue;
        final relative = entity.absolute.path.substring(localRoot.length);
        final components = relative
            .split(Platform.pathSeparator)
            .where((part) => part.isNotEmpty)
            .map(_validatePathComponent)
            .toList();
        if (components.isEmpty) continue;
        final remotePath = components.fold<String>(
          targetRoot,
          (path, component) => remoteJoin(path, component),
        );
        if (type == FileSystemEntityType.directory) {
          directories.add(remotePath);
        } else if (type == FileSystemEntityType.file) {
          final file = File(entity.path);
          files.add((file, remotePath, await file.length()));
        }
      }
      directories.sort((a, b) => a.length.compareTo(b.length));
      final total = files.fold<int>(0, (sum, item) => sum + item.$3);
      transfer.total = total;
      _notify();
      await _ensureRemoteDirectory(targetRoot);
      for (final path in directories) {
        transfer.cancellation.throwIfCancelled();
        await _ensureRemoteDirectory(path);
      }
      for (final item in files) {
        transfer.cancellation.throwIfCancelled();
        RemoteFileEntry? existing;
        try {
          existing = await _requireRemote().stat(item.$2, followLinks: false);
        } on RemoteFileException catch (error) {
          if (error.kind != RemoteFileErrorKind.notFound) rethrow;
        }
        if (existing != null && !overwriteExisting) {
          completedBytes += item.$3;
          _updateProgress(transfer, completedBytes, total);
          continue;
        }
        await _requireRemote().upload(
          item.$2,
          item.$1.openRead(),
          length: item.$3,
          overwrite: existing != null,
          expectedTarget: existing,
          cancellation: transfer.cancellation,
          onProgress: (done, _) {
            _updateProgress(transfer, completedBytes + done, total);
          },
        );
        completedBytes += item.$3;
      }
      transfer.status = RemoteTransferStatus.completed;
      await refresh();
    } catch (error) {
      _failTransfer(transfer, error);
      rethrow;
    } finally {
      _notify();
    }
  }

  /// Downloads files/directories into [destination] with one aggregate
  /// transfer. Remote symlinks are skipped instead of followed.
  Future<void> downloadEntries(
    Iterable<RemoteFileEntry> roots,
    Directory destination, {
    bool overwriteExisting = false,
  }) async {
    final rootEntries = roots.toList();
    final directories = <String>[];
    final files = <_RemoteDownloadPlan>[];
    final plannedLocalPaths = <String>{};
    final transfer = _startTransfer(
      name: rootEntries.length == 1
          ? rootEntries.first.name
          : '${rootEntries.length} items',
      direction: RemoteTransferDirection.download,
      total: null,
    );

    Future<void> scan(RemoteFileEntry entry, String relativePath) async {
      transfer.cancellation.throwIfCancelled();
      if (entry.isSymbolicLink) return;
      final safeName = _validateLocalName(entry.name);
      final safeRelative = relativePath.isEmpty
          ? safeName
          : '$relativePath${Platform.pathSeparator}$safeName';
      final collisionKey = Platform.isWindows
          ? safeRelative.toLowerCase()
          : safeRelative;
      if (!plannedLocalPaths.add(collisionKey)) {
        throw StateError(
          'Two remote items map to the same local path: "$safeRelative".',
        );
      }
      if (entry.isDirectory) {
        directories.add(safeRelative);
        final children = await _requireRemote().listDirectory(entry.path);
        for (final child in children) {
          await scan(child, safeRelative);
        }
      } else if (entry.type == RemoteFileType.file) {
        files.add(_RemoteDownloadPlan(entry, safeRelative));
      }
    }

    var completedBytes = 0;
    try {
      for (final root in rootEntries) {
        await scan(root, '');
      }
      final total = files.fold<int>(
        0,
        (sum, item) => sum + (item.entry.size ?? 0),
      );
      transfer.total = total;
      _notify();
      await _ensureSafeLocalDirectory(destination, '');
      for (final relative in directories) {
        transfer.cancellation.throwIfCancelled();
        await _ensureSafeLocalDirectory(destination, relative);
      }
      for (final plan in files) {
        transfer.cancellation.throwIfCancelled();
        final local = File(
          '${destination.path}${Platform.pathSeparator}${plan.relativePath}',
        );
        final parentRelative = remoteParent(
          plan.relativePath.replaceAll(Platform.pathSeparator, '/'),
        );
        await _ensureSafeLocalDirectory(
          destination,
          parentRelative == '.'
              ? ''
              : parentRelative.replaceAll('/', Platform.pathSeparator),
        );
        if (await local.exists() && !overwriteExisting) {
          completedBytes += plan.entry.size ?? 0;
          _updateProgress(transfer, completedBytes, total);
          continue;
        }
        final partial = File('${local.path}.seance-${uuidV4()}.part');
        IOSink? sink;
        try {
          await partial.create(exclusive: true);
          sink = partial.openWrite();
          await _requireRemote().download(
            plan.entry.path,
            sink,
            cancellation: transfer.cancellation,
            onProgress: (done, _) {
              _updateProgress(transfer, completedBytes + done, total);
            },
          );
          await sink.flush();
          await sink.close();
          sink = null;
          await _replaceLocalFile(partial, local);
          completedBytes += plan.entry.size ?? await local.length();
        } finally {
          await sink?.close();
          if (await partial.exists()) await partial.delete();
        }
      }
      transfer.status = RemoteTransferStatus.completed;
    } catch (error) {
      _failTransfer(transfer, error);
      rethrow;
    } finally {
      _notify();
    }
  }

  Future<void> _ensureRemoteDirectory(String path) async {
    try {
      final existing = await _requireRemote().stat(path, followLinks: false);
      if (!existing.isDirectory) {
        throw StateError('A non-directory item already exists at "$path".');
      }
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
      await _requireRemote().createDirectory(path);
    }
  }

  /// Downloads [entry] into the durable app-support checkout area and starts
  /// watching its parent directory so editors that save by atomic replacement
  /// are detected as well as in-place writes.
  ///
  /// An existing checkout is re-validated against the server first: a clean
  /// copy whose remote file changed is refreshed in place, so reopening a
  /// file can never serve stale content. A dirty copy is never overwritten —
  /// [remoteChangedFor] flags the drift and the editor's reload affordance
  /// becomes the deliberate discard path.
  Future<ManagedRemoteFile> checkoutRemoteFile(
    RemoteFileEntry entry, {
    int? maximumBytes,
  }) async {
    var copy = await _checkoutFlights.putIfAbsent(entry.path, () async {
      try {
        final existing = localCopies[entry.path];
        return existing == null
            ? await _checkoutRemoteFile(entry, maximumBytes: maximumBytes)
            : await _refreshExistingCheckout(
                existing,
                maximumBytes: maximumBytes,
              );
      } finally {
        _checkoutFlights.remove(entry.path);
      }
    });
    // A flight joined while its checkout was being discarded can resolve to
    // a copy that is no longer tracked (its local file is gone). Never hand
    // that out — take a fresh flight so the caller gets a live checkout.
    if (!_disposed && localCopies[entry.path]?.id != copy.id) {
      copy = await checkoutRemoteFile(entry, maximumBytes: maximumBytes);
    }
    return copy;
  }

  /// Re-stats an existing checkout's remote path and refreshes the local copy
  /// when the server version moved on. Falls back to the stale copy when the
  /// refresh cannot complete — the recorded drift still lets the editor offer
  /// an explicit reload.
  Future<ManagedRemoteFile> _refreshExistingCheckout(
    ManagedRemoteFile copy, {
    int? maximumBytes,
  }) async {
    // Reconcile before deciding: an external editor's just-finished save must
    // be seen before the server copy is allowed to overwrite the checkout.
    final current = await managedFileStore.reconcile(copy.id) ?? copy;
    if (_disposed) return current;
    if (!identical(current, copy)) {
      localCopies[current.remotePath] = current;
    }
    final RemoteFileEntry latest;
    try {
      latest = await _requireRemote().stat(
        current.remotePath,
        followLinks: false,
      );
    } on RemoteFileException catch (e) {
      if (e.kind == RemoteFileErrorKind.notFound) {
        latestRemoteSnapshots[current.remotePath] = null;
      }
      // Gone or unreachable: keep the local copy — it may hold the only
      // surviving content, and a dead connection must not block reopening.
      _notify();
      return current;
    } catch (_) {
      // Not connected (or a non-standard filesystem failure): same answer.
      return current;
    }
    latestRemoteSnapshots[current.remotePath] = latest;
    if (current.dirty || _sameSnapshot(latest, current.remoteSnapshot)) {
      _notify();
      return current;
    }
    try {
      return await _refreshLocalCopy(current, maximumBytes: maximumBytes);
    } catch (_) {
      return current;
    }
  }

  /// Re-downloads the server copy into the managed checkout, replacing the
  /// local file. Any local edits are discarded — callers confirm first.
  Future<ManagedRemoteFile> refreshLocalCopy(
    String remotePath, {
    int? maximumBytes,
  }) async {
    final copy = localCopies[remotePath];
    if (copy == null) {
      throw StateError('No managed local copy of "$remotePath" exists.');
    }
    return _checkoutFlights.putIfAbsent(remotePath, () async {
      try {
        return await _refreshLocalCopy(copy, maximumBytes: maximumBytes);
      } finally {
        _checkoutFlights.remove(remotePath);
      }
    });
  }

  Future<ManagedRemoteFile> _refreshLocalCopy(
    ManagedRemoteFile copy, {
    int? maximumBytes,
  }) async {
    final local = localFile(copy);
    final partial = File('${local.path}.seance-${uuidV4()}.part');
    IOSink? sink;
    try {
      final latest = await _requireRemote().stat(
        copy.remotePath,
        followLinks: false,
      );
      sink = partial.openWrite();
      final snapshot = await download(
        latest,
        maximumBytes == null ? sink : _MaximumByteSink(sink, maximumBytes),
      );
      await sink.flush();
      await sink.close();
      sink = null;
      // The copy may have been discarded, migrated via takeLocalCopies, or
      // the whole controller disposed while the download was in flight —
      // finishing now would resurrect it. Keyed on identity, not path
      // presence: a same-path re-checkout during the download must not let
      // this stale copy clobber the new one.
      if (_disposed || localCopies[copy.remotePath]?.id != copy.id) {
        if (await partial.exists()) await partial.delete();
        return copy;
      }
      await _replaceLocalFile(partial, local);
      final updated = copy.copyWith(
        remoteSnapshot: snapshot,
        baselineSha256: await streamedFileSha256(local),
        dirty: false,
        missing: false,
      );
      await managedFileStore.update(updated);
      localCopies[copy.remotePath] = updated;
      latestRemoteSnapshots[copy.remotePath] = snapshot;
      _checkoutDebounces.remove(copy.id)?.cancel();
      _notify();
      return updated;
    } catch (_) {
      await sink?.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  /// Re-stats one managed path so [remoteChangedFor] reflects the present
  /// server state. Best effort: failures keep the previous answer. Waits for
  /// a still-running [initialize] so a check issued before the channel is up
  /// still lands.
  Future<void> checkRemoteSnapshot(String remotePath) async {
    if (_remoteFileSystem == null) {
      try {
        await initialize();
      } catch (_) {
        return;
      }
    }
    final remote = _remoteFileSystem;
    if (remote == null) return;
    try {
      latestRemoteSnapshots[remotePath] = await remote.stat(
        remotePath,
        followLinks: false,
      );
    } on RemoteFileException catch (e) {
      if (e.kind == RemoteFileErrorKind.notFound) {
        latestRemoteSnapshots[remotePath] = null;
      } else {
        return;
      }
    } catch (_) {
      return;
    }
    _notify();
  }

  /// Whether the server copy is known to differ from what the managed copy
  /// at [remotePath] was checked out against — or is known to be missing.
  /// Null until a freshness check has looked at the path.
  bool? remoteChangedFor(String remotePath) {
    final copy = localCopies[remotePath];
    if (copy == null || !latestRemoteSnapshots.containsKey(remotePath)) {
      return null;
    }
    final latest = latestRemoteSnapshots[remotePath];
    return latest == null || !_sameSnapshot(latest, copy.remoteSnapshot);
  }

  /// Re-stats every managed remote path, refreshing the answers
  /// [remoteChangedFor] gives. Per-path failures keep the previous answer — a
  /// dropped connection must not read as "changed".
  Future<void> refreshRemoteSnapshots() async {
    final remote = _remoteFileSystem;
    if (remote == null || localCopies.isEmpty) return;
    final generation = ++_remoteSnapshotGeneration;
    for (final path in localCopies.keys.toList()) {
      // Publish each stat as it lands — batching into a trailing addAll could
      // overwrite a fresher per-path check that ran mid-loop.
      try {
        latestRemoteSnapshots[path] = await remote.stat(
          path,
          followLinks: false,
        );
      } on RemoteFileException catch (e) {
        if (e.kind == RemoteFileErrorKind.notFound) {
          latestRemoteSnapshots[path] = null;
        }
      } catch (_) {}
      if (_disposed || generation != _remoteSnapshotGeneration) return;
    }
    _notify();
  }

  /// A finished shell command may have rewritten managed files remotely
  /// (pico, sed, git pull, a build script): re-stat them so
  /// [remoteChangedFor] answers from fresh server state. Without OSC 133
  /// [activeCommand] never fires; the open-time and explicit checks remain.
  void _followActiveCommand() {
    final running = activeCommand.value;
    if (running != null) {
      _lastCommand = running;
      return;
    }
    if (_lastCommand == null) return;
    _lastCommand = null;
    _scheduleRemoteSnapshotCheck();
  }

  void _scheduleRemoteSnapshotCheck() {
    if (_disposed || localCopies.isEmpty) return;
    _remoteSnapshotDebounce?.cancel();
    _remoteSnapshotDebounce = Timer(_remoteSnapshotDebounceDelay, () {
      unawaited(refreshRemoteSnapshots());
    });
  }

  Future<ManagedRemoteFile> _checkoutRemoteFile(
    RemoteFileEntry entry, {
    int? maximumBytes,
  }) async {
    if (entry.type != RemoteFileType.file) {
      throw StateError('Only regular remote files can be opened for editing.');
    }
    final id = uuidV4();
    final localPath = managedFileStore.checkoutPathFor(
      id: id,
      fileName: entry.name,
    );
    final local = await managedFileStore.createCheckout(localPath);
    if (Platform.isLinux) {
      await _restrictLinuxPermissions(local.parent.path, '700');
    }
    IOSink? sink;
    try {
      sink = local.openWrite();
      final destination = maximumBytes == null
          ? sink
          : _MaximumByteSink(sink, maximumBytes);
      final snapshot = await download(entry, destination);
      await sink.flush();
      await sink.close();
      sink = null;
      if (Platform.isLinux) {
        await _restrictLinuxPermissions(local.path, '600');
      }
      final copy = ManagedRemoteFile(
        id: id,
        serverId: serverId,
        editSessionId: editSessionId,
        remotePath: snapshot.path,
        localPath: localPath,
        remoteSnapshot: snapshot,
        baselineSha256: await streamedFileSha256(local),
      );
      if (!await trackLocalCopy(copy)) {
        throw StateError('The file session closed before checkout completed.');
      }
      return copy;
    } catch (_) {
      await sink?.close();
      await managedFileStore.deleteCheckout(localPath);
      rethrow;
    }
  }

  Future<bool> trackLocalCopy(ManagedRemoteFile copy) async {
    if (_disposed) {
      await managedFileStore.deleteCheckout(copy.localPath);
      return false;
    }
    await managedFileStore.put(copy);
    if (_disposed) {
      await managedFileStore.remove(copy.id);
      return false;
    }
    localCopies[copy.remotePath] = copy;
    latestRemoteSnapshots[copy.remotePath] = copy.remoteSnapshot;
    _watchCheckout(copy);
    _notify();
    return true;
  }

  File localFile(ManagedRemoteFile copy) =>
      managedFileStore.checkoutFile(copy.localPath);

  Future<void> uploadLocalCopy(
    ManagedRemoteFile copy, {
    bool overwriteRemoteChanges = false,
  }) async {
    final file = localFile(copy);
    final snapshot = File('${file.path}.seance-${uuidV4()}.upload');
    try {
      await file.copy(snapshot.path);
      final uploadedDigest = await streamedFileSha256(snapshot);
      final size = await snapshot.length();
      RemoteFileEntry? latest;
      try {
        latest = await _requireRemote().stat(
          copy.remotePath,
          followLinks: false,
        );
      } on RemoteFileException catch (error) {
        if (error.kind != RemoteFileErrorKind.notFound) rethrow;
      }
      if (!overwriteRemoteChanges &&
          (latest == null || !_sameSnapshot(latest, copy.remoteSnapshot))) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'upload edited copy',
          path: copy.remotePath,
          message:
              '"${remoteBasename(copy.remotePath)}" changed or was deleted on '
              'the server after it was opened locally.',
        );
      }
      final uploaded = await _runUpload(
        path: copy.remotePath,
        displayName: remoteBasename(copy.remotePath),
        content: snapshot.openRead(),
        length: size,
        overwrite: true,
        preserveMode: copy.remoteSnapshot.mode,
        expectedTarget: overwriteRemoteChanges ? null : copy.remoteSnapshot,
      );
      final currentDigest = await streamedFileSha256(file);
      final updated = copy.copyWith(
        remoteSnapshot: uploaded,
        baselineSha256: uploadedDigest,
        dirty: currentDigest != uploadedDigest,
        missing: false,
      );
      await managedFileStore.update(updated);
      localCopies[copy.remotePath] = updated;
      latestRemoteSnapshots[copy.remotePath] = uploaded;
      _notify();
    } finally {
      if (await snapshot.exists()) await snapshot.delete();
    }
  }

  Future<void> removeLocalCopy(String remotePath) async {
    final copy = localCopies[remotePath];
    if (copy == null) return;
    await managedFileStore.remove(copy.id);
    localCopies.remove(remotePath);
    latestRemoteSnapshots.remove(remotePath);
    await _stopWatching(copy.id);
    _notify();
  }

  void cancelTransfer(String id) {
    for (final transfer in transfers) {
      if (transfer.id == id &&
          transfer.status == RemoteTransferStatus.running) {
        transfer.cancellation.cancel();
        return;
      }
    }
  }

  void clearFinishedTransfers() {
    transfers.removeWhere((t) => t.status != RemoteTransferStatus.running);
    _notify();
  }

  RemoteTransferItem _startTransfer({
    required String name,
    required RemoteTransferDirection direction,
    required int? total,
  }) {
    final transfer = RemoteTransferItem(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_nextTransferId++}',
      name: name,
      direction: direction,
      total: total,
      cancellation: RemoteTransferCancellation(),
    );
    transfers.add(transfer);
    _notify();
    return transfer;
  }

  void _updateProgress(
    RemoteTransferItem transfer,
    int transferred,
    int? total,
  ) {
    transfer.transferred = transferred;
    transfer.total = total ?? transfer.total;
    _notify();
  }

  void _failTransfer(RemoteTransferItem transfer, Object failure) {
    final cancelled =
        transfer.cancellation.isCancelled ||
        (failure is RemoteFileException &&
            failure.kind == RemoteFileErrorKind.cancelled);
    transfer.status = cancelled
        ? RemoteTransferStatus.cancelled
        : RemoteTransferStatus.failed;
    transfer.error = failure.toString();
  }

  void _followShellDirectory() {
    final path = reportedShellDirectory;
    if (!initialized || !followTerminal || !_isAbsolutePath(path)) return;
    if (path == currentPath) return;
    unawaited(navigate(path!));
  }

  RemoteFileSystem _requireRemote() {
    final remote = _remoteFileSystem;
    if (remote == null) {
      throw StateError('The remote file browser is not connected.');
    }
    return remote;
  }

  String _requireCurrentPath() {
    final path = currentPath;
    if (path == null) throw StateError('No remote directory is open.');
    return path;
  }

  static String _validateName(String value) {
    final name = value.trim();
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\u0000')) {
      throw const FormatException('Enter a single valid file or folder name.');
    }
    return name;
  }

  static String _validatePathComponent(String value) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains('\u0000')) {
      throw FormatException('"$value" is not a safe path component.');
    }
    return value;
  }

  static String _validateLocalName(String value) {
    final name = _validatePathComponent(value);
    if (RegExp(r'[\\:*?"<>|\x00-\x1f\x7f]').hasMatch(name) ||
        name.endsWith('.') ||
        name.endsWith(' ') ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
          caseSensitive: false,
        ).hasMatch(name)) {
      throw FormatException('"$value" is not a safe local file name.');
    }
    return name;
  }

  static bool _isAbsolutePath(String? path) =>
      path != null && path.startsWith('/') && !path.contains('\u0000');

  void _applyEntryView() {
    final query = filterQuery.trim().toLowerCase();
    final visible = _allEntries.where((entry) {
      if (!showHidden && entry.name.startsWith('.')) return false;
      return query.isEmpty || entry.name.toLowerCase().contains(query);
    }).toList();
    visible.sort(_compareEntries);
    entries = List.unmodifiable(visible);
    selectedPaths.removeWhere(
      (path) => !visible.any((entry) => entry.path == path),
    );
  }

  int _compareEntries(RemoteFileEntry a, RemoteFileEntry b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    int comparison;
    switch (sortField) {
      case RemoteSortField.name:
        comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case RemoteSortField.size:
        comparison = _compareNullable(a.size, b.size);
      case RemoteSortField.modifiedAt:
        comparison = _compareNullable(a.modifiedAt, b.modifiedAt);
      case RemoteSortField.type:
        comparison = a.type.index.compareTo(b.type.index);
    }
    if (comparison == 0) {
      comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
    return sortDirection == RemoteSortDirection.ascending
        ? comparison
        : -comparison;
  }

  static int _compareNullable<T extends Comparable<Object?>>(T? a, T? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  static bool _sameSnapshot(RemoteFileEntry a, RemoteFileEntry b) =>
      a.size == b.size && a.modifiedAt == b.modifiedAt && a.mode == b.mode;

  static RemoteFileEntry _copyEntry(RemoteFileEntry entry, String path) =>
      RemoteFileEntry(
        path: path,
        name: remoteBasename(path),
        type: entry.type,
        size: entry.size,
        uid: entry.uid,
        gid: entry.gid,
        accessedAt: entry.accessedAt,
        modifiedAt: entry.modifiedAt,
        mode: entry.mode,
        contentSha256: entry.contentSha256,
      );

  Map<String, ManagedRemoteFile> takeLocalCopies() {
    final copies = Map<String, ManagedRemoteFile>.of(localCopies);
    localCopies.clear();
    latestRemoteSnapshots.clear();
    return copies;
  }

  Future<void> deleteAllLocalCopies() async {
    final copies = takeLocalCopies();
    for (final copy in copies.values) {
      await managedFileStore.remove(copy.id);
      await _stopWatching(copy.id);
    }
    _notify();
  }

  Future<void> _restoreLocalCopies() async {
    if (_localCopiesLoaded) return;
    _localCopiesLoaded = true;
    final restored = await managedFileStore.reconcileAll(
      serverId: serverId,
      editSessionId: editSessionId,
    );
    if (_disposed) return;
    for (final copy in restored) {
      localCopies[copy.remotePath] = copy;
      _watchCheckout(copy);
    }
    _notify();
  }

  void _watchCheckout(ManagedRemoteFile copy) {
    if (_disposed || _checkoutWatches.containsKey(copy.id)) return;
    final directory = localFile(copy).parent;
    try {
      late final StreamSubscription<FileSystemEvent> subscription;
      subscription = directory.watch().listen(
        (_) => _scheduleCheckoutReconcile(copy.id),
        onError: (_) {
          if (identical(_checkoutWatches[copy.id], subscription)) {
            _checkoutWatches.remove(copy.id);
          }
          _scheduleCheckoutReconcile(copy.id);
        },
        onDone: () {
          if (identical(_checkoutWatches[copy.id], subscription)) {
            _checkoutWatches.remove(copy.id);
          }
        },
        cancelOnError: true,
      );
      _checkoutWatches[copy.id] = subscription;
    } on FileSystemException {
      // Resume/startup reconciliation remains a fallback where watching is not
      // available (notably some document-provider backed environments).
    }
  }

  void _scheduleCheckoutReconcile(String id) {
    _checkoutDebounces[id]?.cancel();
    _checkoutDebounces[id] = Timer(const Duration(milliseconds: 600), () {
      unawaited(_reconcileCheckout(id));
    });
  }

  Future<void> _reconcileCheckout(String id) async {
    final updated = await managedFileStore.reconcile(id);
    if (_disposed || updated == null) return;
    final current = localCopies.entries
        .where((entry) => entry.value.id == id)
        .firstOrNull;
    if (current == null) return;
    localCopies[current.key] = updated;
    _notify();
  }

  Future<void> reconcileLocalCopies() async {
    await _restoreLocalCopies();
    final updated = await managedFileStore.reconcileAll(
      serverId: serverId,
      editSessionId: editSessionId,
    );
    if (_disposed) return;
    for (final copy in updated) {
      localCopies[copy.remotePath] = copy;
      _watchCheckout(copy);
    }
    _notify();
  }

  Future<void> _stopWatching(String id) async {
    _checkoutDebounces.remove(id)?.cancel();
    await _checkoutWatches.remove(id)?.cancel();
  }

  static Future<void> _restrictLinuxPermissions(
    String path,
    String mode,
  ) async {
    final result = await Process.run('chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw StateError('Could not secure the local checkout permissions.');
    }
  }

  static Future<void> _ensureSafeLocalDirectory(
    Directory root,
    String relativePath,
  ) async {
    var path = root.absolute.path;
    var type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await root.create(recursive: true);
      type = await FileSystemEntity.type(path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Download destination is not a directory',
        path,
      );
    }
    for (final component
        in relativePath
            .split(Platform.pathSeparator)
            .where((part) => part.isNotEmpty)) {
      _validateLocalName(component);
      path = '$path${Platform.pathSeparator}$component';
      type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(path).create();
        type = await FileSystemEntity.type(path, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Refusing to follow a non-directory or symbolic link',
          path,
        );
      }
    }
  }

  static Future<void> _replaceLocalFile(File replacement, File target) async {
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.link ||
        (targetType != FileSystemEntityType.file &&
            targetType != FileSystemEntityType.notFound)) {
      throw FileSystemException(
        'Refusing to replace a non-regular local file',
        target.path,
      );
    }
    if (targetType == FileSystemEntityType.notFound) {
      await replacement.rename(target.path);
      return;
    }
    final backup = File('${target.path}.seance-${uuidV4()}.backup');
    await target.rename(backup.path);
    try {
      await replacement.rename(target.path);
    } catch (_) {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    try {
      await backup.delete();
    } on FileSystemException {
      // Replacement succeeded. A stale backup is safer than deleting the new
      // destination or claiming the transfer failed after commit.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    shellDirectory.removeListener(_followShellDirectory);
    terminalTitle.removeListener(_followShellDirectory);
    activeCommand.removeListener(_followActiveCommand);
    _remoteSnapshotDebounce?.cancel();
    for (final transfer in transfers) {
      transfer.cancellation.cancel();
    }
    for (final timer in _checkoutDebounces.values) {
      timer.cancel();
    }
    for (final watch in _checkoutWatches.values) {
      unawaited(watch.cancel());
    }
    super.dispose();
  }
}

class _EmptyStringListenable implements ValueListenable<String?> {
  const _EmptyStringListenable();

  @override
  String? get value => null;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _RemoteDownloadPlan {
  final RemoteFileEntry entry;
  final String relativePath;

  const _RemoteDownloadPlan(this.entry, this.relativePath);
}

class _MaximumByteSink implements StreamSink<List<int>> {
  final StreamSink<List<int>> _delegate;
  final int maximumBytes;
  int _received = 0;

  _MaximumByteSink(this._delegate, this.maximumBytes);

  List<int> _check(List<int> bytes) {
    _received += bytes.length;
    if (_received > maximumBytes) {
      throw StateError('The built-in editor supports text files up to 4 MB.');
    }
    return bytes;
  }

  @override
  void add(List<int> data) => _delegate.add(_check(data));

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      _delegate.addStream(stream.map(_check));

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _delegate.addError(error, stackTrace);

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<void> get done => _delegate.done;
}
