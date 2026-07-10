import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seance_core/seance_core.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../main.dart';
import '../services/external_file_opener.dart';
import '../services/file_export_service.dart';
import '../services/managed_remote_file.dart';
import '../services/remote_files_controller.dart';
import '../services/xterm_engine.dart';

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
        body: const SafeArea(
          top: false,
          child: FilesPane(popAfterTerminalStage: true),
        ),
      ),
    );
  }
}

class FilesPane extends StatelessWidget {
  final bool popAfterTerminalStage;

  const FilesPane({super.key, this.popAfterTerminalStage = false});

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
          if (session.retainedLocalCopies.isNotEmpty) {
            return _RecoveredLocalEdits(session: session, state: state);
          }
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
          session: session,
          popAfterTerminalStage: popAfterTerminalStage,
        );
      },
    );
  }
}

class _RemoteBrowser extends StatefulWidget {
  final RemoteFilesController controller;
  final String identity;
  final TerminalSession session;
  final bool popAfterTerminalStage;

  const _RemoteBrowser({
    super.key,
    required this.controller,
    required this.identity,
    required this.session,
    required this.popAfterTerminalStage,
  });

  @override
  State<_RemoteBrowser> createState() => _RemoteBrowserState();
}

class _RemoteBrowserState extends State<_RemoteBrowser> {
  bool _dragging = false;
  final ExternalFileOpener _fileOpener = const ExternalFileOpener();
  final TextEditingController _filter = TextEditingController();
  final Set<String> _promptedDirtyCopies = {};

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        _queueDirtyEditPrompt(controller);
        final content = Stack(
          children: [
            Column(
              children: [
                _BrowserHeader(
                  identity: widget.identity,
                  controller: controller,
                  onUpload: _pickUploads,
                  onUploadFolder: _supportsDesktopDrop
                      ? _pickUploadFolder
                      : null,
                  onNewFolder: _createFolder,
                  onNewSymbolicLink: _createSymbolicLink,
                  onEnterPath: _enterPath,
                  onCopyPath: () => _copyRemotePath(controller.currentPath),
                  onOpenTerminalHere: _openTerminalHere,
                  filterController: _filter,
                  onDownloadSelected:
                      _supportsDesktopDrop &&
                          controller.selectedPaths.isNotEmpty
                      ? _downloadSelected
                      : null,
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
                    onOpenWithBBEdit: Platform.isMacOS
                        ? (copy) => _openLocalCopy(
                            copy,
                            editor: RemoteFileEditor.bbedit,
                          )
                        : null,
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
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_open_outlined, size: 40),
                const SizedBox(height: 10),
                Text(
                  controller.filterQuery.isNotEmpty || !controller.showHidden
                      ? 'No matching files'
                      : 'This directory is empty',
                ),
                const SizedBox(height: 4),
                const Text('Tap to choose files, or drop files here.'),
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
              selected: controller.selectedPaths.contains(entry.path),
              selectionMode: controller.selectedPaths.isNotEmpty,
              onSelect: () => controller.toggleSelection(entry.path),
              onOpen: () => entry.isDirectory
                  ? controller.navigate(entry.path)
                  : _openRemoteFile(entry),
              onRename: () => _rename(entry),
              onDelete: () => _delete(entry),
              onProperties: () => _showProperties(entry),
              onCopyPath: () => _copyRemotePath(entry.path),
              onOpenTerminalHere: entry.isDirectory
                  ? () => _openTerminalHere(entry.path)
                  : null,
              onDownload: entry.type == RemoteFileType.file
                  ? () => _exportRemoteFile(entry)
                  : entry.isDirectory && _supportsDesktopDrop
                  ? () => _downloadRemoteEntries([entry])
                  : null,
              onShare: entry.type == RemoteFileType.file && _supportsSharing
                  ? () => _shareRemoteFile(entry)
                  : null,
              onOpenWithBBEdit:
                  Platform.isMacOS && entry.type == RemoteFileType.file
                  ? () => _openRemoteFileWithEditor(
                      entry,
                      RemoteFileEditor.bbedit,
                    )
                  : null,
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

  Future<void> _pickUploadFolder() async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a folder to upload',
      );
      if (path == null) return;
      if (!mounted) return;
      final replace = await _confirm(
        title: 'Upload folder?',
        message:
            'The folder is merged with the remote destination. Existing files '
            'are replaced only if you continue.',
        confirmLabel: 'Upload and Replace',
      );
      if (!replace) return;
      await widget.controller.uploadDirectory(
        Directory(path),
        overwriteExisting: true,
      );
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _uploadDroppedFiles(Iterable<DropItem> files) async {
    final targetDirectory = widget.controller.currentPath;
    if (targetDirectory == null) return;
    final existingNames = {
      for (final entry in widget.controller.entries) entry.name,
    };
    for (final file in files) {
      final bookmark = file.extraAppleBookmark;
      var scopedAccess = false;
      try {
        if (Platform.isMacOS && bookmark != null && bookmark.isNotEmpty) {
          scopedAccess = await DesktopDrop.instance
              .startAccessingSecurityScopedResource(bookmark: bookmark);
        }
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (file is DropItemDirectory ||
            type == FileSystemEntityType.directory) {
          final replace = await _confirm(
            title: 'Upload ${file.name}?',
            message:
                'The folder is merged recursively. Existing files are replaced.',
            confirmLabel: 'Upload and Replace',
          );
          if (replace) {
            await widget.controller.uploadDirectory(
              Directory(file.path),
              directory: targetDirectory,
              overwriteExisting: true,
            );
          }
        } else {
          await _uploadXFile(
            file,
            targetDirectory: targetDirectory,
            destinationExists: existingNames.contains(file.name),
          );
        }
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

    try {
      final copy = await widget.controller.checkoutRemoteFile(entry);
      if (!mounted) return;
      await _openLocalCopy(copy);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openRemoteFileWithEditor(
    RemoteFileEntry entry,
    RemoteFileEditor editor,
  ) async {
    final existing = widget.controller.localCopies[entry.path];
    if (existing != null) {
      await _openLocalCopy(existing, editor: editor);
      return;
    }
    try {
      final copy = await widget.controller.checkoutRemoteFile(entry);
      if (!mounted) return;
      await _openLocalCopy(copy, editor: editor);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _openLocalCopy(
    ManagedRemoteFile copy, {
    RemoteFileEditor? editor,
  }) async {
    try {
      await _openPath(widget.controller.localFile(copy).path, editor: editor);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openPath(String path, {RemoteFileEditor? editor}) =>
      _fileOpener.open(
        path,
        editor:
            editor ??
            (Platform.isMacOS
                ? AppScope.of(context).services.settings.remoteFileEditor
                : RemoteFileEditor.systemDefault),
      );

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

  void _queueDirtyEditPrompt(RemoteFilesController controller) {
    final dirtyIds = {
      for (final copy in controller.localCopies.values)
        if (copy.dirty) copy.id,
    };
    _promptedDirtyCopies.removeWhere((id) => !dirtyIds.contains(id));
    final dirty = controller.localCopies.values.where(
      (copy) => copy.dirty && !_promptedDirtyCopies.contains(copy.id),
    );
    if (dirty.isEmpty) return;
    final copy = dirty.first;
    _promptedDirtyCopies.add(copy.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.localCopies.containsKey(copy.remotePath)) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${remoteBasename(copy.remotePath)} changed locally. Upload it?',
          ),
          duration: const Duration(seconds: 12),
          action: SnackBarAction(
            label: 'Upload',
            onPressed: () => unawaited(_uploadLocalCopy(copy)),
          ),
        ),
      );
    });
  }

  Future<void> _copyRemotePath(String? path) async {
    if (path == null) return;
    await Clipboard.setData(ClipboardData(text: path));
    _showMessage('Copied remote path');
  }

  Future<void> _openTerminalHere([String? path]) async {
    final target = path ?? widget.controller.currentPath;
    if (target == null) return;
    if (!widget.session.isConnected) {
      _showError('Reconnect this session first.');
      return;
    }
    final engine = widget.session.engine;
    final integration = engine.shellIntegration.value;
    final shell = integration.shell;
    if (shell == null) {
      _showError('Shell integration is required. Copy the path instead.');
      return;
    }
    if (integration.phase != TerminalPromptPhase.acceptingInput) {
      _showError('Wait for the shell prompt.');
      return;
    }
    if (integration.inputSincePrompt || engine.pendingInput.isNotEmpty) {
      _showError('Clear or submit the current terminal input first.');
      return;
    }
    late final String preview;
    try {
      preview = buildChangeDirectoryCommand(target, shell: shell);
    } on ArgumentError {
      _showError('This path cannot be staged safely.');
      return;
    }
    final insert = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Insert command into terminal?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Review the command. Séance will not press Enter.'),
            const SizedBox(height: 12),
            SelectableText(preview),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Insert'),
          ),
        ],
      ),
    );
    if (insert != true || !mounted) return;
    final result = engine.stageChangeDirectory(target);
    final message = switch (result) {
      TerminalStageResult.staged =>
        'Inserted into the prompt. Press Enter in the terminal to run.',
      TerminalStageResult.shellIntegrationRequired =>
        'Shell integration is required. Copy the path instead.',
      TerminalStageResult.promptNotReady => 'Wait for the shell prompt.',
      TerminalStageResult.pendingInput =>
        'Clear or submit the current terminal input first.',
      TerminalStageResult.invalidPath => 'This path cannot be staged safely.',
    };
    if (result != TerminalStageResult.staged) {
      _showError(message);
      return;
    }
    _showMessage(message);
    if (widget.popAfterTerminalStage && mounted) Navigator.of(context).pop();
  }

  Future<StagedExportFile> _stageRemoteFile(RemoteFileEntry entry) async {
    if (entry.type != RemoteFileType.file) {
      throw StateError('Only regular files can be downloaded.');
    }
    final root = await getTemporaryDirectory();
    final directory = await root.createTemp('seance-export-');
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_safeLocalName(entry.name)}',
    );
    IOSink? sink;
    try {
      sink = file.openWrite();
      await widget.controller.download(entry, sink);
      await sink.flush();
      await sink.close();
      return StagedExportFile(
        file: file,
        fileName: _safeLocalName(entry.name),
        mimeType: _mimeType(entry.name),
      );
    } catch (_) {
      await sink?.close();
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _exportRemoteFile(RemoteFileEntry entry) async {
    StagedExportFile? staged;
    try {
      staged = await _stageRemoteFile(entry);
      final service = FileExportService(
        desktopSave: (file) async {
          final destination = await FilePicker.saveFile(
            fileName: file.fileName,
          );
          if (destination == null) return null;
          await _copyExportAtomically(file.file, File(destination));
          return destination;
        },
      );
      if (Platform.isAndroid && !await service.hasExportDirectoryAccess()) {
        if (!await service.pickExportDirectory()) return;
      }
      final destination = await service.exportFile(staged);
      if (destination != null) _showMessage('Saved ${staged.fileName}');
    } catch (error) {
      _showError(error);
    } finally {
      await _deleteStagedExport(staged);
    }
  }

  Future<void> _shareRemoteFile(RemoteFileEntry entry) async {
    StagedExportFile? staged;
    try {
      staged = await _stageRemoteFile(entry);
      if (!mounted) return;
      final renderBox = context.findRenderObject() as RenderBox?;
      final origin = renderBox == null
          ? null
          : renderBox.localToGlobal(Offset.zero) & renderBox.size;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(staged.file.path, mimeType: staged.mimeType)],
          title: staged.fileName,
          sharePositionOrigin: origin,
        ),
      );
      final retained = staged;
      Timer(const Duration(hours: 1), () {
        unawaited(_deleteStagedExport(retained));
      });
      staged = null;
    } catch (error) {
      _showError(error);
    } finally {
      await _deleteStagedExport(staged);
    }
  }

  Future<void> _deleteStagedExport(StagedExportFile? staged) async {
    if (staged == null) return;
    try {
      final parent = staged.file.parent;
      if (await parent.exists()) await parent.delete(recursive: true);
    } catch (_) {
      // Temporary exports are also subject to normal OS cache eviction.
    }
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

  Future<void> _createSymbolicLink() async {
    final name = await _askForName(title: 'New symbolic link', action: 'Next');
    if (name == null) return;
    final target = await _askForName(
      title: 'Link target for $name',
      action: 'Create',
      validateName: false,
    );
    if (target == null) return;
    try {
      await widget.controller.createSymbolicLink(name, target);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _downloadSelected() =>
      _downloadRemoteEntries(widget.controller.selectedEntries);

  Future<void> _downloadRemoteEntries(Iterable<RemoteFileEntry> entries) async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a download destination',
      );
      if (path == null) return;
      if (!mounted) return;
      final replace = await _confirm(
        title:
            'Download ${entries.length == 1 ? entries.first.name : '${entries.length} items'}?',
        message:
            'Folders are copied recursively. Existing local files are replaced.',
        confirmLabel: 'Download and Replace',
      );
      if (!replace) return;
      await widget.controller.downloadEntries(
        entries,
        Directory(path),
        overwriteExisting: true,
      );
      widget.controller.clearSelection();
      _showMessage('Download complete');
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _showProperties(RemoteFileEntry entry) async {
    String? linkTarget;
    if (entry.isSymbolicLink) {
      try {
        linkTarget = await widget.controller.readSymbolicLink(entry);
      } catch (error) {
        _showError(error);
        return;
      }
    }
    if (!mounted) return;
    final mode = entry.mode == null
        ? ''
        : (entry.mode! & 0xFFF).toRadixString(8).padLeft(4, '0');
    final modeController = TextEditingController(text: mode);
    String? validationError;
    final updatedMode = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(entry.name),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(entry.path),
                const SizedBox(height: 12),
                Text('Type: ${entry.type.name}'),
                if (entry.size != null)
                  Text('Size: ${_formatBytes(entry.size!)}'),
                if (entry.uid != null || entry.gid != null)
                  Text('Owner: ${entry.uid ?? '?'}:${entry.gid ?? '?'}'),
                if (entry.modifiedAt != null)
                  Text('Modified: ${_formatDate(entry.modifiedAt!.toLocal())}'),
                if (linkTarget != null) ...[
                  const SizedBox(height: 8),
                  const Text('Symbolic-link target'),
                  SelectableText(linkTarget),
                ],
                if (!entry.isSymbolicLink) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: modeController,
                    decoration: InputDecoration(
                      labelText: 'Permissions (octal)',
                      hintText: '0644',
                      errorText: validationError,
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            if (!entry.isSymbolicLink)
              FilledButton(
                onPressed: () {
                  final text = modeController.text.trim();
                  final parsed = int.tryParse(text, radix: 8);
                  if (parsed == null || parsed < 0 || parsed > 0xFFF) {
                    setDialogState(() {
                      validationError =
                          'Enter an octal mode from 0000 to 7777.';
                    });
                    return;
                  }
                  Navigator.pop(context, parsed);
                },
                child: const Text('Apply mode'),
              ),
          ],
        ),
      ),
    );
    modeController.dispose();
    if (updatedMode == null ||
        (entry.mode != null && updatedMode == (entry.mode! & 0xFFF))) {
      return;
    }
    try {
      await widget.controller.setMode(entry, updatedMode);
    } catch (error) {
      _showError(error);
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
    final hasLocalCopy = widget.controller.localCopies.containsKey(entry.path);
    final delete = await _confirm(
      title: 'Delete ${entry.name}?',
      message: entry.isDirectory
          ? 'Only an empty directory can be deleted. This cannot be undone.'
          : hasLocalCopy
          ? 'The remote file will be permanently deleted. Its managed local '
                'copy is retained until you upload or discard it.'
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
    var safe = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f\x7f]'), '_');
    safe = safe.replaceFirst(RegExp(r'[. ]+$'), '_');
    if (safe.isEmpty ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
          caseSensitive: false,
        ).hasMatch(safe)) {
      return 'remote-file';
    }
    return safe;
  }

  static final bool _supportsDesktopDrop =
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  static final bool _supportsSharing =
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  static String _mimeType(String name) {
    final extension = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return switch (extension) {
      'txt' || 'log' || 'conf' || 'ini' || 'md' => 'text/plain',
      'json' => 'application/json',
      'yaml' || 'yml' => 'application/yaml',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'pdf' => 'application/pdf',
      _ => 'application/octet-stream',
    };
  }

  static Future<void> _copyExportAtomically(File source, File target) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.seance-${uuidV4()}.part');
    final backup = File('${target.path}.seance-${uuidV4()}.backup');
    try {
      await source.copy(temporary.path);
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.file &&
              type != FileSystemEntityType.notFound)) {
        throw FileSystemException(
          'Refusing to replace a non-regular destination',
          target.path,
        );
      }
      if (type == FileSystemEntityType.file) {
        await target.rename(backup.path);
      }
      try {
        await temporary.rename(target.path);
      } catch (_) {
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // The destination is complete; a stale backup is safer than rolling
          // back a successful export after commit.
        }
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class _BrowserHeader extends StatelessWidget {
  final String identity;
  final RemoteFilesController controller;
  final VoidCallback onUpload;
  final VoidCallback? onUploadFolder;
  final VoidCallback onNewFolder;
  final VoidCallback onNewSymbolicLink;
  final VoidCallback onEnterPath;
  final VoidCallback onCopyPath;
  final VoidCallback onOpenTerminalHere;
  final TextEditingController filterController;
  final VoidCallback? onDownloadSelected;

  const _BrowserHeader({
    required this.identity,
    required this.controller,
    required this.onUpload,
    this.onUploadFolder,
    required this.onNewFolder,
    required this.onNewSymbolicLink,
    required this.onEnterPath,
    required this.onCopyPath,
    required this.onOpenTerminalHere,
    required this.filterController,
    this.onDownloadSelected,
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
                    if (value == 'upload_folder') onUploadFolder?.call();
                    if (value == 'folder') onNewFolder();
                    if (value == 'symlink') onNewSymbolicLink();
                    if (value == 'copy_path') onCopyPath();
                    if (value == 'terminal_here') onOpenTerminalHere();
                    if (value == 'bookmark') {
                      unawaited(controller.toggleCurrentBookmark());
                    }
                    if (value == 'hidden') {
                      controller.setShowHidden(!controller.showHidden);
                    }
                    if (value.startsWith('open_bookmark:')) {
                      unawaited(
                        controller.navigate(
                          value.substring('open_bookmark:'.length),
                        ),
                      );
                    }
                    if (value.startsWith('remove_bookmark:')) {
                      unawaited(
                        controller.removeBookmark(
                          value.substring('remove_bookmark:'.length),
                        ),
                      );
                    }
                    if (value.startsWith('sort:')) {
                      final field = RemoteSortField.values.firstWhere(
                        (field) => field.name == value.substring(5),
                      );
                      final direction =
                          controller.sortField == field &&
                              controller.sortDirection ==
                                  RemoteSortDirection.ascending
                          ? RemoteSortDirection.descending
                          : RemoteSortDirection.ascending;
                      controller.setSort(field, direction);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'upload',
                      child: Text('Upload files…'),
                    ),
                    if (onUploadFolder != null)
                      const PopupMenuItem(
                        value: 'upload_folder',
                        child: Text('Upload folder…'),
                      ),
                    const PopupMenuItem(
                      value: 'folder',
                      child: Text('New folder…'),
                    ),
                    const PopupMenuItem(
                      value: 'symlink',
                      child: Text('New symbolic link…'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'copy_path',
                      child: Text('Copy current path'),
                    ),
                    const PopupMenuItem(
                      value: 'terminal_here',
                      child: Text('Open terminal here'),
                    ),
                    PopupMenuItem(
                      value: 'bookmark',
                      child: Text(
                        controller.currentPathBookmarked
                            ? 'Remove current bookmark'
                            : 'Bookmark current path',
                      ),
                    ),
                    for (final path in controller.bookmarks) ...[
                      PopupMenuItem(
                        value: 'open_bookmark:$path',
                        child: Text(
                          'Open $path',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'remove_bookmark:$path',
                        child: Text(
                          'Remove bookmark $path',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'hidden',
                      child: Text(
                        controller.showHidden
                            ? 'Hide dotfiles'
                            : 'Show dotfiles',
                      ),
                    ),
                    for (final field in RemoteSortField.values)
                      PopupMenuItem(
                        value: 'sort:${field.name}',
                        child: Text(
                          'Sort by ${field.name}${controller.sortField == field
                              ? controller.sortDirection == RemoteSortDirection.ascending
                                    ? ' ↑'
                                    : ' ↓'
                              : ''}',
                        ),
                      ),
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
                    controller.reportedShellDirectory == null)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message:
                          'Waiting for directory metadata from the remote shell',
                      child: Icon(Icons.info_outline, size: 16),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
              child: TextField(
                controller: filterController,
                onChanged: controller.setFilterQuery,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filter files',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: controller.filterQuery.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear filter',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            filterController.clear();
                            controller.setFilterQuery('');
                          },
                        ),
                ),
              ),
            ),
            if (controller.selectedPaths.isNotEmpty)
              Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${controller.selectedPaths.length} selected'),
                  ),
                  if (onDownloadSelected != null)
                    IconButton(
                      tooltip: 'Download selected',
                      icon: const Icon(Icons.download),
                      onPressed: onDownloadSelected,
                    ),
                  TextButton(
                    onPressed: controller.clearSelection,
                    child: const Text('Clear'),
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
  final bool selected;
  final bool selectionMode;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onProperties;
  final VoidCallback onCopyPath;
  final VoidCallback? onOpenTerminalHere;
  final VoidCallback? onDownload;
  final VoidCallback? onShare;
  final VoidCallback? onOpenWithBBEdit;
  final VoidCallback? onUploadChanges;

  const _FileRow({
    required this.entry,
    required this.showDetails,
    required this.hasLocalCopy,
    required this.selected,
    required this.selectionMode,
    required this.onSelect,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    required this.onProperties,
    required this.onCopyPath,
    this.onOpenTerminalHere,
    this.onDownload,
    this.onShare,
    this.onOpenWithBBEdit,
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
      selected: selected,
      leading: selectionMode
          ? Checkbox(value: selected, onChanged: (_) => onSelect())
          : Icon(switch (entry.type) {
              RemoteFileType.directory => Icons.folder_outlined,
              RemoteFileType.symbolicLink => Icons.link,
              RemoteFileType.file => Icons.insert_drive_file_outlined,
              RemoteFileType.other => Icons.description_outlined,
            }),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: !showDetails && details.isNotEmpty
          ? Text(details, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      onTap: selectionMode ? onSelect : onOpen,
      onLongPress: onSelect,
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
              if (value == 'select') onSelect();
              if (value == 'upload') onUploadChanges?.call();
              if (value == 'bbedit') onOpenWithBBEdit?.call();
              if (value == 'download') onDownload?.call();
              if (value == 'share') onShare?.call();
              if (value == 'copy_path') onCopyPath();
              if (value == 'terminal_here') onOpenTerminalHere?.call();
              if (value == 'rename') onRename();
              if (value == 'delete') onDelete();
              if (value == 'properties') onProperties();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'open',
                child: Text(entry.isDirectory ? 'Open' : 'Open locally'),
              ),
              const PopupMenuItem(value: 'select', child: Text('Select')),
              if (onOpenWithBBEdit != null)
                const PopupMenuItem(
                  value: 'bbedit',
                  child: Text('Open with BBEdit'),
                ),
              if (onUploadChanges != null)
                const PopupMenuItem(
                  value: 'upload',
                  child: Text('Upload local changes'),
                ),
              if (onDownload != null)
                const PopupMenuItem(
                  value: 'download',
                  child: Text('Download / Save as…'),
                ),
              if (onShare != null)
                const PopupMenuItem(value: 'share', child: Text('Share…')),
              const PopupMenuItem(
                value: 'copy_path',
                child: Text('Copy remote path'),
              ),
              if (onOpenTerminalHere != null)
                const PopupMenuItem(
                  value: 'terminal_here',
                  child: Text('Open terminal here'),
                ),
              const PopupMenuItem(value: 'rename', child: Text('Rename…')),
              const PopupMenuItem(
                value: 'properties',
                child: Text('Properties…'),
              ),
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
  final ValueChanged<ManagedRemoteFile>? onOpenWithBBEdit;
  final ValueChanged<ManagedRemoteFile> onUpload;
  final ValueChanged<ManagedRemoteFile> onDiscard;

  const _LocalCopiesPanel({
    required this.copies,
    required this.onOpen,
    this.onOpenWithBBEdit,
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
            '${copy.remotePath}\n${copy.missing
                ? 'Local file is missing'
                : copy.dirty
                ? 'Modified locally · review before upload'
                : 'Watching for local saves'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => onOpen(copy),
          trailing: Wrap(
            children: [
              if (onOpenWithBBEdit != null)
                IconButton(
                  tooltip: 'Open with BBEdit',
                  icon: const Icon(Icons.edit_outlined, size: 19),
                  onPressed: copy.missing
                      ? null
                      : () => onOpenWithBBEdit!(copy),
                ),
              IconButton(
                tooltip: 'Upload changes',
                icon: const Icon(Icons.upload, size: 19),
                onPressed: copy.missing ? null : () => onUpload(copy),
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

class _RecoveredLocalEdits extends StatelessWidget {
  final TerminalSession session;
  final AppState state;

  const _RecoveredLocalEdits({required this.session, required this.state});

  @override
  Widget build(BuildContext context) {
    final copies = session.retainedLocalCopies.values.toList();
    return Column(
      children: [
        MaterialBanner(
          leading: const Icon(Icons.cloud_off_outlined),
          content: const Text(
            'These local edits were recovered. Reconnect before uploading; '
            'Open and Discard remain available offline.',
          ),
          actions: [
            TextButton(
              onPressed: () => state.reconnect(session.id),
              child: const Text('Reconnect'),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            itemCount: copies.length,
            itemBuilder: (context, index) {
              final copy = copies[index];
              return ListTile(
                leading: Icon(
                  copy.missing
                      ? Icons.file_present_outlined
                      : Icons.edit_document,
                ),
                title: Text(remoteBasename(copy.remotePath)),
                subtitle: Text(
                  copy.missing
                      ? 'Local checkout is missing'
                      : copy.dirty
                      ? '${copy.remotePath}\nModified locally'
                      : copy.remotePath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: copy.missing
                    ? null
                    : () async {
                        try {
                          await const ExternalFileOpener().open(
                            state.services.managedRemoteFiles
                                .checkoutFile(copy.localPath)
                                .path,
                            editor: state.services.settings.remoteFileEditor,
                          );
                        } catch (error) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(error.toString())),
                          );
                        }
                      },
                trailing: IconButton(
                  tooltip: 'Discard local copy',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final discard = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Discard local copy?'),
                        content: const Text(
                          'Any changes not uploaded to the server are deleted.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Discard'),
                          ),
                        ],
                      ),
                    );
                    if (discard == true) {
                      await state.discardRetainedLocalCopy(session.id, copy);
                    }
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
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
