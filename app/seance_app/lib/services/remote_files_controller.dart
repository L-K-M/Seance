import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

enum RemoteTransferDirection { upload, download }

enum RemoteTransferStatus { running, completed, failed, cancelled }

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

class ManagedRemoteFile {
  final String remotePath;
  final String localPath;
  RemoteFileEntry remoteSnapshot;

  ManagedRemoteFile({
    required this.remotePath,
    required this.localPath,
    required this.remoteSnapshot,
  });
}

/// Session-scoped navigation and transfer state. Platform pickers and external
/// application launching stay in the Files UI; this controller only consumes
/// byte streams and local paths handed to it.
class RemoteFilesController extends ChangeNotifier {
  final Future<RemoteFileSystem> Function() _openRemoteFileSystem;
  final ValueListenable<String?> shellDirectory;

  RemoteFilesController(
    this._openRemoteFileSystem, {
    required this.shellDirectory,
    Map<String, ManagedRemoteFile>? initialLocalCopies,
  }) {
    if (initialLocalCopies != null) localCopies.addAll(initialLocalCopies);
    shellDirectory.addListener(_followShellDirectory);
  }

  RemoteFileSystem? _remoteFileSystem;
  Future<void>? _initializing;
  int _navigationGeneration = 0;
  int _nextTransferId = 0;
  bool _disposed = false;

  bool initialized = false;
  bool loading = false;
  bool followTerminal = true;
  String? homePath;
  String? currentPath;
  String? error;
  List<RemoteFileEntry> entries = const [];
  final List<RemoteTransferItem> transfers = [];
  final Map<String, ManagedRemoteFile> localCopies = {};

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
      final remote = await _openRemoteFileSystem();
      if (_disposed) return;
      _remoteFileSystem = remote;
      homePath = await remote.canonicalize('.');
      if (_disposed) return;
      initialized = true;
      final shellPath = shellDirectory.value;
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
      next.sort(_compareEntries);
      currentPath = canonical;
      entries = List.unmodifiable(next);
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

  void setFollowTerminal(bool value) {
    if (followTerminal == value) return;
    followTerminal = value;
    _notify();
    if (value) _followShellDirectory();
  }

  Future<void> createDirectory(String name) async {
    final remote = _requireRemote();
    final path = remoteJoin(_requireCurrentPath(), _validateName(name));
    await remote.createDirectory(path);
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
      localCopies[nextPath] = ManagedRemoteFile(
        remotePath: nextPath,
        localPath: item.value.localPath,
        remoteSnapshot: _copyEntry(item.value.remoteSnapshot, nextPath),
      );
    }
    await refresh();
  }

  Future<void> deleteEntry(RemoteFileEntry entry) async {
    await _requireRemote().delete(entry);
    await removeLocalCopy(entry.path);
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

  bool trackLocalCopy(RemoteFileEntry entry, String localPath) {
    if (_disposed) {
      unawaited(_deleteCheckout(localPath));
      return false;
    }
    localCopies[entry.path] = ManagedRemoteFile(
      remotePath: entry.path,
      localPath: localPath,
      remoteSnapshot: entry,
    );
    _notify();
    return true;
  }

  Future<void> uploadLocalCopy(
    ManagedRemoteFile copy, {
    bool overwriteRemoteChanges = false,
  }) async {
    final file = File(copy.localPath);
    final size = await file.length();
    final latest = await _requireRemote().stat(
      copy.remotePath,
      followLinks: false,
    );
    if (!overwriteRemoteChanges &&
        !_sameSnapshot(latest, copy.remoteSnapshot)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'upload edited copy',
        path: copy.remotePath,
        message:
            '"${remoteBasename(copy.remotePath)}" changed on the server '
            'after it was opened locally.',
      );
    }
    final uploaded = await _runUpload(
      path: copy.remotePath,
      displayName: remoteBasename(copy.remotePath),
      content: file.openRead(),
      length: size,
      overwrite: true,
      preserveMode: copy.remoteSnapshot.mode,
      expectedTarget: overwriteRemoteChanges ? null : copy.remoteSnapshot,
    );
    copy.remoteSnapshot = uploaded;
    _notify();
  }

  Future<void> removeLocalCopy(String remotePath) async {
    final copy = localCopies[remotePath];
    if (copy == null) return;
    await _deleteCheckout(copy.localPath, bestEffort: false);
    localCopies.remove(remotePath);
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
        failure is RemoteFileException &&
        failure.kind == RemoteFileErrorKind.cancelled;
    transfer.status = cancelled
        ? RemoteTransferStatus.cancelled
        : RemoteTransferStatus.failed;
    transfer.error = failure.toString();
  }

  void _followShellDirectory() {
    final path = shellDirectory.value;
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

  static bool _isAbsolutePath(String? path) =>
      path != null && path.startsWith('/') && !path.contains('\u0000');

  static int _compareEntries(RemoteFileEntry a, RemoteFileEntry b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  static bool _sameSnapshot(RemoteFileEntry a, RemoteFileEntry b) =>
      a.size == b.size && a.modifiedAt == b.modifiedAt && a.mode == b.mode;

  static RemoteFileEntry _copyEntry(RemoteFileEntry entry, String path) =>
      RemoteFileEntry(
        path: path,
        name: remoteBasename(path),
        type: entry.type,
        size: entry.size,
        modifiedAt: entry.modifiedAt,
        mode: entry.mode,
      );

  Map<String, ManagedRemoteFile> takeLocalCopies() {
    final copies = Map<String, ManagedRemoteFile>.of(localCopies);
    localCopies.clear();
    return copies;
  }

  Future<void> deleteAllLocalCopies() async {
    final copies = takeLocalCopies();
    await deleteManagedCopies(copies.values);
    _notify();
  }

  static Future<void> deleteManagedCopies(
    Iterable<ManagedRemoteFile> copies,
  ) async {
    for (final copy in copies) {
      await _deleteCheckout(copy.localPath);
    }
  }

  static Future<void> _deleteCheckout(
    String localPath, {
    bool bestEffort = true,
  }) async {
    try {
      final parent = File(localPath).parent;
      if (await parent.exists()) await parent.delete(recursive: true);
    } catch (e) {
      if (!bestEffort) {
        throw StateError(
          'Could not delete the local copy. Close its editor and try again: $e',
        );
      }
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
    for (final transfer in transfers) {
      transfer.cancellation.cancel();
    }
    super.dispose();
  }
}
