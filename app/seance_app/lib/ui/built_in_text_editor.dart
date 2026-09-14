import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../services/managed_remote_file_store.dart';
import '../services/remote_files_controller.dart';
import '../theme.dart';
import 'editor_syntax.dart';
import 'top_toast.dart';

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

  /// When set, the editor watches this controller's drift flag for
  /// [remotePath] and offers to reload the file once the server copy no
  /// longer matches what the local checkout was taken from.
  final RemoteFilesController? remoteFiles;
  final Future<void> Function(File file, String text)? saveDocument;
  final Future<void> Function()? onSaved;
  final Future<bool> Function()? onUpload;

  const BuiltInTextEditorScreen({
    super.key,
    required this.file,
    required this.remotePath,
    this.initialText,
    this.remoteFiles,
    this.saveDocument,
    this.onSaved,
    this.onUpload,
  });

  @override
  State<BuiltInTextEditorScreen> createState() =>
      _BuiltInTextEditorScreenState();
}

class _BuiltInTextEditorScreenState extends State<BuiltInTextEditorScreen>
    with WidgetsBindingObserver {
  late final CodeEditingController _text = CodeEditingController(
    language: syntaxLanguageFor(widget.remotePath),
  );
  final ScrollController _scroll = ScrollController();
  final FocusNode _editorFocus = FocusNode();
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _savedText = '';
  String? _error;
  String? _baselineSha256;
  bool _hasUtf8Bom = false;
  String _lineEnding = '\n';
  bool _loading = true;
  bool _saving = false;
  bool _reloading = false;
  bool _searchOpen = false;
  bool _searchCaseSensitive = false;
  List<TextRange> _matches = const [];
  int _activeMatch = -1;
  String _lastSearchedText = '';
  String? _lastQuery;
  double? _editorWidth;

  /// Inset around the document text; also part of the scroll-to-match math.
  static const double _editorPadding = 14;

  /// Matches the terminal's monospace stack; a bare 'monospace' family does
  /// not resolve on every platform (notably macOS/iOS).
  static final TextStyle _editorTextStyle = TextStyle(
    fontFamily: SeanceTheme.monoFallback.first,
    fontFamilyFallback: SeanceTheme.monoFallback,
    fontSize: 14,
    height: 1.35,
  );

  bool get _dirty => !_loading && _text.text != _savedText;

  /// Tri-state drift answer: true once a freshness check has proven the
  /// server copy moved on (or disappeared), false while it still matches,
  /// null until the first check lands.
  bool? get _remoteChanged =>
      widget.remoteFiles?.remoteChangedFor(widget.remotePath);

  bool get _remoteMissing {
    final files = widget.remoteFiles;
    return files != null &&
        files.latestRemoteSnapshots.containsKey(widget.remotePath) &&
        files.latestRemoteSnapshots[widget.remotePath] == null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _text.addListener(_changed);
    _search.addListener(_searchChanged);
    final initialText = widget.initialText;
    if (initialText == null) {
      _load();
    } else {
      _applyLoadedText(initialText);
      _loading = false;
    }
    _checkRemoteDrift();
  }

  /// Best-effort re-stat of the server copy — drives the reload banner.
  void _checkRemoteDrift() {
    unawaited(
      widget.remoteFiles?.checkRemoteSnapshot(widget.remotePath) ??
          Future<void>.value(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the app is the cheapest moment to notice remote drift a
    // command-completion listener cannot see (another session, a cron job).
    if (state == AppLifecycleState.resumed) _checkRemoteDrift();
  }

  Future<void> _load() async {
    try {
      _error = null;
      final document = await loadBuiltInTextDocumentDetails(widget.file);
      if (!mounted) return;
      _applyLoadedText(document.text);
      _baselineSha256 = document.sha256;
      _hasUtf8Bom = document.hasUtf8Bom;
      _lineEnding = document.lineEnding;
    } catch (error) {
      if (mounted) _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Install the document with the caret and viewport at the very top, and
  /// re-detect the language now that a `#!` line is available.
  void _applyLoadedText(String text) {
    _savedText = text;
    final newline = text.indexOf('\n');
    _text.language = syntaxLanguageFor(
      widget.remotePath,
      firstLine: newline < 0 ? text : text.substring(0, newline),
    );
    _text.value = TextEditingValue(
      text: text,
      selection: const TextSelection.collapsed(offset: 0),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _changed() {
    if (!mounted || _loading) return;
    if (_searchOpen &&
        !identical(_text.text, _lastSearchedText) &&
        _text.text != _lastSearchedText) {
      _updateSearchMatches(resetActive: false);
    }
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.removeListener(_searchChanged);
    _text.removeListener(_changed);
    _text.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _editorFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---- Search -------------------------------------------------------------

  void _openSearch() {
    if (_loading || _error != null) return;
    final selection = _text.selection;
    String? prefill;
    if (selection.isValid && !selection.isCollapsed) {
      final selected = selection.textInside(_text.text);
      if (selected.isNotEmpty &&
          !selected.contains('\n') &&
          selected.length <= 200) {
        prefill = selected;
      }
    }
    _searchOpen = true;
    if (prefill != null) {
      _search.text = prefill; // Listener recomputes the matches.
    } else {
      _updateSearchMatches(resetActive: true);
    }
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
    _searchFocus.requestFocus();
    setState(() {});
    _revealActiveMatch();
  }

  void _closeSearch() {
    if (!_searchOpen) return;
    _searchOpen = false;
    _matches = const [];
    _activeMatch = -1;
    _lastQuery = null;
    _text.setSearchMatches(const [], -1);
    setState(() {});
    _editorFocus.requestFocus();
  }

  void _searchChanged() {
    if (!mounted || !_searchOpen) return;
    // The controller also notifies on selection changes inside the query
    // field; only an actual query edit warrants re-searching the document.
    if (_search.text == _lastQuery) return;
    _updateSearchMatches(resetActive: true);
    setState(() {});
    _revealActiveMatch();
  }

  void _updateSearchMatches({required bool resetActive}) {
    _lastSearchedText = _text.text;
    _lastQuery = _search.text;
    _matches = _searchOpen
        ? findSearchMatches(
            _text.text,
            _search.text,
            caseSensitive: _searchCaseSensitive,
          )
        : const [];
    if (_matches.isEmpty) {
      _activeMatch = -1;
    } else if (resetActive ||
        _activeMatch < 0 ||
        _activeMatch >= _matches.length) {
      // Start from the first match at or after the caret.
      final caret = _text.selection.isValid ? _text.selection.start : 0;
      final index = _matches.indexWhere((match) => match.start >= caret);
      _activeMatch = index < 0 ? 0 : index;
    }
    _text.setSearchMatches(_matches, _activeMatch);
  }

  void _nextMatch() => _stepMatch(1);

  void _previousMatch() => _stepMatch(-1);

  void _stepMatch(int delta) {
    if (_matches.isEmpty) return;
    _activeMatch = _activeMatch < 0
        ? (delta > 0 ? 0 : _matches.length - 1)
        : (_activeMatch + delta + _matches.length) % _matches.length;
    _text.setSearchMatches(_matches, _activeMatch);
    // Park the caret on the match so editing or Escape resumes there. Both
    // controller mutations notify, and _changed rebuilds — no setState here.
    final match = _matches[_activeMatch];
    _text.selection = TextSelection(
      baseOffset: match.start,
      extentOffset: match.end,
    );
    _revealActiveMatch();
  }

  void _toggleCaseSensitive() {
    _searchCaseSensitive = !_searchCaseSensitive;
    _updateSearchMatches(resetActive: true);
    setState(() {});
    _revealActiveMatch();
  }

  /// Scroll the viewport so the active match is about a third from the top.
  /// Small files get a precise text layout; very large ones fall back to a
  /// line-count estimate rather than laying out megabytes of text.
  void _revealActiveMatch() {
    if (_activeMatch < 0 || _activeMatch >= _matches.length) return;
    if (!_scroll.hasClients) return;
    final match = _matches[_activeMatch];
    final text = _text.text;
    final width = _editorWidth;
    double dy;
    if (text.length <= syntaxHighlightingMaxChars && width != null) {
      final textWidth = width - 2 * _editorPadding;
      // Only the text before the match determines its vertical position, so
      // lay out just that prefix: a full-document layout on every search
      // keystroke would jank on files approaching the highlighting cap. (A
      // soft wrap mid-word at the boundary can be off by one line — fine
      // for positioning the viewport.)
      final prefix = text.substring(0, match.start);
      final painter = TextPainter(
        text: TextSpan(text: prefix, style: _editorTextStyle),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: textWidth > 1 ? textWidth : 1);
      dy = painter.getOffsetForCaret(
        TextPosition(offset: prefix.length),
        Rect.zero,
      ).dy;
      painter.dispose();
    } else {
      var line = 0;
      for (var i = 0; i < match.start; i++) {
        if (text.codeUnitAt(i) == 0x0a) line++;
      }
      final fontSize = MediaQuery.textScalerOf(
        context,
      ).scale(_editorTextStyle.fontSize!);
      dy = line * fontSize * _editorTextStyle.height!;
    }
    dy += _editorPadding; // The text sits below the field's top content inset.
    final position = _scroll.position;
    final target = (dy - position.viewportDimension / 3).clamp(
      0.0,
      position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
    );
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
    final uploadAfterSave = upload && widget.onUpload != null;
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
      var uploaded = false;
      if (uploadAfterSave) {
        // Upload immediately, no confirmation. The upload reconciles this
        // copy itself; onSaved only needs to run when the upload didn't —
        // including when it throws, hence the finally.
        try {
          uploaded = await widget.onUpload!();
        } finally {
          if (!uploaded) await widget.onSaved?.call();
        }
      } else {
        await widget.onSaved?.call();
      }
      if (mounted) {
        showTopToastIn(
          context,
          message: uploadAfterSave
              ? uploaded
                    ? _dirty
                          ? 'Uploaded the saved version; newer edits remain unsaved.'
                          : 'Saved and uploaded.'
                    : 'Saved locally; not uploaded.'
              : 'Saved locally.',
        );
      }
    } catch (error) {
      if (mounted) showTopToastIn(context, message: error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Replace the local checkout (and this document) with the current server
  /// copy. Confirms first when local edits — unsaved buffer text or a dirty
  /// managed copy — would be lost.
  Future<void> _reloadFromServer() async {
    final files = widget.remoteFiles;
    if (files == null || _reloading || _saving || _loading) return;
    final localEdits =
        _dirty || (files.localCopies[widget.remotePath]?.dirty ?? false);
    if (localEdits) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard local changes?'),
          content: const Text(
            'Reloading replaces the local copy with the server version. '
            'Unsaved edits will be lost.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard and reload'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() => _reloading = true);
    try {
      await files.refreshLocalCopy(
        widget.remotePath,
        maximumBytes: builtInEditorMaximumBytes,
      );
      if (!mounted) return;
      await _load();
    } catch (error) {
      if (mounted) showTopToastIn(context, message: error.toString());
    } finally {
      if (mounted) setState(() => _reloading = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme.of registers the dependency, so brightness flips land here.
    _text.theme = EditorSyntaxTheme.of(Theme.of(context).brightness);
  }

  @override
  Widget build(BuildContext context) {
    final name = remoteBasename(widget.remotePath);
    final uploadOnSave = widget.onUpload != null;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !await _confirmDiscard() || !context.mounted) return;
        Navigator.of(context).pop();
      },
      child: CallbackShortcuts(
        bindings: {
          // ⌘S/Ctrl+S is "save and upload" for a server file; hold Shift to
          // deliberately keep a save local-only.
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
              _save(upload: uploadOnSave),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
              _save(upload: uploadOnSave),
          const SingleActivator(
            LogicalKeyboardKey.keyS,
            meta: true,
            shift: true,
          ): _save,
          const SingleActivator(
            LogicalKeyboardKey.keyS,
            control: true,
            shift: true,
          ): _save,
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              _openSearch,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _openSearch,
          const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
              _nextMatch,
          const SingleActivator(LogicalKeyboardKey.keyG, control: true):
              _nextMatch,
          const SingleActivator(LogicalKeyboardKey.keyG, meta: true, shift: true):
              _previousMatch,
          const SingleActivator(
            LogicalKeyboardKey.keyG,
            control: true,
            shift: true,
          ): _previousMatch,
          const SingleActivator(LogicalKeyboardKey.f3): _nextMatch,
          const SingleActivator(LogicalKeyboardKey.f3, shift: true):
              _previousMatch,
          if (_searchOpen)
            const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
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
                tooltip: 'Find',
                onPressed: _loading || _error != null ? null : _openSearch,
                icon: const Icon(Icons.search),
              ),
              IconButton(
                tooltip: 'Save locally',
                onPressed: _dirty && !_saving ? _save : null,
                icon: const Icon(Icons.save_outlined),
              ),
              if (uploadOnSave)
                IconButton(
                  tooltip: 'Save and upload',
                  onPressed: !_saving ? () => _save(upload: true) : null,
                  icon: const Icon(Icons.cloud_upload_outlined),
                ),
            ],
            bottom: _searchOpen
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(52),
                    child: _searchBar(context),
                  )
                : null,
          ),
          body: Column(
            children: [
              if (widget.remoteFiles != null)
                ListenableBuilder(
                  listenable: widget.remoteFiles!,
                  builder: (context, _) {
                    if (_remoteChanged != true) {
                      return const SizedBox.shrink();
                    }
                    return MaterialBanner(
                      leading: const Icon(Icons.sync_problem_outlined),
                      content: Text(
                        _remoteMissing
                            ? 'This file no longer exists on the server.'
                            : 'This file changed on the server.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: _reloading ? null : _reloadFromServer,
                          child: const Text('Reload'),
                        ),
                      ],
                    );
                  },
                ),
              Expanded(child: _body()),
            ],
          ),
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

  Widget _searchBar(BuildContext context) {
    final theme = Theme.of(context);
    final counter = _search.text.isEmpty
        ? ''
        : _matches.isEmpty
        ? 'No matches'
        : '${_activeMatch + 1}/${_matches.length}'
              '${_matches.length >= searchMatchLimit ? '+' : ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              style: theme.textTheme.bodyMedium,
              decoration: const InputDecoration(
                hintText: 'Find in file',
                isDense: true,
                border: InputBorder.none,
              ),
              onSubmitted: (_) {
                if (HardwareKeyboard.instance.isShiftPressed) {
                  _previousMatch();
                } else {
                  _nextMatch();
                }
                _searchFocus.requestFocus();
              },
            ),
          ),
          // Keep focus in the query field: the buttons act without taking it.
          ExcludeFocus(
            child: Row(
              children: [
                if (counter.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(counter, style: theme.textTheme.labelSmall),
                  ),
                IconButton(
                  tooltip: 'Match case',
                  visualDensity: VisualDensity.compact,
                  onPressed: _toggleCaseSensitive,
                  icon: Text(
                    'Aa',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _searchCaseSensitive
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Previous match',
                  visualDensity: VisualDensity.compact,
                  onPressed: _matches.isEmpty ? null : _previousMatch,
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: 'Next match',
                  visualDensity: VisualDensity.compact,
                  onPressed: _matches.isEmpty ? null : _nextMatch,
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
                IconButton(
                  tooltip: 'Close search',
                  visualDensity: VisualDensity.compact,
                  onPressed: _closeSearch,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ],
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
    return LayoutBuilder(
      builder: (context, constraints) {
        _editorWidth = constraints.maxWidth;
        return TextField(
          controller: _text,
          focusNode: _editorFocus,
          scrollController: _scroll,
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
          style: _editorTextStyle,
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.all(_editorPadding),
          ),
        );
      },
    );
  }
}
