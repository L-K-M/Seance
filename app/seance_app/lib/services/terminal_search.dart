import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:xterm/xterm.dart';

/// Search stops counting here; the find bar shows "1000+" rather than
/// anchoring an unbounded number of highlights for a one-letter query in a
/// full scrollback. The same cap as the editor's find bar.
const int terminalSearchHitLimit = 1000;

/// One match in a terminal buffer: from the cell holding its first character
/// up to, but not including, the cell after its last one — the shape a
/// highlight paints. A match that crosses a soft wrap starts and ends on
/// different rows.
@immutable
class TerminalSearchHit {
  const TerminalSearchHit(this.start, this.end);

  final CellOffset start;
  final CellOffset end;

  @override
  bool operator ==(Object other) =>
      other is TerminalSearchHit && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TerminalSearchHit($start, $end)';
}

@immutable
class TerminalSearchResult {
  const TerminalSearchResult(this.hits, {required this.capped});

  static const empty = TerminalSearchResult([], capped: false);

  /// In buffer order: top to bottom, left to right.
  final List<TerminalSearchHit> hits;

  /// Whether the scan stopped at the limit with buffer left unread.
  final bool capped;
}

/// Plain substring search over one terminal buffer — scrollback and screen —
/// that can pause between logical lines, so a full scrollback is scanned in
/// slices instead of in one frame.
///
/// Rows joined by soft wraps are searched as the one logical line they
/// display, so a match spanning a wrap is found; hard line ends are never
/// crossed. Case-insensitive search folds each character on both sides with
/// the same mapping, so a character whose lowercase form is longer (`İ`)
/// still maps back to the one cell it came from. Matches do not overlap.
///
/// The scan walks up from the bottom. Capped at [limit], the hits it keeps
/// are the newest — the output you are most likely looking for — and a
/// paused scan has already covered the screen. Rows are recorded by their
/// absolute index, so the scrollback trimming between slices shifts
/// nothing; [result] leaves out hits whose lines have since been trimmed.
class TerminalBufferScan {
  TerminalBufferScan(
    this.buffer,
    String query, {
    this.caseSensitive = false,
    this.limit = terminalSearchHitLimit,
  }) : _needle = caseSensitive ? query : _foldString(query),
       _next = buffer.lines.absoluteStartIndex + buffer.lines.length - 1;

  final Buffer buffer;
  final bool caseSensitive;
  final int limit;

  final String _needle;
  final _LogicalLineText _text = _LogicalLineText();
  final List<int> _lineMatches = [];

  /// Absolute index of the bottom row of the next logical line to scan.
  int _next;
  bool _done = false;
  bool _capped = false;

  /// Hits newest first, four absolute coordinates each: start row, start
  /// column, end row, end column.
  final List<int> _found = [];

  bool get isDone => _done;

  int get _hitCount => _found.length ~/ 4;

  /// Scans until the buffer is covered, the limit is reached, or
  /// [shouldPause] — asked after each logical line — returns true.
  void run({bool Function()? shouldPause}) {
    if (_done) return;
    if (_needle.isEmpty || limit <= 0) {
      _done = true;
      return;
    }
    final lines = buffer.lines;
    final base = lines.absoluteStartIndex;
    var row = math.min(_next - base, lines.length - 1);
    while (row >= 0) {
      var head = row;
      // Row 0 can be a continuation whose head was trimmed away; it still
      // starts the first logical line the buffer holds.
      while (head > 0 && lines[head].isWrapped) {
        head--;
      }
      _scanLine(head, row, base);
      row = head - 1;
      _next = base + row;
      if (_hitCount == limit) {
        _capped = _capped || row >= 0;
        break;
      }
      if (row >= 0 && (shouldPause?.call() ?? false)) return;
    }
    _done = true;
  }

  /// What the scan has found so far, in the buffer's current coordinates.
  TerminalSearchResult get result {
    final base = buffer.lines.absoluteStartIndex;
    final hits = <TerminalSearchHit>[];
    for (var i = _found.length - 4; i >= 0; i -= 4) {
      final startRow = _found[i] - base;
      if (startRow < 0) continue;
      hits.add(
        TerminalSearchHit(
          CellOffset(_found[i + 1], startRow),
          CellOffset(_found[i + 3], _found[i + 2] - base),
        ),
      );
    }
    return TerminalSearchResult(hits, capped: _capped);
  }

