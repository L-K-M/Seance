import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

enum RemoteFileType { file, directory, symbolicLink, other }

enum RemoteFileErrorKind {
  notFound,
  permissionDenied,
  unsupported,
  disconnected,
  conflict,
  cancelled,
  other,
}

class RemoteFileException implements Exception {
  final RemoteFileErrorKind kind;
  final String operation;
  final String? path;
  final String message;
  final Object? cause;

  const RemoteFileException({
    required this.kind,
    required this.operation,
    required this.message,
    this.path,
    this.cause,
  });

  @override
  String toString() => message;
}

class RemoteFileEntry {
  final String path;
  final String name;
  final RemoteFileType type;
  final int? size;
  final DateTime? modifiedAt;

  /// Full POSIX mode, including the file-type bits when the server supplied it.
  final int? mode;

  const RemoteFileEntry({
    required this.path,
    required this.name,
    required this.type,
    this.size,
    this.modifiedAt,
    this.mode,
  });

  bool get isDirectory => type == RemoteFileType.directory;
  bool get isSymbolicLink => type == RemoteFileType.symbolicLink;
}

typedef RemoteTransferProgress = void Function(int transferred, int? total);

class RemoteTransferCancellation {
  bool _isCancelled = false;
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelled.complete();
  }

  void throwIfCancelled() {
    if (_isCancelled) throw const _RemoteTransferCancelled();
  }
}

abstract interface class RemoteFileSystem {
  Future<String> canonicalize(String path);

  Future<List<RemoteFileEntry>> listDirectory(String path);

  Future<RemoteFileEntry> stat(String path, {bool followLinks = true});

  Future<void> createDirectory(String path);

  Future<void> rename(String oldPath, String newPath, {bool overwrite = false});

  /// Deletes a file, symlink, or empty directory. Recursive deletion is
  /// deliberately not part of the initial browser.
  Future<void> delete(RemoteFileEntry entry);

  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
  });

  /// Uploads through a sibling temporary file and renames only after every byte
  /// has reached the server. Existing targets are rejected unless [overwrite]
  /// is explicitly true.
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
  });
}

String remoteJoin(String directory, String name) {
  if (directory.isEmpty || directory == '.') return name;
  if (directory == '/') return '/$name';
  return '${directory.replaceFirst(RegExp(r'/+$'), '')}/$name';
}

