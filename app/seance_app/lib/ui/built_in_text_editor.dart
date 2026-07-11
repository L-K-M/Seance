import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../services/managed_remote_file_store.dart';

const builtInEditorMaximumBytes = 4 * 1024 * 1024;

class BuiltInTextDocument {
  final String text;
  final bool hasUtf8Bom;
  final String lineEnding;
  final String sha256;

  const BuiltInTextDocument({
    required this.text,
    required this.hasUtf8Bom,
    required this.lineEnding,
    required this.sha256,
  });
}

Future<String> loadBuiltInTextDocument(
  File file, {
  int maximumBytes = builtInEditorMaximumBytes,
}) async => (await loadBuiltInTextDocumentDetails(
  file,
  maximumBytes: maximumBytes,
)).text;

Future<BuiltInTextDocument> loadBuiltInTextDocumentDetails(
  File file, {
  int maximumBytes = builtInEditorMaximumBytes,
}) async {
  final length = await file.length();
  if (length > maximumBytes) {
    throw StateError(
      'The built-in editor supports text files up to '
      '${(maximumBytes / (1024 * 1024)).toStringAsFixed(0)} MB.',
    );
  }
  final before = await streamedFileSha256(file);
  final bytes = await file.readAsBytes();
  if (bytes.length > maximumBytes) {
    throw StateError(
      'The built-in editor supports text files up to '
      '${(maximumBytes / (1024 * 1024)).toStringAsFixed(0)} MB.',
    );
  }
  final after = await streamedFileSha256(file);
  if (before != after) {
    throw StateError('The local copy changed while it was being opened.');
  }
  late final String text;
  try {
    text = const Utf8Decoder(allowMalformed: false).convert(bytes);
  } on FormatException {
    throw StateError('This file is not valid UTF-8 text.');
  }
  if (text.contains('\u0000')) {
    throw StateError('This file appears to be binary, not editable text.');
  }
  final crlfCount = RegExp(r'\r\n').allMatches(text).length;
  final lfCount = RegExp(r'(?<!\r)\n').allMatches(text).length;
  return BuiltInTextDocument(
    text: text,
    hasUtf8Bom:
        bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf,
    lineEnding: crlfCount > lfCount ? '\r\n' : '\n',
    sha256: after,
  );
}

Future<String> saveBuiltInTextDocument(
  File file,
  String text, {
  bool hasUtf8Bom = false,
  String lineEnding = '\n',
  String? expectedSha256,
}) async {
  final normalized = _normalizeLineEndings(text, lineEnding);
  final bytes = <int>[
    if (hasUtf8Bom) ...const [0xef, 0xbb, 0xbf],
    ...utf8.encode(normalized),
  ];
  if (bytes.length > builtInEditorMaximumBytes) {
    throw StateError('The edited file exceeds the 4 MB built-in editor limit.');
  }
  final temporary = File('${file.path}.seance-${uuidV4()}.edit');
  final backup = File('${file.path}.seance-${uuidV4()}.backup');
  RandomAccessFile? handle;
  try {
    await temporary.create(exclusive: true);
    handle = await temporary.open(mode: FileMode.writeOnly);
    await handle.writeFrom(bytes);
    await handle.flush();
    await handle.close();
    handle = null;
    final savedSha256 = await streamedFileSha256(temporary);

    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'The local checkout is missing or no longer a regular file.',
        file.path,
      );
    }
    await file.rename(backup.path);
    if (expectedSha256 != null &&
        await streamedFileSha256(backup) != expectedSha256) {
      await backup.rename(file.path);
      throw StateError(
        'The local copy changed in another editor. Reopen it before saving to '
        'avoid losing those changes.',
      );
    }
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
          'The local copy changed while it was being saved.',
          file.path,
        );
      }
      await temporary.rename(file.path);
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
    try {
      await backup.delete();
    } on FileSystemException {
      // The new file is safely committed; retaining a backup is preferable to
      // rolling back or reporting a false save failure.
    }
    return savedSha256;
  } finally {
    await handle?.close();
    if (await temporary.exists()) await temporary.delete();
  }
}