  void _scanLine(int first, int last, int base) {
    // Most lines hold no match: collect just the text, and map characters
    // back to cells only for a line that does.
    _text.build(buffer, first, last, caseSensitive: caseSensitive);
    final at = _text.string.indexOf(_needle);
    if (at < 0) return;
    _text.build(buffer, first, last, caseSensitive: caseSensitive, cells: true);
    final haystack = _text.string;
    _lineMatches.clear();
    for (var from = at; from >= 0;) {
      _lineMatches.add(from);
      from = haystack.indexOf(_needle, from + _needle.length);
    }
    // Right to left, continuing the scan's bottom-up order.
    for (var i = _lineMatches.length - 1; i >= 0; i--) {
      if (_hitCount == limit) {
        _capped = true;
        return;
      }
      _text.addHit(_found, _lineMatches[i], _needle.length, base);
    }
  }
}

/// [TerminalBufferScan] run to the end in one go.
TerminalSearchResult searchTerminalBuffer(
  Buffer buffer,
  String query, {
  bool caseSensitive = false,
  int limit = terminalSearchHitLimit,
}) {
  final scan = TerminalBufferScan(
    buffer,
    query,
    caseSensitive: caseSensitive,
    limit: limit,
  )..run();
  return scan.result;
}

/// Lowercase fold for one code point, applied identically to the query and
/// the buffer. ASCII — nearly everything a terminal shows — skips the String
/// round trip; the rest are cached, the set of distinct non-ASCII characters
/// in a scrollback being small.
String _foldCodePoint(int codePoint) =>
    _foldCache[codePoint] ??= String.fromCharCode(codePoint).toLowerCase();

final Map<int, String> _foldCache = {};

String _foldString(String value) {
  final folded = StringBuffer();
  for (final rune in value.runes) {
    if (rune < 0x80) {
      folded.writeCharCode(_asciiLower(rune));
    } else {
      folded.write(_foldCodePoint(rune));
    }
  }
  return folded.toString();
}

@pragma('vm:prefer-inline')
int _asciiLower(int c) => c >= 0x41 && c <= 0x5A ? c + 0x20 : c;

/// The text of one logical line and, per UTF-16 code unit, the cell it came
/// from. Reused across lines, so a scan allocates a string per line and
/// nothing per cell.
class _LogicalLineText {
  Uint16List _units = Uint16List(256);
  Int32List _rows = Int32List(256);
  Int32List _cols = Int32List(256);
  Uint8List _widths = Uint8List(256);
  int _length = 0;
  bool _cells = false;

  late String string;

  /// Collects rows [first] to [last], one soft-wrapped run; with [cells],
  /// also where each code unit came from.
  ///
  /// A cell nothing was written to reads as a space when text follows it on
  /// the same row, as it looks on screen; trailing blank cells add nothing,
  /// so a wrapped row's padding never splits a word. The filler cell after a
  /// wide character — on its row, or at the start of the next row when the
  /// character sat in the last column — is skipped: the character already
  /// claims both cells.
  void build(
    Buffer buffer,
    int first,
    int last, {
    required bool caseSensitive,
    bool cells = false,
  }) {
    final lines = buffer.lines;
    _length = 0;
    _cells = cells;
    var previousWide = false;
    for (var row = first; row <= last; row++) {
      final line = lines[row];
      var pendingBlanks = 0;
      for (var col = 0; col < line.length; col++) {
        final content = line.getContent(col);
        final codePoint = content & CellContent.codepointMask;
        if (codePoint == 0) {
          if (!previousWide) pendingBlanks++;
          previousWide = false;
          continue;
        }
        for (var blank = col - pendingBlanks; blank < col; blank++) {
          _add(0x20, row, blank, 1);
        }
        pendingBlanks = 0;
        final width = content >> CellContent.widthShift;
        previousWide = width == 2;
        // A zero-width character still occupies a cell of its own here.
        _addCodePoint(codePoint, row, col, width == 2 ? 2 : 1, caseSensitive);
      }
    }
    string = String.fromCharCodes(_units, 0, _length);
  }

  /// Appends the hit covering code units [at] to [at] + [length] to [out] as
  /// absolute rows (relative row + [base]) and columns.
  void addHit(List<int> out, int at, int length, int base) {
    assert(_cells, 'addHit needs a build with cells');
    final end = at + length - 1;
    out
      ..add(_rows[at] + base)
      ..add(_cols[at])
      ..add(_rows[end] + base)
      ..add(_cols[end] + _widths[end]);
  }

