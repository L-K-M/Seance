import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';

enum RemoteFileEditor { systemDefault, bbedit }

/// Opens a managed checkout without turning an editor command into a shell.
class ExternalFileOpener {
  static const _channel = MethodChannel('seance/files');

  const ExternalFileOpener();

  Future<void> open(
    String path, {
    RemoteFileEditor editor = RemoteFileEditor.systemDefault,
  }) async {
    if (editor == RemoteFileEditor.bbedit) {
      if (!Platform.isMacOS) {
        throw UnsupportedError(
          'BBEdit integration is available on macOS only.',
        );
      }
      await _channel.invokeMethod<void>('openWithApplication', {
        'path': path,
        'bundleIdentifier': 'com.barebones.bbedit',
      });
      return;
    }
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done) throw StateError(result.message);
  }
}