String remoteBasename(String path) {
  final trimmed = path.length > 1
      ? path.replaceFirst(RegExp(r'/+$'), '')
      : path;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

String remoteParent(String path) {
  final trimmed = path.length > 1
      ? path.replaceFirst(RegExp(r'/+$'), '')
      : path;
  final slash = trimmed.lastIndexOf('/');
  if (slash < 0) return '.';
  if (slash == 0) return '/';
  return trimmed.substring(0, slash);
}

/// dartssh2-backed implementation. Kept private to the core package's public
/// surface through [RemoteFileSystem], so UI code cannot depend on SFTP types.
class DartSshRemoteFileSystem implements RemoteFileSystem {
  final SftpClient _client;
  final Duration operationTimeout;
  final Random _random = Random.secure();

  DartSshRemoteFileSystem(
    this._client, {
    this.operationTimeout = const Duration(seconds: 30),
  });

  @override
  Future<String> canonicalize(String path) => _guard(
    'resolve',
    path,
    () => _client.absolute(path).timeout(operationTimeout),
  );

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) =>
      _guard('list', path, () async {
        final names = await _client.listdir(path).timeout(operationTimeout);
        return [
          for (final item in names)
            if (item.filename != '.' && item.filename != '..')
              _entry(remoteJoin(path, item.filename), item.filename, item.attr),
        ];
      });

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) =>
      _guard('inspect', path, () async {
        final attrs = await _client
            .stat(path, followLink: followLinks)
            .timeout(operationTimeout);
        return _entry(path, remoteBasename(path), attrs);
      });

  @override
  Future<void> createDirectory(String path) => _guard(
    'create directory',
    path,
    () => _client.mkdir(path).timeout(operationTimeout),
  );

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) => _guard('rename', oldPath, () async {
    if (!overwrite && await _statOrNull(newPath) != null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'rename',
        path: newPath,
        message:
            'A remote item named "${remoteBasename(newPath)}" already exists.',
      );
    }
    await _client.rename(oldPath, newPath).timeout(operationTimeout);
  });

  @override
  Future<void> delete(RemoteFileEntry entry) => _guard(
    'delete',
    entry.path,
    () =>
        (entry.isDirectory
                ? _client.rmdir(entry.path)
                : _client.remove(entry.path))
            .timeout(operationTimeout),
  );

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
  }) => _guard('download', path, () async {
    cancellation?.throwIfCancelled();
    final file = await _client
        .open(path, mode: SftpFileOpenMode.read)
        .timeout(operationTimeout);
    try {
      final attrs = await file.stat().timeout(operationTimeout);
      final length = attrs.size;
      if (length == null) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.unsupported,
          operation: 'download',
          path: path,
          message: 'The server did not report a size for "$path".',
        );
      }
      var transferred = 0;
      await destination.addStream(
        _cancelWhenRequested(
          file.read(
            length: length,
            onProgress: (read) {
              transferred = read;
              onProgress?.call(read, length);
            },
          ),
          cancellation,
        ).timeout(operationTimeout),
      );
      cancellation?.throwIfCancelled();
      if (transferred != length) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'download',
          path: path,
          message:
              'The remote file changed while it was downloading '
              '($transferred of $length bytes received).',
        );
      }
      return _entry(path, remoteBasename(path), attrs);
    } finally {
      if (cancellation?.isCancelled ?? false) {
        unawaited(file.close().catchError((_) {}));
      } else {
        await file.close().timeout(operationTimeout);
      }
    }
  });

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
  }) => _guard('upload', path, () async {
    final existing = await _statOrNull(path);
    if (existing != null && !overwrite) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'upload',
        path: path,
        message:
            'A remote item named "${remoteBasename(path)}" already exists.',
      );
    }
    if (expectedTarget != null &&
        (existing == null || !_sameSnapshot(existing, expectedTarget))) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'upload',
        path: path,
        message:
            '"${remoteBasename(path)}" changed on the server before '
            'the upload started.',
      );
    }

    cancellation?.throwIfCancelled();
    final tempPath = _temporaryPath(path);
    SftpFile? file;
    try {
      file = await _client
          .open(
            tempPath,
            mode:
                SftpFileOpenMode.write |
                SftpFileOpenMode.create |
                SftpFileOpenMode.exclusive,
          )
          .timeout(operationTimeout);
      var transferred = 0;
      await for (final chunk in _cancelWhenRequested(
        content,
        cancellation,
      ).timeout(operationTimeout)) {
        cancellation?.throwIfCancelled();
        if (chunk.isEmpty) continue;
        await file
            .writeBytes(Uint8List.fromList(chunk), offset: transferred)
            .timeout(operationTimeout);
        transferred += chunk.length;
        onProgress?.call(transferred, length);
      }
      cancellation?.throwIfCancelled();
      if (length != null && transferred != length) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.other,
          operation: 'upload',
          path: path,
          message: 'Upload ended after $transferred of $length bytes.',
        );
      }
      await file.close().timeout(operationTimeout);
      file = null;

      final mode = preserveMode ?? existing?.mode;
      if (mode != null) {
        await _client
            .setStat(tempPath, SftpFileAttrs(mode: SftpFileMode.value(mode)))
            .timeout(operationTimeout);
      }
      final latest = await _statOrNull(path);
      if (!overwrite && latest != null) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'upload',
          path: path,
          message:
              'A remote item named "${remoteBasename(path)}" was created '
              'while the upload was running.',
        );
      }
      if (expectedTarget != null &&
          (latest == null || !_sameSnapshot(latest, expectedTarget))) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'upload',
          path: path,
          message:
              '"${remoteBasename(path)}" changed on the server while '
              'the upload was running.',
        );
      }
      await _client.rename(tempPath, path).timeout(operationTimeout);
      return stat(path, followLinks: false);
    } catch (_) {
      if (cancellation?.isCancelled ?? false) {
        unawaited(_cleanupTemporaryUpload(file, tempPath));
        cancellation!.throwIfCancelled();
      }
      if (file != null) {
        try {
          await file.close().timeout(operationTimeout);
        } catch (_) {}
      }
      try {
        await _client.remove(tempPath).timeout(operationTimeout);
      } catch (_) {}
      rethrow;
    }
  });

  Future<void> _cleanupTemporaryUpload(SftpFile? file, String tempPath) async {
    if (file != null) {
      try {
        await file.close().timeout(operationTimeout);
      } catch (_) {}
    }
    try {
      await _client.remove(tempPath).timeout(operationTimeout);
    } catch (_) {}
  }

  Future<RemoteFileEntry?> _statOrNull(String path) async {
    try {
      return await stat(path, followLinks: false);
    } on RemoteFileException catch (e) {
      if (e.kind == RemoteFileErrorKind.notFound) return null;
      rethrow;
    }
  }

  static bool _sameSnapshot(RemoteFileEntry a, RemoteFileEntry b) =>
      a.type == b.type &&
      a.size == b.size &&
      a.modifiedAt == b.modifiedAt &&
      a.mode == b.mode;

  String _temporaryPath(String path) {
    final suffix = List.generate(
      8,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    return remoteJoin(
      remoteParent(path),
      '.${remoteBasename(path)}.seance-upload-$suffix',
    );
  }

  static RemoteFileEntry _entry(
    String path,
    String name,
    SftpFileAttrs attrs,
  ) => RemoteFileEntry(
    path: path,
    name: name,
    type: switch (attrs.type) {
      SftpFileType.regularFile => RemoteFileType.file,
      SftpFileType.directory => RemoteFileType.directory,
      SftpFileType.symbolicLink => RemoteFileType.symbolicLink,
      _ => RemoteFileType.other,
    },
    size: attrs.size,
    modifiedAt: attrs.modifyTime == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            attrs.modifyTime! * 1000,
            isUtc: true,
          ),
    mode: attrs.mode?.value,
  );

  Future<T> _guard<T>(
    String operation,
    String? path,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } on RemoteFileException {
      rethrow;
    } on _RemoteTransferCancelled catch (e) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: operation,
        path: path,
        message: 'Transfer cancelled.',
        cause: e,
      );
    } on SftpStatusError catch (e) {
      final kind = switch (e.code) {
        SftpStatusCode.noSuchFile => RemoteFileErrorKind.notFound,
        SftpStatusCode.permissionDenied => RemoteFileErrorKind.permissionDenied,
        SftpStatusCode.opUnsupported => RemoteFileErrorKind.unsupported,
        SftpStatusCode.noConnection ||
        SftpStatusCode.connectionLost => RemoteFileErrorKind.disconnected,
        _ => RemoteFileErrorKind.other,
      };
      throw RemoteFileException(
        kind: kind,
        operation: operation,
        path: path,
        message: _message(operation, path, e.message),
        cause: e,
      );
    } on TimeoutException catch (e) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: operation,
        path: path,
        message: _message(operation, path, 'the server did not respond'),
        cause: e,
      );
    } on SftpAbortError catch (e) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: operation,
        path: path,
        message: _message(operation, path, e.message),
        cause: e,
      );
    } catch (e) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: operation,
        path: path,
        message: _message(operation, path, e.toString()),
        cause: e,
      );
    }
  }

  static String _message(String operation, String? path, String detail) {
    final target = path == null ? '' : ' "$path"';
    return 'Could not $operation$target: $detail';
  }
}

Stream<T> _cancelWhenRequested<T>(
  Stream<T> source,
  RemoteTransferCancellation? cancellation,
) async* {
  final iterator = StreamIterator<T>(source);
  try {
    while (true) {
      cancellation?.throwIfCancelled();
      final hasNext = cancellation == null
          ? await iterator.moveNext()
          : await Future.any([
              iterator.moveNext(),
              cancellation.whenCancelled.then<bool>((_) {
                cancellation.throwIfCancelled();
                return false;
              }),
            ]);
      if (!hasNext) return;
      yield iterator.current;
    }
  } finally {
    unawaited(iterator.cancel());
  }
}

class _RemoteTransferCancelled implements Exception {
  const _RemoteTransferCancelled();
}