  @pragma('vm:prefer-inline')
  void _addCodePoint(
    int codePoint,
    int row,
    int col,
    int width,
    bool caseSensitive,
  ) {
    if (codePoint < 0x80) {
      _add(caseSensitive ? codePoint : _asciiLower(codePoint), row, col, width);
      return;
    }
    if (!caseSensitive) {
      final folded = _foldCodePoint(codePoint);
      for (var i = 0; i < folded.length; i++) {
        _add(folded.codeUnitAt(i), row, col, width);
      }
      return;
    }
    if (codePoint > 0xFFFF) {
      final offset = codePoint - 0x10000;
      _add(0xD800 + (offset >> 10), row, col, width);
      _add(0xDC00 + (offset & 0x3FF), row, col, width);
      return;
    }
    _add(codePoint, row, col, width);
  }

  @pragma('vm:prefer-inline')
  void _add(int unit, int row, int col, int width) {
    if (_length == _units.length) _grow();
    _units[_length] = unit;
    if (_cells) {
      _rows[_length] = row;
      _cols[_length] = col;
      _widths[_length] = width;
    }
    _length++;
  }

  void _grow() {
    final capacity = _units.length * 2;
    _units = Uint16List(capacity)..setRange(0, _length, _units);
    _rows = Int32List(capacity)..setRange(0, _length, _rows);
    _cols = Int32List(capacity)..setRange(0, _length, _cols);
    _widths = Uint8List(capacity)..setRange(0, _length, _widths);
  }
}

/// What [TerminalSearchSession] needs from the view showing the terminal.
abstract interface class TerminalSearchViewport {
  /// The buffer rows in full view, or null while the view has no size.
  ({int first, int last})? get visibleRows;

  /// Scrolls so [row] sits mid-viewport, as far as the scrollback allows.
  void centerRow(int row);
}

/// How a finished scan picks the current hit.
enum _Pick {
  /// A new query or case setting: the hit nearest where you were looking,
  /// scrolled into view.
  fresh,

  /// A refresh after output: the same hit if it still exists, and the
  /// viewport left alone — you may be reading.
  keep,
}

/// A find-in-scrollback session over one terminal: the query, its hits as
/// highlights on the view's [TerminalController], and which hit is current.
///
/// This is the one place search touches xterm. Hits are anchors in the
/// buffer and highlights on the controller, never selections, so copying is
/// unaffected. Anchors detach when their line is trimmed off the scrollback,
/// which takes their highlight with them. While a query is set, output
/// re-runs the search at most once per [refreshDelay], so a stream of output
/// cannot starve it; each run scans in slices of [sliceBudget].
class TerminalSearchSession extends ChangeNotifier {
  TerminalSearchSession({
    required this._terminal,
    required this._controller,
    required this._viewport,
    required TerminalTheme theme,
    this.refreshDelay = const Duration(milliseconds: 150),
    this.sliceBudget = const Duration(milliseconds: 4),
  }) : _colors = _HitColors.of(theme) {
    _terminal.addListener(_onOutput);
  }

  final Terminal _terminal;
  final TerminalController _controller;
  final TerminalSearchViewport _viewport;
  final Duration refreshDelay;
  final Duration sliceBudget;

  _HitColors _colors;
  String _query = '';
  bool _caseSensitive = false;
  List<_Hit> _hits = [];
  int? _current;
  bool _capped = false;

  TerminalBufferScan? _scan;
  _Pick _scanPick = _Pick.fresh;
  int _scanWidth = 0;
  Timer? _sliceTimer;
  Timer? _refreshTimer;
  bool _outputPending = false;
  bool _disposed = false;

  String get query => _query;
  bool get caseSensitive => _caseSensitive;
  int get hitCount => _hits.length;

  /// Whether more matches exist than [hitCount] (see
  /// [terminalSearchHitLimit]).
  bool get capped => _capped;

  /// The current hit's index in [hits], or null when there are none.
  int? get currentIndex => _current;

  /// Where the hits are now, in buffer order.
  @visibleForTesting
  List<TerminalSearchHit> get hits => [
    for (final hit in _hits)
      if (hit.isLive(_terminal.buffer))
        TerminalSearchHit(hit.start.offset, hit.end.offset),
  ];

