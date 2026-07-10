import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'atomic_file.dart';
import 'managed_remote_file.dart';

const _indexVersion = 1;

/// Computes a SHA-256 without loading the checkout into memory.
Future<String> streamedFileSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// Durable local index and checkout lifecycle for externally edited files.
///
/// The caller supplies app-support locations so platform path lookup remains at
/// the composition boundary and tests can use isolated temporary directories.
class ManagedRemoteFileStore {
  final File indexFile;
  final Directory checkoutRoot;

  final Map<String, ManagedRemoteFile> _files = {};
  Future<void> _operationTail = Future<void>.value();
  bool _loaded = false;

  ManagedRemoteFileStore({required this.indexFile, required this.checkoutRoot});

  /// Returns a stable root-relative path for a checkout. Hashing [id] avoids
  /// treating externally supplied identifiers as filesystem path components.
  String checkoutPathFor({required String id, required String fileName}) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty');
    final directory = sha256.convert(utf8.encode(id)).toString();
    var safeName = fileName.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_');
    safeName = safeName.replaceFirst(RegExp(r'[. ]+$'), '_');
    if (safeName.isEmpty ||
        safeName == '.' ||
        safeName == '..' ||
        _windowsDeviceName.hasMatch(safeName)) {
      safeName = 'remote-file';
    }
    return '$directory/$safeName';
  }

  /// Resolves a validated relative identity without touching the filesystem.
  File checkoutFile(String localPath) {
    final segments = _validateRelativePath(localPath);
    final file = File(_join(checkoutRoot.absolute.path, segments));
    if (file.absolute.path == indexFile.absolute.path) {
      throw ArgumentError.value(
        localPath,
        'localPath',
        'Must not resolve to the index file',
      );
    }
    return file;
  }

  /// Creates a new empty checkout file without following existing symlinks.
  Future<File> createCheckout(String localPath, {bool exclusive = true}) =>
      _serialized(() async {
        await _loadUnlocked();
        final file = checkoutFile(localPath);
        await _ensureSafeParents(localPath);
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type != FileSystemEntityType.notFound) {
          if (type != FileSystemEntityType.file || exclusive) {
            throw FileSystemException(
              'Checkout path already exists',
              file.path,
            );
          }
          return file;
        }

        await file.create(exclusive: true);
        final createdType = await FileSystemEntity.type(
          file.path,
          followLinks: false,
        );
        if (createdType != FileSystemEntityType.file) {
          throw FileSystemException(
            'Checkout path is not a regular file',
            file.path,
          );
        }
        return file;
      });

  /// Deletes only the validated checkout and then prunes empty directories.
  /// A symlink at the final path is unlinked; it is never followed.
  Future<void> deleteCheckout(String localPath) =>
      _serialized(() => _deleteCheckoutUnlocked(localPath));

  Future<ManagedRemoteFile?> get(String id) => _serialized(() async {
    await _loadUnlocked();
    return _files[id];
  });

  Future<List<ManagedRemoteFile>> list({
    String? serverId,
    String? editSessionId,
  }) => _serialized(() async {
    await _loadUnlocked();
    return _filteredFiles(serverId: serverId, editSessionId: editSessionId);
  });

  Future<List<ManagedRemoteFile>> listForServer(String serverId) =>
      list(serverId: serverId);

  Future<List<ManagedRemoteFile>> listForSession(
    String editSessionId, {
    String? serverId,
  }) => list(serverId: serverId, editSessionId: editSessionId);

  /// Inserts or replaces a record and atomically commits the complete index.
  Future<void> put(ManagedRemoteFile file) => _serialized(() async {
    await _loadUnlocked();
    _validateFile(file);
    final duplicate = _files.values.where(
      (existing) =>
          existing.id != file.id &&
          existing.serverId == file.serverId &&
          existing.editSessionId == file.editSessionId &&
          existing.remotePath == file.remotePath,
    );
    if (duplicate.isNotEmpty) {
      throw StateError(
        'A managed checkout already exists for ${file.remotePath}',
      );
    }
    final previous = _files[file.id];
    _files[file.id] = file;
    try {
      await _flushUnlocked();
    } catch (_) {
      if (previous == null) {
        _files.remove(file.id);
      } else {
        _files[file.id] = previous;
      }
      rethrow;
    }
  });

  /// Replaces an existing record. Unlike [put], a missing id is an error.
  Future<void> update(ManagedRemoteFile file) => _serialized(() async {
    await _loadUnlocked();
    if (!_files.containsKey(file.id)) {
      throw StateError('Managed remote file ${file.id} does not exist');
    }
    _validateFile(file);
    final previous = _files[file.id]!;
    _files[file.id] = file;
    try {
      await _flushUnlocked();
    } catch (_) {
      _files[file.id] = previous;
      rethrow;
    }
  });

  /// Removes a record. Plaintext is deleted before the index entry so a failed
  /// filesystem operation cannot silently orphan a checkout.
  Future<ManagedRemoteFile?> remove(String id, {bool deleteCheckout = true}) =>
      _serialized(() async {
        await _loadUnlocked();
        final previous = _files[id];
        if (previous == null) return null;
        if (deleteCheckout) {
          await _deleteCheckoutUnlocked(previous.localPath);
        }
        _files.remove(id);
        try {
          await _flushUnlocked();
        } catch (_) {
          _files[id] = previous;
          rethrow;
        }
        return previous;
      });

  /// Recomputes runtime state for one checkout. Missing files are not dirty;
  /// they are reported separately through [ManagedRemoteFile.missing].
  Future<ManagedRemoteFile?> reconcile(String id) => _serialized(() async {
    await _loadUnlocked();
    final file = _files[id];
    if (file == null) return null;
    return _reconcileUnlocked(file);
  });

  Future<List<ManagedRemoteFile>> reconcileAll({
    String? serverId,
    String? editSessionId,
  }) => _serialized(() async {
    await _loadUnlocked();
    final files = _filteredFiles(
      serverId: serverId,
      editSessionId: editSessionId,
    );
    final reconciled = <ManagedRemoteFile>[];
    for (final file in files) {
      reconciled.add(await _reconcileUnlocked(file));
    }
    return reconciled;
  });

  /// Accepts the current local contents as the new persisted baseline.
  Future<ManagedRemoteFile?> updateBaseline(String id) => _serialized(() async {
    await _loadUnlocked();
    final current = _files[id];
    if (current == null) return null;
    final local = await _safeRegularFile(current.localPath);
    if (local == null) {
      throw FileSystemException(
        'Checkout file does not exist',
        checkoutFile(current.localPath).path,
      );
    }
    final updated = current.copyWith(
      baselineSha256: await streamedFileSha256(local),
      dirty: false,
      missing: false,
    );
    _files[id] = updated;
    try {
      await _flushUnlocked();
    } catch (_) {
      _files[id] = current;
      rethrow;
    }
    return updated;
  });

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<void> _loadUnlocked() async {
    if (_loaded) return;
    var canSweepUnindexed = true;
    if (await indexFile.exists()) {
      try {
        final decoded = jsonDecode(await indexFile.readAsString());
        if (decoded is! Map) {
          throw const FormatException('Managed-file index must be an object');
        }
        final json = decoded.cast<String, dynamic>();
        if (json['version'] != _indexVersion) {
          throw FormatException(
            'Unsupported managed-file index version: ${json['version']}',
          );
        }
        final entries = json['files'];
        if (entries is! List) {
          throw const FormatException(
            'Managed-file index files must be a list',
          );
        }
        for (final entry in entries) {
          if (entry is! Map) {
            throw const FormatException('Managed-file entry must be an object');
          }
          final file = ManagedRemoteFile.fromJson(
            entry.cast<String, dynamic>(),
          );
          _validateFile(file);
          if (_files.containsKey(file.id)) {
            throw FormatException('Duplicate managed-file id: ${file.id}');
          }
          _files[file.id] = file;
        }
      } catch (_) {
        _files.clear();
        await quarantineCorruptFile(indexFile);
        // Without a trustworthy index, any checkout may contain the only copy
        // of an edit. Preserve all plaintext directories for manual recovery.
        canSweepUnindexed = false;
      }
    }
    if (canSweepUnindexed) await _sweepUnindexedCheckouts();
    _loaded = true;
  }

  Future<void> _sweepUnindexedCheckouts() async {
    final rootType = await FileSystemEntity.type(
      checkoutRoot.path,
      followLinks: false,
    );
    if (rootType == FileSystemEntityType.notFound) return;
    if (rootType != FileSystemEntityType.directory) return;
    final retained = {
      for (final file in _files.values) file.localPath.split('/').first,
    };
    await for (final entity in checkoutRoot.list(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (retained.contains(name)) continue;
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await Directory(entity.path).delete(recursive: true);
      } else if (type == FileSystemEntityType.file) {
        await File(entity.path).delete();
      } else if (type == FileSystemEntityType.link) {
        await Link(entity.path).delete();
      }
    }
  }

  Future<void> _flushUnlocked() async {
    final files = _files.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    await writeStringAtomically(
      indexFile,
      jsonEncode({
        'version': _indexVersion,
        'files': files.map((file) => file.toJson()).toList(),
      }),
    );
  }

  List<ManagedRemoteFile> _filteredFiles({
    String? serverId,
    String? editSessionId,
  }) {
    final files =
        _files.values
            .where(
              (file) =>
                  (serverId == null || file.serverId == serverId) &&
                  (editSessionId == null ||
                      file.editSessionId == editSessionId),
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return files;
  }

  Future<ManagedRemoteFile> _reconcileUnlocked(
    ManagedRemoteFile managed,
  ) async {
    final local = await _safeRegularFile(managed.localPath);
    if (local == null) {
      final missing = managed.copyWith(dirty: false, missing: true);
      _files[managed.id] = missing;
      return missing;
    }

    try {
      final digest = await streamedFileSha256(local);
      final reconciled = managed.copyWith(
        dirty: digest != managed.baselineSha256,
        missing: false,
      );
      _files[managed.id] = reconciled;
      return reconciled;
    } on FileSystemException {
      if (await _safeRegularFile(managed.localPath) == null) {
        final missing = managed.copyWith(dirty: false, missing: true);
        _files[managed.id] = missing;
        return missing;
      }
      rethrow;
    }
  }

  void _validateFile(ManagedRemoteFile file) {
    try {
      file.validate();
      checkoutFile(file.localPath);
    } on FormatException catch (error) {
      throw ArgumentError.value(file, 'file', error.message);
    }
  }

  Future<void> _ensureSafeParents(String localPath) async {
    final segments = _validateRelativePath(localPath);
    final root = checkoutRoot.absolute;
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Checkout root is not a real directory',
        root.path,
      );
    }

    var path = root.path;
    for (final segment in segments.take(segments.length - 1)) {
      path = _join(path, [segment]);
      var type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(path).create();
        type = await FileSystemEntity.type(path, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Checkout path contains a non-directory or symlink',
          path,
        );
      }
    }
  }

  Future<File?> _safeRegularFile(String localPath) async {
    final segments = _validateRelativePath(localPath);
    var path = checkoutRoot.absolute.path;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    for (final segment in segments.take(segments.length - 1)) {
      path = _join(path, [segment]);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return null;
      }
    }
    final file = checkoutFile(localPath);
    return await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file
        ? file
        : null;
  }

  Future<void> _deleteCheckoutUnlocked(String localPath) async {
    final segments = _validateRelativePath(localPath);
    final root = checkoutRoot.absolute;
    var path = root.path;
    final parents = <Directory>[];
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    for (final segment in segments.take(segments.length - 1)) {
      path = _join(path, [segment]);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Refusing to follow an unsafe checkout path',
          path,
        );
      }
      parents.add(Directory(path));
    }

    final target = checkoutFile(localPath);
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.file) {
      await target.delete();
    } else if (targetType == FileSystemEntityType.link) {
      await Link(target.path).delete();
    } else if (targetType != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Refusing to delete a non-file checkout',
        target.path,
      );
    }

    for (final parent in parents.reversed) {
      try {
        await parent.delete();
      } on FileSystemException {
        break;
      }
    }
  }
}

List<String> _validateRelativePath(String localPath) {
  if (localPath.isEmpty ||
      localPath.startsWith('/') ||
      localPath.startsWith('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(localPath) ||
      localPath.contains('\\') ||
      localPath.contains('\x00')) {
    throw ArgumentError.value(
      localPath,
      'localPath',
      'Must be a safe root-relative path',
    );
  }
  final segments = localPath.split('/');
  if (segments.any(
    (segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        RegExp(r'[:*?"<>|]').hasMatch(segment) ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        _windowsDeviceName.hasMatch(segment) ||
        RegExp(r'[\x00-\x1f]').hasMatch(segment),
  )) {
    throw ArgumentError.value(
      localPath,
      'localPath',
      'Contains an unsafe path component',
    );
  }
  return segments;
}

String _join(String base, Iterable<String> segments) =>
    <String>[base, ...segments].join(Platform.pathSeparator);

final _windowsDeviceName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
  caseSensitive: false,
);