String _normalizeLineEndings(String text, String lineEnding) {
  if (lineEnding != '\r\n') return text;
  return text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', '\r\n');
}

class BuiltInTextEditorScreen extends StatefulWidget {
  final File file;
  final String remotePath;
  final String? initialText;
  final Future<void> Function(File file, String text)? saveDocument;
  final Future<void> Function()? onSaved;
  final Future<bool> Function()? onUpload;

  const BuiltInTextEditorScreen({
    super.key,
    required this.file,
    required this.remotePath,
    this.initialText,
    this.saveDocument,
    this.onSaved,
    this.onUpload,
  });

  @override
  State<BuiltInTextEditorScreen> createState() =>
      _BuiltInTextEditorScreenState();
}

class _BuiltInTextEditorScreenState extends State<BuiltInTextEditorScreen> {
  final TextEditingController _text = TextEditingController();
  String _savedText = '';
  String? _error;
  String? _baselineSha256;
  bool _hasUtf8Bom = false;
  String _lineEnding = '\n';
  bool _loading = true;
  bool _saving = false;

  bool get _dirty => !_loading && _text.text != _savedText;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
    final initialText = widget.initialText;
    if (initialText == null) {
      _load();
    } else {
      _savedText = initialText;
      _text.text = initialText;
      _loading = false;
    }
  }

  Future<void> _load() async {
    try {
      final document = await loadBuiltInTextDocumentDetails(widget.file);
      if (!mounted) return;
      _savedText = document.text;
      _text.text = document.text;
      _baselineSha256 = document.sha256;
      _hasUtf8Bom = document.hasUtf8Bom;
      _lineEnding = document.lineEnding;
    } catch (error) {
      if (mounted) _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _changed() {
    if (mounted && !_loading) setState(() {});
  }

  @override
  void dispose() {
    _text.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved changes?'),
            content: const Text(
              'Changes not saved to the managed local copy will be lost.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep editing'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save({bool upload = false}) async {
    if (_saving || _loading || _error != null) return;
    setState(() => _saving = true);
    final value = _text.text;
    try {
      final customSave = widget.saveDocument;
      if (customSave == null) {
        _baselineSha256 = await saveBuiltInTextDocument(
          widget.file,
          value,
          hasUtf8Bom: _hasUtf8Bom,
          lineEnding: _lineEnding,
          expectedSha256: _baselineSha256,
        );
      } else {
        await customSave(widget.file, value);
      }
      if (!mounted) return;
      setState(() => _savedText = value);
      await widget.onSaved?.call();
      final uploaded = upload && widget.onUpload != null
          ? await widget.onUpload!()
          : false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              upload
                  ? uploaded
                        ? _dirty
                              ? 'Uploaded the saved version; newer edits remain unsaved.'
                              : 'Saved and uploaded.'
                        : 'Saved locally; not uploaded.'
                  : 'Saved locally.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = remoteBasename(widget.remotePath);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !await _confirmDiscard() || !context.mounted) return;
        Navigator.of(context).pop();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        },
        child: Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  widget.remotePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Save locally',
                onPressed: _dirty && !_saving ? _save : null,
                icon: const Icon(Icons.save_outlined),
              ),
              if (widget.onUpload != null)
                IconButton(
                  tooltip: 'Save and upload',
                  onPressed: !_saving ? () => _save(upload: true) : null,
                  icon: const Icon(Icons.cloud_upload_outlined),
                ),
            ],
          ),
          body: _body(),
          bottomNavigationBar: _loading || _error != null
              ? null
              : SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      '${_text.text.split('\n').length} lines · '
                      '${utf8.encode(_text.text).length} bytes'
                      '${_dirty ? ' · Unsaved' : ''}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.text_snippet_outlined, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return TextField(
      controller: _text,
      autofocus: true,
      expands: true,
      maxLines: null,
      minLines: null,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 14,
        height: 1.35,
      ),
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(14),
      ),
    );
  }
}