  void search(String query) {
    if (query == _query) return;
    _query = query;
    _startScan(_Pick.fresh);
  }

  set caseSensitive(bool value) {
    if (value == _caseSensitive) return;
    _caseSensitive = value;
    _startScan(_Pick.fresh);
  }

  /// Takes the colours of the terminal's current palette. Does not notify:
  /// the counter does not change, and a build may be what calls this.
  set theme(TerminalTheme theme) {
    final colors = _HitColors.of(theme);
    if (colors == _colors) return;
    _colors = colors;
    for (var i = 0; i < _hits.length; i++) {
      _paint(i);
    }
  }

  /// The next hit down, wrapping to the top.
  void next() => _step(1);

  /// The next hit up, wrapping to the bottom.
  void previous() => _step(-1);

  void _step(int delta) {
    _dropDeadHits();
    if (_hits.isEmpty) {
      notifyListeners();
      return;
    }
    final old = _current;
    final count = _hits.length;
    _current = old == null
        ? (delta > 0 ? 0 : count - 1)
        : (old + delta + count) % count;
    if (old != null) _paint(old);
    _paint(_current!);
    notifyListeners();
    _revealCurrent();
  }

  /// Output trims scrollback between refreshes; stepping onto a hit whose
  /// line is gone would go nowhere.
  void _dropDeadHits() {
    final buffer = _terminal.buffer;
    if (_hits.every((hit) => hit.isLive(buffer))) return;
    final current = _current == null ? null : _hits[_current!];
    final live = <_Hit>[];
    for (final hit in _hits) {
      if (hit.isLive(buffer)) {
        live.add(hit);
      } else {
        hit.dispose();
      }
    }
    _hits = live;
    final index = current == null ? -1 : live.indexOf(current);
    _current = index >= 0 ? index : (live.isEmpty ? null : 0);
  }

  void _onOutput() {
    if (_query.isEmpty) return;
    _outputPending = true;
    // A scan in flight reschedules when it finishes.
    if (_scan == null) _scheduleRefresh();
  }

  void _scheduleRefresh() {
    _refreshTimer ??= Timer(refreshDelay, () {
      _refreshTimer = null;
      _startScan(_Pick.keep);
    });
  }

  void _startScan(_Pick pick) {
    _sliceTimer?.cancel();
    _sliceTimer = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _outputPending = false;
    if (_query.isEmpty) {
      _scan = null;
      _apply(TerminalSearchResult.empty, pick);
      return;
    }
    _scan = TerminalBufferScan(
      _terminal.buffer,
      _query,
      caseSensitive: _caseSensitive,
    );
    _scanPick = pick;
    _scanWidth = _terminal.viewWidth;
    _continueScan();
  }

  void _continueScan() {
    _sliceTimer = null;
    final scan = _scan;
    if (scan == null || _disposed) return;
    // A switch to the other buffer (vim) or a reflow (width change) has
    // moved every row the scan recorded: start over on what is showing.
    if (!identical(scan.buffer, _terminal.buffer) ||
        _scanWidth != _terminal.viewWidth) {
      _startScan(_scanPick);
      return;
    }
    final clock = Stopwatch()..start();
    scan.run(shouldPause: () => clock.elapsed >= sliceBudget);
    if (!scan.isDone) {
      _sliceTimer = Timer(Duration.zero, _continueScan);
      return;
    }
    _scan = null;
    _apply(scan.result, _scanPick);
    if (_outputPending) _scheduleRefresh();
  }

