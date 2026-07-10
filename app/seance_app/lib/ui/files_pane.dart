import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seance_core/seance_core.dart';

import '../main.dart';
import '../services/remote_files_controller.dart';

class FilesScreen extends StatelessWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(
            'Files · ${state.activeSession?.config.label ?? 'Session'}',
          ),
        ),
        body: const SafeArea(top: false, child: FilesPane()),
      ),
    );
  }
}

class FilesPane extends StatelessWidget {
  const FilesPane({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final session = state.activeSession;
        if (session == null) {
          return const _FilesUnavailable(
            icon: Icons.folder_off_outlined,
            message: 'Open a terminal session to browse its files.',
          );
        }
        if (!session.isConnected || session.files == null) {
          return const _FilesUnavailable(
            icon: Icons.link_off,
            message: 'Reconnect this session to browse remote files.',
          );
        }
        final sessions = state.sessionsForServer(session.serverId);
        final ordinal =
            sessions.indexWhere((item) => item.id == session.id) + 1;
        return _RemoteBrowser(
          key: ValueKey(session.id),
          controller: session.files!,
          identity: '${session.config.label} · Session $ordinal',
          sessionId: session.id,
        );
      },
    );
  }
}

class _RemoteBrowser extends StatefulWidget {
  final RemoteFilesController controller;
  final String identity;
  final String sessionId;

  const _RemoteBrowser({
    super.key,
    required this.controller,
    required this.identity,
    required this.sessionId,
  });

  @override
  State<_RemoteBrowser> createState() => _RemoteBrowserState();
}

