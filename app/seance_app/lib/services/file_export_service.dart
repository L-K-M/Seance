import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Injectable boundary around Android's Storage Access Framework channel.
abstract interface class FileExportPlatform {
  Future<bool> pickExportDirectory();

  Future<bool> hasExportDirectoryAccess();

  Future<String> exportFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  });

  Future<void> releaseExportDirectory();
}

/// The Android implementation of [FileExportPlatform].
class MethodChannelFileExportPlatform implements FileExportPlatform {
  static const channelName = 'seance/files';

  final MethodChannel _channel;

  MethodChannelFileExportPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  @override
  Future<bool> pickExportDirectory() async {
    final selected = await _channel.invokeMethod<bool>('pickExportDirectory');
    if (selected == null) {
      throw PlatformException(
        code: 'INVALID_RESULT',
        message: 'Android returned no directory selection result.',
      );
    }
    return selected;
  }

  @override
  Future<bool> hasExportDirectoryAccess() async {
    final hasAccess = await _channel.invokeMethod<bool>(
      'hasExportDirectoryAccess',
    );
    if (hasAccess == null) {
      throw PlatformException(
        code: 'INVALID_RESULT',
        message: 'Android returned no directory access result.',
      );
    }
    return hasAccess;
  }

  @override
  Future<String> exportFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    final uri = await _channel.invokeMethod<String>('exportFile', {
      'sourcePath': sourcePath,
      'fileName': fileName,
      'mimeType': mimeType,
    });
    if (uri == null || uri.isEmpty) {
      throw PlatformException(
        code: 'INVALID_RESULT',
        message: 'Android returned no exported document URI.',
      );
    }
    return uri;
  }

  @override
  Future<void> releaseExportDirectory() =>
      _channel.invokeMethod<void>('releaseExportDirectory');
}

/// A local cache file plus the metadata used when exporting or sharing it.
class StagedExportFile {
  final File file;
  final String fileName;
  final String mimeType;

  const StagedExportFile({
    required this.file,
    required this.fileName,
    required this.mimeType,
  });
}

typedef DesktopSaveCallback = Future<String?> Function(StagedExportFile file);
typedef StagingDirectoryProvider = Future<Directory> Function();

/// Stages streams locally, exports them through SAF, or prepares them to share.
class FileExportService {
  final FileExportPlatform _platform;
  final StagingDirectoryProvider _stagingDirectoryProvider;
  final DesktopSaveCallback? desktopSave;
  final bool _useAndroidSaf;

  FileExportService({
    FileExportPlatform? platform,
    StagingDirectoryProvider? stagingDirectoryProvider,
    this.desktopSave,
    bool? useAndroidSaf,
  }) : _platform = platform ?? MethodChannelFileExportPlatform(),
       _stagingDirectoryProvider =
           stagingDirectoryProvider ?? getTemporaryDirectory,
       _useAndroidSaf = useAndroidSaf ?? Platform.isAndroid;

  Future<bool> pickExportDirectory() {
    if (!_useAndroidSaf) return Future<bool>.value(false);
    return _platform.pickExportDirectory();
  }

  Future<bool> hasExportDirectoryAccess() {
    if (!_useAndroidSaf) return Future<bool>.value(false);
    return _platform.hasExportDirectoryAccess();
  }

  Future<void> releaseExportDirectory() {
    if (!_useAndroidSaf) return Future<void>.value();
    return _platform.releaseExportDirectory();
  }

  /// Writes [contents] to a unique cache directory without buffering it all.
  Future<StagedExportFile> stageFile({
    required String fileName,
    required Stream<List<int>> contents,
    String mimeType = 'application/octet-stream',
  }) async {
    _validateFileName(fileName);
    _validateMimeType(mimeType);

    final root = await _stagingDirectoryProvider();
    await root.create(recursive: true);
    final directory = await root.createTemp('seance-export-');
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    final sink = file.openWrite();
    try {
      await sink.addStream(contents);
      await sink.flush();
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {
        // Preserve the original stream or filesystem error.
      }
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // Best effort; cache cleanup must not mask the staging error.
      }
      rethrow;
    }
    return StagedExportFile(file: file, fileName: fileName, mimeType: mimeType);
  }

  /// Exports with Android SAF or delegates the desktop save dialog to the app.
  ///
  /// A null desktop result means the user cancelled the injected save dialog.
  Future<String?> exportFile(StagedExportFile stagedFile) async {
    if (!await stagedFile.file.exists()) {
      throw StateError('The staged export file no longer exists.');
    }
    if (_useAndroidSaf) {
      return _platform.exportFile(
        sourcePath: stagedFile.file.path,
        fileName: stagedFile.fileName,
        mimeType: stagedFile.mimeType,
      );
    }
    final save = desktopSave;
    if (save == null) {
      throw UnsupportedError('No desktop file saver was provided.');
    }
    return save(stagedFile);
  }

  /// Returns an [XFile] suitable for a platform share sheet.
  Future<XFile> shareReadyFile(StagedExportFile stagedFile) async {
    if (!await stagedFile.file.exists()) {
      throw StateError('The staged export file no longer exists.');
    }
    return XFile(stagedFile.file.path, mimeType: stagedFile.mimeType);
  }

  static void _validateFileName(String fileName) {
    if (fileName.trim().isEmpty ||
        fileName == '.' ||
        fileName == '..' ||
        fileName.length > 255 ||
        RegExp(r'[\x00-\x1f\x7f/\\]').hasMatch(fileName)) {
      throw ArgumentError.value(fileName, 'fileName', 'Invalid file name');
    }
  }

  static void _validateMimeType(String mimeType) {
    final separator = mimeType.indexOf('/');
    if (separator <= 0 ||
        separator == mimeType.length - 1 ||
        separator != mimeType.lastIndexOf('/') ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(mimeType)) {
      throw ArgumentError.value(mimeType, 'mimeType', 'Invalid MIME type');
    }
  }
}
