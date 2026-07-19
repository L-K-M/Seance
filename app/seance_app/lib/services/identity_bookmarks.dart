import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// An identity file chosen via Browse…. [bookmark] is a base64
/// security-scoped bookmark on macOS (null when minting failed, or on other
/// platforms where the plain path is enough).
class PickedIdentityFile {
  final String path;
  final String? bookmark;
  const PickedIdentityFile(this.path, {this.bookmark});
}

/// A bookmark resolved for reading. [path] is inside a live security-scope
/// grant until [IdentityFileBookmarks.stopAccess] is called with [token]
/// (an opaque per-grant handle, so overlapping grants on the same file each
/// balance their own start). [refreshedBookmark] is set when the stored
/// bookmark went stale and a fresh one should be persisted in its place.
class ResolvedIdentityFile {
  final String path;
  final String token;
  final String? refreshedBookmark;
  const ResolvedIdentityFile(this.path,
      {required this.token, this.refreshedBookmark});
}

/// Browse…-picked identity files. On macOS the picking runs through a native
/// NSOpenPanel (file_picker can't show dot-directories like ~/.ssh) that also
/// mints a security-scoped bookmark, which is what keeps a key outside ~/.ssh
/// readable at connect time across relaunches — the sandbox forgets plain
/// picker grants on quit. Elsewhere the sandbox doesn't apply and Browse… is
/// just a convenient way to fill in the path.
class IdentityFileBookmarks {
  static const _channel = MethodChannel('seance/secure_bookmarks');

  /// Whether picks produce (and reads need) security-scoped bookmarks.
  bool get isSupported => Platform.isMacOS;

  /// Let the user pick an identity file. Returns null when cancelled.
  Future<PickedIdentityFile?> pick() async {
    if (isSupported) {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('pickIdentityFile');
      if (result == null) return null;
      return PickedIdentityFile(
        result['path'] as String,
        bookmark: result['bookmark'] as String?,
      );
    }
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Choose an SSH identity file',
      allowMultiple: false,
      type: FileType.any,
    );
    final path = result?.files.single.path;
    return path == null ? null : PickedIdentityFile(path);
  }

  /// Resolve a stored bookmark and start its security-scope grant. Returns
  /// null when the bookmark no longer resolves (file moved/deleted, bookmark
  /// from another device) — callers then fall back to the plain path. A
  /// non-null result MUST be balanced with [stopAccess] after the read.
  Future<ResolvedIdentityFile?> resolveAndStart(String bookmark) async {
    if (!isSupported) return null;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
          'resolveBookmark', {'bookmark': bookmark});
      if (result == null) return null;
      return ResolvedIdentityFile(
        result['path'] as String,
        token: result['token'] as String,
        refreshedBookmark: result['refreshedBookmark'] as String?,
      );
    } catch (_) {
      // Any channel failure means "no usable grant" — fall back to the path.
      return null;
    }
  }

  /// End the security-scope grant started by [resolveAndStart].
  Future<void> stopAccess(String token) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stopAccess', {'token': token});
    } catch (_) {
      // Best effort: an unbalanced stop only leaks a grant until app exit,
      // and this runs in a finally that must not mask the original error.
    }
  }
}
