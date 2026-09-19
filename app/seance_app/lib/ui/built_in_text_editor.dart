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

/// Offsets at which logical lines begin: 0 plus the position after each
/// `\n`. A trailing newline therefore still counts its empty final line.
List<int> lineStartOffsets(String text) {
  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0a) starts.add(i + 1);
  }
  return starts;
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
  bool _missingBannerDismissed = false;
  List<TextRange> _matches = const [];
  int _activeMatch = -1;
  String _lastSearchedText = '';
  String? _lastQuery;
  double? _editorWidth;

  /// Cache for [lineStartOffsets] — recomputed only when the text instance
  /// changes.
  String? _lineStartsFor;
  List<int> _lineStarts = const [0];

  /// Cache for the gutter's per-line visual offsets — keyed on the text
  /// instance plus the layout inputs (text width, scaler). Language, theme
  /// and search matches also feed `buildTextSpan`, but only through
  /// color/background styles that never change metrics; a span input that
  /// ever affects layout must invalidate this cache too.
  List<double> _gutterTops = const [0];
  String? _gutterLayoutText;
  double? _gutterLayoutWidth;
  TextScaler? _gutterLayoutScaler;

  /// Repaint signal for the gutter. A ScrollController does not notify on
  /// offset changes — only attach/detach — so the field's scroll
  /// notifications bump this instead of rebuilding the row.
  final ValueNotifier<int> _gutterRepaint = ValueNotifier(0);

  /// Inset around the document text; also part of the scroll-to-match math.
  static const double _editorPadding = 14;

  /// Horizontal insets inside the line-number gutter.
  static const double _gutterLeftInset = 8;
  static const double _gutterRightInset = 8;

  /// Matches the terminal's monospace stack; a bare 'monospace' family does
  /// not resolve on every platform (notably macOS/iOS).
  static final TextStyle _editorTextStyle = TextStyle(
    fontFamily: SeanceTheme.monoFallback.first,
    fontFamilyFallback: SeanceTheme.monoFallback,
    fontSize: 14,
    height: 1.35,
  );

  bool get _dirty => !_loading && _text.text != _savedText;

  /// [lineStartOffsets] for the current buffer — identity-keyed so a
  /// rebuild after only a caret move never rescans.
  List<int> get _starts {
    final text = _text.text;
    if (!identical(_lineStartsFor, text)) {
      _lineStarts = lineStartOffsets(text);
      _lineStartsFor = text;
    }
    return _lineStarts;
  }

  /// 1-based line and column of the caret, for the status bar and the
  /// gutter's current-line highlight.
  (int, int) _caretLineCol() {
    final selection = _text.selection;
    if (!selection.isValid) return (1, 1);
    // extentOffset is the moving caret — during a drag/shift selection the
    // anchor (baseOffset) stays pinned where the selection started.
    final offset = selection.extentOffset.clamp(0, _text.text.length);
    final starts = _starts;
    var lo = 0;
    var hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return (lo + 1, offset - starts[lo] + 1);
  }

  /// Visual top offset of every logical line, for the gutter. Precise layout
  /// below [syntaxHighlightingMaxChars] — the same span and width the field
  /// renders, so soft wraps land each number on the right row. Past the cap
  /// the fixed-height estimate mirrors `_revealActiveMatch`: a wrapped line
  /// in a huge file can leave numbers off by a row, never the whole gutter.
  void _ensureGutterLayout(double textWidth, TextScaler scaler) {
    if (identical(_gutterLayoutText, _text.text) &&
        _gutterLayoutWidth == textWidth &&
        _gutterLayoutScaler == scaler) {
      return;
    }
    final text = _text.text;
    final starts = _starts;
    final lineHeight =
        scaler.scale(_editorTextStyle.fontSize!) * _editorTextStyle.height!;
    if (text.length <= syntaxHighlightingMaxChars) {
      final painter = TextPainter(
        text: _text.buildTextSpan(
          context: context,
          style: _editorTextStyle,
          withComposing: false,
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: textWidth > 1 ? textWidth : 1);
      _gutterTops = [
        for (final start in starts)
          painter.getOffsetForCaret(TextPosition(offset: start), Rect.zero).dy,
      ];
      painter.dispose();
    } else {
      _gutterTops = [for (var i = 0; i < starts.length; i++) i * lineHeight];
    }
    _gutterLayoutText = text;
    _gutterLayoutWidth = textWidth;
    _gutterLayoutScaler = scaler;
  }

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
    _gutterRepaint.dispose();
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
                    if (!_remoteMissing) _missingBannerDismissed = false;
                    if (_remoteChanged != true || _missingBannerDismissed) {
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
                        if (_remoteMissing)
                          // Reload cannot succeed against a deleted remote;
                          // the honest action is keeping the surviving copy.
                          TextButton(
                            onPressed: () => setState(
                              () => _missingBannerDismissed = true,
                            ),
                            child: const Text('Keep local copy'),
                          )
                        else
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
                  // The copy's dirty flag and the drift answer live on the
                  // controller; the banner listens to it the same way.
                  child: widget.remoteFiles == null
                      ? _statusBar(context)
                      : ListenableBuilder(
                          listenable: widget.remoteFiles!,
                          builder: (context, _) => _statusBar(context),
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

  /// Caret position and size on the left; document state on the right.
  /// "Local changes" is the managed-copy answer — the on-disk checkout
  /// differs from its last-uploaded baseline — while "Unsaved edits" is the
  /// buffer, so both can appear together.
  Widget _statusBar(BuildContext context) {
    final theme = Theme.of(context);
    final (line, col) = _caretLineCol();
    final copy = widget.remoteFiles?.localCopies[widget.remotePath];
    final status = [
      if (_saving) 'Saving…',
      if (_remoteMissing)
        'Deleted on server'
      else if (_remoteChanged == true)
        'Changed on server',
      if (_dirty)
        'Unsaved edits'
      else if (copy?.dirty ?? false)
        'Local changes'
      else if (copy != null)
        'In sync',
      _lineEnding == '\r\n' ? 'CRLF' : 'LF',
      _hasUtf8Bom ? 'UTF-8 BOM' : 'UTF-8',
      if (_text.language case final language?) language.id,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Ln $line, Col $col · ${_starts.length} lines · '
              '${utf8.encode(_text.text).length} bytes',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
          Flexible(
            child: Text(
              status.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
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
        final scaler = MediaQuery.textScalerOf(context);
        final gutterWidth = _gutterWidth(scaler);
        // The field's text wraps at its width minus the content padding;
        // the gutter lays out at exactly that width so numbers track wraps.
        final textWidth =
            constraints.maxWidth - gutterWidth - 2 * _editorPadding;
        _ensureGutterLayout(textWidth, scaler);
        _editorWidth = constraints.maxWidth - gutterWidth;
        final theme = Theme.of(context);
        return NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _gutterRepaint.value++;
            return false;
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                key: const ValueKey('editor-line-gutter'),
                width: gutterWidth,
                child: CustomPaint(
                  painter: _LineNumberGutterPainter(
                    scroll: _scroll,
                    repaint: _gutterRepaint,
                    lineTops: _gutterTops,
                    topInset: _editorPadding,
                    caretLine: _caretLineCol().$1,
                    textStyle: _editorTextStyle,
                    numberColor: theme.colorScheme.onSurfaceVariant,
                    caretLineColor: theme.colorScheme.onSurface,
                    dividerColor: theme.dividerColor,
                    textScaler: scaler,
                    rightInset: _gutterRightInset,
                  ),
                ),
              ),
              Expanded(
                child: TextField(
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
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Width of the line-number gutter: the widest number plus side padding
  /// and the hairline divider.
  double _gutterWidth(TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(
        text: '0' * _starts.length.toString().length,
        style: _editorTextStyle,
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return _gutterLeftInset + width + _gutterRightInset + 1;
  }
}

/// Paints right-aligned line numbers at each logical line's visual top,
/// tracking the editor's scroll offset. Only lines intersecting the
/// viewport are laid out, and scroll notifications repaint through
/// [CustomPainter.repaint] without a widget rebuild.
class _LineNumberGutterPainter extends CustomPainter {
  /// Read for the live offset at paint time; its notifications do not
  /// reach this painter — [repaint] (bumped by scroll notifications)
  /// drives repaints instead.
  final ScrollController scroll;
  final List<double> lineTops;
  final double topInset;

  /// 1-based logical line holding the caret, drawn brighter.
  final int caretLine;
  final TextStyle textStyle;
  final Color numberColor;
  final Color caretLineColor;
  final Color dividerColor;
  final TextScaler textScaler;
  final double rightInset;

  _LineNumberGutterPainter({
    required this.scroll,
    required Listenable repaint,
    required this.lineTops,
    required this.topInset,
    required this.caretLine,
    required this.textStyle,
    required this.numberColor,
    required this.caretLineColor,
    required this.dividerColor,
    required this.textScaler,
    required this.rightInset,
  })  : assert(
          textStyle.fontSize != null,
          '_LineNumberGutterPainter needs a TextStyle with an explicit '
          'fontSize.',
        ),
        super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    final lineHeight =
        textScaler.scale(textStyle.fontSize!) * (textStyle.height ?? 1);
    canvas.clipRect(Offset.zero & size);
    // Skip ahead to the first line whose box bottom is still on screen.
    final threshold = offset - topInset - lineHeight;
    var lo = 0;
    var hi = lineTops.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (lineTops[mid] > threshold) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    // Insurance against line-height estimate error: painting extra
    // off-screen lines is clipped, skipping a visible one isn't. Past the
    // highlighting cap the estimate lags by one row per soft wrap above the
    // viewport, so the backoff is sized in viewport rows, not one line.
    lo -= (size.height / lineHeight).ceil();
    if (lo < 0) lo = 0;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    );
    for (var i = lo; i < lineTops.length; i++) {
      final y = topInset + lineTops[i] - offset;
      if (y > size.height) break;
      painter.text = TextSpan(
        text: '${i + 1}',
        style: textStyle.copyWith(
          color: i + 1 == caretLine ? caretLineColor : numberColor,
        ),
      );
      painter.layout();
      painter.paint(
        canvas,
        Offset(size.width - 1 - rightInset - painter.width, y),
      );
    }
    painter.dispose();
    canvas.drawRect(
      Rect.fromLTWH(size.width - 1, 0, 1, size.height),
      Paint()..color = dividerColor,
    );
  }

  @override
  bool shouldRepaint(_LineNumberGutterPainter old) =>
      !identical(lineTops, old.lineTops) ||
      caretLine != old.caretLine ||
      topInset != old.topInset ||
      textStyle != old.textStyle ||
      numberColor != old.numberColor ||
      caretLineColor != old.caretLineColor ||
      dividerColor != old.dividerColor ||
      textScaler != old.textScaler ||
      rightInset != old.rightInset;
}