class _RemoteBrowserState extends State<_RemoteBrowser> {
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final content = Stack(
          children: [
            Column(
              children: [
                _BrowserHeader(
                  identity: widget.identity,
                  controller: controller,
                  onUpload: _pickUploads,
                  onNewFolder: _createFolder,
                  onEnterPath: _enterPath,
                ),
                if (controller.loading)
                  const LinearProgressIndicator(minHeight: 2),
                if (controller.error != null)
                  _ErrorBanner(
                    message: controller.error!,
                    onRetry: controller.refresh,
                  ),
                Expanded(child: _browserBody(controller)),
                if (controller.localCopies.isNotEmpty)
                  _LocalCopiesPanel(
                    copies: controller.localCopies.values.toList(),
                    onOpen: _openLocalCopy,
                    onUpload: _uploadLocalCopy,
                    onDiscard: _discardLocalCopy,
                  ),
                if (controller.transfers.isNotEmpty)
                  _TransfersPanel(controller: controller),
              ],
            ),
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.12),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 18,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.file_upload_outlined, size: 36),
                            SizedBox(height: 8),
                            Text('Upload to this directory'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
        if (!_supportsDesktopDrop) return content;
        return DropTarget(
          enable:
              TickerMode.valuesOf(context).enabled &&
              (ModalRoute.of(context)?.isCurrent ?? true),
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: (details) {
            setState(() => _dragging = false);
            unawaited(_uploadDroppedFiles(details.files));
          },
          child: content,
        );
      },
    );
  }

  Widget _browserBody(RemoteFilesController controller) {
    if (!controller.initialized && controller.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!controller.initialized) {
      return Center(
        child: FilledButton.icon(
          onPressed: controller.initialize,
          icon: const Icon(Icons.refresh),
          label: const Text('Try SFTP again'),
        ),
      );
    }
    if (controller.entries.isEmpty && !controller.loading) {
      return InkWell(
        onTap: _pickUploads,
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder_open_outlined, size: 40),
                SizedBox(height: 10),
                Text('This directory is empty'),
                SizedBox(height: 4),
                Text('Tap to choose files, or drop files here.'),
              ],
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final showDetails = constraints.maxWidth >= 430;
        return ListView.builder(
          itemCount: controller.entries.length,
          itemBuilder: (context, index) {
            final entry = controller.entries[index];
            final localCopy = controller.localCopies[entry.path];
            return _FileRow(
              entry: entry,
              showDetails: showDetails,
              hasLocalCopy: localCopy != null,
              onOpen: () => entry.isDirectory
                  ? controller.navigate(entry.path)
                  : _openRemoteFile(entry),
              onRename: () => _rename(entry),
              onDelete: () => _delete(entry),
              onUploadChanges: localCopy == null
                  ? null
                  : () => _uploadLocalCopy(localCopy),
            );
          },
        );
      },
    );
  }

  Future<void> _pickUploads() async {
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        withReadStream: true,
      );
      if (result == null) return;
      final targetDirectory = widget.controller.currentPath;
      if (targetDirectory == null) return;
      final existingNames = {
        for (final entry in widget.controller.entries) entry.name,
      };
      for (final file in result.files) {
        final stream = file.readStream;
        final path = file.path;
        if (stream == null && path == null) {
          _showError('The selected document could not be read.');
          continue;
        }
        await _uploadSource(
          name: file.name,
          length: file.size,
          openRead: () => stream ?? File(path!).openRead(),
          targetDirectory: targetDirectory,
          destinationExists: existingNames.contains(file.name),
        );
        existingNames.add(file.name);
      }
    } catch (e) {
      _showError(e);
    } finally {
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          await FilePicker.clearTemporaryFiles();
        } catch (_) {
          // Some platform implementations do not keep picker-owned temp files.
        }
      }
    }
  }

  Future<void> _uploadDroppedFiles(Iterable<DropItem> files) async {
    final targetDirectory = widget.controller.currentPath;
    if (targetDirectory == null) return;
    final existingNames = {
      for (final entry in widget.controller.entries) entry.name,
    };
    for (final file in files) {
      if (file is DropItemDirectory) {
        _showError('Folder uploads are not supported yet.');
        continue;
      }
      final bookmark = file.extraAppleBookmark;
      var scopedAccess = false;
      try {
        if (Platform.isMacOS && bookmark != null && bookmark.isNotEmpty) {
          scopedAccess = await DesktopDrop.instance
              .startAccessingSecurityScopedResource(bookmark: bookmark);
        }
        await _uploadXFile(
          file,
          targetDirectory: targetDirectory,
          destinationExists: existingNames.contains(file.name),
        );
        existingNames.add(file.name);
      } finally {
        if (scopedAccess && bookmark != null) {
          await DesktopDrop.instance.stopAccessingSecurityScopedResource(
            bookmark: bookmark,
          );
        }
      }
    }
  }

  Future<void> _uploadXFile(
    XFile file, {
    required String targetDirectory,
    required bool destinationExists,
  }) async {
    try {
      await _uploadSource(
        name: file.name,
        length: await file.length(),
        openRead: file.openRead,
        targetDirectory: targetDirectory,
        destinationExists: destinationExists,
      );
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _uploadSource({
    required String name,
    required int length,
    required Stream<List<int>> Function() openRead,
    required String targetDirectory,
    required bool destinationExists,
  }) async {
    var overwrite = false;
    if (destinationExists) {
      if (!mounted) return;
      overwrite = await _confirm(
        title: 'Replace $name?',
        message: 'An item with this name already exists on the server.',
        confirmLabel: 'Replace',
      );
      if (!overwrite) return;
    }
    await widget.controller.upload(
      name: name,
      content: openRead(),
      length: length,
      overwrite: overwrite,
      directory: targetDirectory,
    );
  }

  Future<void> _openRemoteFile(RemoteFileEntry entry) async {
    if (entry.isSymbolicLink) {
      _showError('Opening symbolic links locally is not supported yet.');
      return;
    }
    final existing = widget.controller.localCopies[entry.path];
    if (existing != null) {
      await _openLocalCopy(existing);
      return;
    }

    IOSink? sink;
    Directory? checkout;
    try {
      final temp = await getApplicationCacheDirectory();
      final random = Random.secure()
          .nextInt(0x7fffffff)
          .toRadixString(16)
          .padLeft(8, '0');
      checkout = Directory(
        '${temp.path}/seance-sftp/${widget.sessionId}/'
        '${DateTime.now().microsecondsSinceEpoch}-$random',
      );
      await checkout.create(recursive: true);
      if (Platform.isLinux) {
        await _restrictLinuxPermissions(checkout.path, '700');
      }
      final local = File('${checkout.path}/${_safeLocalName(entry.name)}');
      sink = local.openWrite();
      final snapshot = await widget.controller.download(entry, sink);
      await sink.flush();
      await sink.close();
      sink = null;
      if (Platform.isLinux) {
        await _restrictLinuxPermissions(local.path, '600');
      }
      if (!widget.controller.trackLocalCopy(snapshot, local.path)) return;
    } catch (e) {
      await sink?.close();
      if (checkout != null && await checkout.exists()) {
        await checkout.delete(recursive: true);
      }
      _showError(e);
      return;
    }
    if (!mounted) return;
    final copy = widget.controller.localCopies[entry.path];
    if (copy == null) return;
    try {
      await _openPath(copy.localPath);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openLocalCopy(ManagedRemoteFile copy) async {
    try {
      await _openPath(copy.localPath);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openPath(String path) async {
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done) {
      throw StateError(result.message);
    }
  }

  Future<void> _uploadLocalCopy(ManagedRemoteFile copy) async {
    try {
      await widget.controller.uploadLocalCopy(copy);
      _showMessage('Uploaded ${remoteBasename(copy.remotePath)}');
    } on RemoteFileException catch (e) {
      if (e.kind != RemoteFileErrorKind.conflict) {
        _showError(e);
        return;
      }
      if (!mounted) return;
      final overwrite = await _confirm(
        title: 'Remote file changed',
        message: '${e.message}\n\nOverwrite the newer remote version?',
        confirmLabel: 'Overwrite',
      );
      if (!overwrite) return;
      try {
        await widget.controller.uploadLocalCopy(
          copy,
          overwriteRemoteChanges: true,
        );
        _showMessage('Uploaded ${remoteBasename(copy.remotePath)}');
      } catch (failure) {
        _showError(failure);
      }
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _discardLocalCopy(ManagedRemoteFile copy) async {
    final discard = await _confirm(
      title: 'Discard local copy?',
      message: 'Any changes made in the local editor will be deleted.',
      confirmLabel: 'Discard',
    );
    if (discard) await widget.controller.removeLocalCopy(copy.remotePath);
  }

  Future<void> _createFolder() async {
    final name = await _askForName(title: 'New folder', action: 'Create');
    if (name == null) return;
    try {
      await widget.controller.createDirectory(name);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _rename(RemoteFileEntry entry) async {
    final name = await _askForName(
      title: 'Rename ${entry.name}',
      action: 'Rename',
      initialValue: entry.name,
    );
    if (name == null) return;
    try {
      await widget.controller.renameEntry(entry, name);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _delete(RemoteFileEntry entry) async {
    final delete = await _confirm(
      title: 'Delete ${entry.name}?',
      message: entry.isDirectory
          ? 'Only an empty directory can be deleted. This cannot be undone.'
          : 'This remote file will be permanently deleted.',
      confirmLabel: 'Delete',
    );
    if (!delete) return;
    try {
      await widget.controller.deleteEntry(entry);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _enterPath() async {
    final path = await _askForName(
      title: 'Open remote path',
      action: 'Open',
      initialValue: widget.controller.currentPath,
      validateName: false,
    );
    if (path != null && path.trim().isNotEmpty) {
      await widget.controller.navigate(path.trim());
    }
  }

  Future<String?> _askForName({
    required String title,
    required String action,
    String? initialValue,
    bool validateName = true,
  }) async {
    final text = TextEditingController(text: initialValue);
    String? validationError;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: text,
            autofocus: true,
            decoration: InputDecoration(errorText: validationError),
            onSubmitted: (_) => _submitName(
              context,
              text.text,
              validateName,
              (message) => setDialogState(() => validationError = message),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => _submitName(
                context,
                text.text,
                validateName,
                (message) => setDialogState(() => validationError = message),
              ),
              child: Text(action),
            ),
          ],
        ),
      ),
    );
    text.dispose();
    return result;
  }

  void _submitName(
    BuildContext dialogContext,
    String value,
    bool validateName,
    ValueChanged<String?> setError,
  ) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        (validateName &&
            (trimmed == '.' || trimmed == '..' || trimmed.contains('/')))) {
      setError(validateName ? 'Enter one valid name.' : 'Enter a path.');
      return;
    }
    Navigator.pop(dialogContext, trimmed);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  static String _safeLocalName(String name) {
    final safe = name.replaceAll(RegExp(r'[/\\\u0000]'), '_');
    return safe.isEmpty ? 'remote-file' : safe;
  }

  static final bool _supportsDesktopDrop =
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  static Future<void> _restrictLinuxPermissions(
    String path,
    String mode,
  ) async {
    final result = await Process.run('chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw StateError('Could not secure the local checkout permissions.');
    }
  }
}

class _BrowserHeader extends StatelessWidget {
  final String identity;
  final RemoteFilesController controller;
  final VoidCallback onUpload;
  final VoidCallback onNewFolder;
  final VoidCallback onEnterPath;

  const _BrowserHeader({
    required this.identity,
    required this.controller,
    required this.onUpload,
    required this.onNewFolder,
    required this.onEnterPath,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                identity,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _HeaderButton(
                  tooltip: 'Up',
                  icon: Icons.arrow_upward,
                  onPressed: controller.currentPath == '/'
                      ? null
                      : controller.goUp,
                ),
                _HeaderButton(
                  tooltip: 'Home',
                  icon: Icons.home_outlined,
                  onPressed: controller.goHome,
                ),
                _HeaderButton(
                  tooltip: 'Refresh',
                  icon: Icons.refresh,
                  onPressed: controller.refresh,
                ),
                Expanded(
                  child: Tooltip(
                    message: 'Open another path',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: onEnterPath,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 7,
                        ),
                        child: Text(
                          controller.currentPath ?? 'Opening SFTP…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'File actions',
                  onSelected: (value) {
                    if (value == 'upload') onUpload();
                    if (value == 'folder') onNewFolder();
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'upload',
                      child: Text('Upload files…'),
                    ),
                    PopupMenuItem(value: 'folder', child: Text('New folder…')),
                  ],
                ),
              ],
            ),
            Row(
              children: [
                Switch(
                  value: controller.followTerminal,
                  onChanged: controller.setFollowTerminal,
                ),
                const Flexible(child: Text('Follow terminal directory')),
                if (controller.followTerminal &&
                    controller.shellDirectory.value == null)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message:
                          'Waiting for OSC 7 metadata from the remote shell',
                      child: Icon(Icons.info_outline, size: 16),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const _HeaderButton({
    required this.tooltip,
    required this.icon,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    iconSize: 20,
    onPressed: onPressed,
    icon: Icon(icon),
  );
}

class _FileRow extends StatelessWidget {
  final RemoteFileEntry entry;
  final bool showDetails;
  final bool hasLocalCopy;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback? onUploadChanges;

  const _FileRow({
    required this.entry,
    required this.showDetails,
    required this.hasLocalCopy,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    this.onUploadChanges,
  });

  @override
  Widget build(BuildContext context) {
    final details = [
      if (!entry.isDirectory && entry.size != null) _formatBytes(entry.size!),
      if (entry.modifiedAt != null) _formatDate(entry.modifiedAt!.toLocal()),
    ].join(' · ');
    return ListTile(
      dense: true,
      leading: Icon(switch (entry.type) {
        RemoteFileType.directory => Icons.folder_outlined,
        RemoteFileType.symbolicLink => Icons.link,
        RemoteFileType.file => Icons.insert_drive_file_outlined,
        RemoteFileType.other => Icons.description_outlined,
      }),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: !showDetails && details.isNotEmpty
          ? Text(details, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      onTap: onOpen,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDetails && details.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                details,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (hasLocalCopy)
            IconButton(
              tooltip: 'Upload local changes',
              iconSize: 18,
              onPressed: onUploadChanges,
              icon: const Icon(Icons.edit_note),
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'open') onOpen();
              if (value == 'upload') onUploadChanges?.call();
              if (value == 'rename') onRename();
              if (value == 'delete') onDelete();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'open',
                child: Text(entry.isDirectory ? 'Open' : 'Open locally'),
              ),
              if (onUploadChanges != null)
                const PopupMenuItem(
                  value: 'upload',
                  child: Text('Upload local changes'),
                ),
              const PopupMenuItem(value: 'rename', child: Text('Rename…')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'delete', child: Text('Delete…')),
            ],
          ),
        ],
      ),
    );
  }
}

class _LocalCopiesPanel extends StatelessWidget {
  final List<ManagedRemoteFile> copies;
  final ValueChanged<ManagedRemoteFile> onOpen;
  final ValueChanged<ManagedRemoteFile> onUpload;
  final ValueChanged<ManagedRemoteFile> onDiscard;

  const _LocalCopiesPanel({
    required this.copies,
    required this.onOpen,
    required this.onUpload,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) => ExpansionTile(
    dense: true,
    leading: const Icon(Icons.edit_document, size: 20),
    title: Text('Local edits (${copies.length})'),
    children: [
      for (final copy in copies)
        ListTile(
          dense: true,
          title: Text(remoteBasename(copy.remotePath)),
          subtitle: Text(
            copy.remotePath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => onOpen(copy),
          trailing: Wrap(
            children: [
              IconButton(
                tooltip: 'Upload changes',
                icon: const Icon(Icons.upload, size: 19),
                onPressed: () => onUpload(copy),
              ),
              IconButton(
                tooltip: 'Discard local copy',
                icon: const Icon(Icons.close, size: 19),
                onPressed: () => onDiscard(copy),
              ),
            ],
          ),
        ),
    ],
  );
}

class _TransfersPanel extends StatelessWidget {
  final RemoteFilesController controller;

  const _TransfersPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    final visible = controller.transfers.reversed.take(3).toList();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(width: 12),
              const Expanded(child: Text('Transfers')),
              TextButton(
                onPressed:
                    controller.transfers.any(
                      (item) => item.status != RemoteTransferStatus.running,
                    )
                    ? controller.clearFinishedTransfers
                    : null,
                child: const Text('Clear'),
              ),
            ],
          ),
          for (final transfer in visible)
            ListTile(
              dense: true,
              leading: Icon(
                transfer.direction == RemoteTransferDirection.upload
                    ? Icons.upload
                    : Icons.download,
                size: 19,
              ),
              title: Text(
                transfer.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: transfer.status == RemoteTransferStatus.running
                  ? LinearProgressIndicator(value: transfer.progress)
                  : Text(
                      switch (transfer.status) {
                        RemoteTransferStatus.completed => 'Complete',
                        RemoteTransferStatus.failed =>
                          transfer.error ?? 'Failed',
                        RemoteTransferStatus.cancelled => 'Cancelled',
                        RemoteTransferStatus.running => '',
                      },
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: transfer.status == RemoteTransferStatus.running
                  ? IconButton(
                      tooltip: 'Cancel transfer',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => controller.cancelTransfer(transfer.id),
                    )
                  : Icon(
                      transfer.status == RemoteTransferStatus.completed
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 18,
                    ),
            ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => MaterialBanner(
    content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
    leading: const Icon(Icons.error_outline),
    actions: [TextButton(onPressed: onRetry, child: const Text('Retry'))],
  );
}

class _FilesUnavailable extends StatelessWidget {
  final IconData icon;
  final String message;

  const _FilesUnavailable({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 38),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _formatDate(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}