  void _apply(TerminalSearchResult result, _Pick pick) {
    final buffer = _terminal.buffer;
    final previous = _current == null ? null : _hits[_current!];
    final previousStart = previous != null && previous.isLive(buffer)
        ? previous.start.offset
        : null;

    // Keep hits that are still where the new result puts them. Under
    // streaming output nearly all are, and keeping them spares
    // re-anchoring and re-highlighting up to a thousand ranges per refresh.
    final existing = <CellOffset, _Hit>{};
    for (final hit in _hits) {
      if (hit.isLive(buffer)) {
        existing[hit.start.offset] = hit;
      } else {
        hit.dispose();
      }
    }
    final hits = <_Hit>[];
    for (final found in result.hits) {
      final kept = existing.remove(found.start);
      if (kept != null && kept.end.offset == found.end) {
        hits.add(kept);
        continue;
      }
      kept?.dispose();
      hits.add(
        _Hit(
          buffer.createAnchorFromOffset(
            found.start,
            onTrim: AnchorTrimBehavior.detach,
          ),
          buffer.createAnchorFromOffset(
            found.end,
            onTrim: AnchorTrimBehavior.detach,
          ),
        ),
      );
    }
    for (final stale in existing.values) {
      stale.dispose();
    }
    _hits = hits;
    _capped = result.capped;
    _current = _pickCurrent(pick, previousStart, hadPrevious: previous != null);
    for (var i = 0; i < _hits.length; i++) {
      _paint(i);
    }
    notifyListeners();
    if (pick == _Pick.fresh) _revealCurrent();
  }

  int? _pickCurrent(
    _Pick pick,
    CellOffset? previousStart, {
    required bool hadPrevious,
  }) {
    if (_hits.isEmpty) return null;
    if (pick == _Pick.keep && hadPrevious) {
      // Its line was trimmed: everything left is below it.
      if (previousStart == null) return 0;
      final index = _hits.indexWhere(
        (hit) => hit.start.offset.isAfterOrSame(previousStart),
      );
      return index < 0 ? _hits.length - 1 : index;
    }
    // Nearest at or above where you were: the old current hit while you
    // refine a query, else the bottom of the viewport — the newest output
    // you can see, then what came before it.
    final origin = previousStart ?? _viewportEnd();
    final index = _hits.lastIndexWhere(
      (hit) => hit.start.offset.isBeforeOrSame(origin),
    );
    return index < 0 ? 0 : index;
  }

  CellOffset _viewportEnd() {
    final rows = _viewport.visibleRows;
    final last = _terminal.buffer.lines.length - 1;
    return CellOffset(
      _terminal.viewWidth,
      rows == null ? last : math.min(rows.last, last),
    );
  }

  void _paint(int index) {
    _hits[index].paint(
      _controller,
      current: index == _current,
      colors: _colors,
    );
  }

  void _revealCurrent() {
    final index = _current;
    if (index == null) return;
    final hit = _hits[index];
    if (!hit.isLive(_terminal.buffer)) return;
    final top = hit.start.y;
    final bottom = hit.end.y;
    final visible = _viewport.visibleRows;
    if (visible != null && top >= visible.first && bottom <= visible.last) {
      return;
    }
    _viewport.centerRow(top);
  }

  @override
  void dispose() {
    _disposed = true;
    _terminal.removeListener(_onOutput);
    _sliceTimer?.cancel();
    _refreshTimer?.cancel();
    for (final hit in _hits) {
      hit.dispose();
    }
    _hits = [];
    super.dispose();
  }
}

@immutable
class _HitColors {
  const _HitColors(this.background, this.current, this.foreground);

  _HitColors.of(TerminalTheme theme)
    : this(
        theme.searchHitBackground,
        theme.searchHitBackgroundCurrent,
        theme.searchHitForeground,
      );

  final Color background;
  final Color current;
  final Color foreground;

  @override
  bool operator ==(Object other) =>
      other is _HitColors &&
      other.background == background &&
      other.current == current &&
      other.foreground == foreground;

  @override
  int get hashCode => Object.hash(background, current, foreground);
}

/// One hit's anchors (owned) and its highlight, repainted only when its
/// role or the palette changes.
class _Hit {
  _Hit(this.start, this.end);

  final CellAnchor start;
  final CellAnchor end;
  TerminalHighlight? _highlight;
  bool _paintedCurrent = false;
  _HitColors? _paintedColors;

  bool isLive(Buffer buffer) =>
      start.attached && end.attached && buffer.ownsAnchor(start);

  void paint(
    TerminalController controller, {
    required bool current,
    required _HitColors colors,
  }) {
    if (_highlight != null &&
        _paintedCurrent == current &&
        _paintedColors == colors) {
      return;
    }
    _highlight?.dispose();
    _paintedCurrent = current;
    _paintedColors = colors;
    _highlight = controller.highlight(
      p1: start,
      p2: end,
      color: current ? colors.current : colors.background,
      foreground: colors.foreground,
    );
  }

  void dispose() {
    _highlight?.dispose();
    _highlight = null;
    start.dispose();
    end.dispose();
  }
}
