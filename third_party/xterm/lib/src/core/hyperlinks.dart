import 'package:xterm/src/core/cell.dart';

/// [seance fork] The id stored in cells that carry no OSC 8 hyperlink.
const noHyperlink = 0;

/// [seance fork] The largest hyperlink id that fits beside the style flags in
/// a cell's attribute word.
const maxHyperlinkId = CellAttr.hyperlinkMask >> CellAttr.hyperlinkShift;

/// [seance fork] Longer targets are refused, the same ceiling VTE and iTerm2
/// apply (the de-facto ~2000 byte limit on URLs). Remote output is untrusted:
/// without a bound, one escape sequence could park an arbitrary string here.
const maxHyperlinkTargetLength = 2083;

/// [seance fork] How many distinct targets stay resolvable. Only web URIs are
/// stored (a `file://` listing from `ls --hyperlink` never enters), so this
/// covers far more links than a scrollback realistically holds.
const _defaultHyperlinkCapacity = 1024;

/// [seance fork] Parses a URI that Séance is willing to hand to the host
/// browser. Terminal output is untrusted, so anything that is not plain web
/// navigation is refused: other schemes can reach local files and application
/// handlers, and embedded credentials would be leaked to the browser (and hide
/// the real host behind a `user@` prefix).
Uri? parseWebUri(String text) {
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  return uri;
}

/// [seance fork] The targets of the OSC 8 hyperlinks written to a terminal,
/// keyed by the id its cells carry.
///
/// A hyperlink belongs to cells rather than to their text — `OSC 8 ; params ;
/// URI ST` opens one, every cell written until `OSC 8 ; ; ST` carries it — so
/// the target has to live somewhere other than the buffer: the visible text is
/// often not the URL at all, and a program that wraps its own output breaks
/// even a printed URL across hard newlines that no text scan may rejoin.
///
/// Cells store an id into this table instead of the URI, because one link can
/// cover hundreds of cells and the buffer keeps thousands of lines of them.
/// The table is bounded: past [capacity] targets the least recently opened one
/// is dropped, and an id is never handed to a second target, so a cell whose
/// entry is gone resolves to nothing instead of to somebody else's URL. Once
/// every id has been spent the table stops registering new targets rather than
/// reuse one.
class Hyperlinks {
  Hyperlinks({
    this.capacity = _defaultHyperlinkCapacity,
    this.greatestId = maxHyperlinkId,
  })  : assert(capacity > 0),
        assert(greatestId > noHyperlink && greatestId <= maxHyperlinkId);

  /// The number of targets kept resolvable at once.
  final int capacity;

  /// The last id this table will ever hand out. See [maxHyperlinkId];
  /// injectable so tests can reach exhaustion without 16M targets.
  final int greatestId;

  /// Insertion-ordered, so the first key is the least recently opened target.
  final _targets = <int, Uri>{};

  /// Reverse index, so a target printed repeatedly keeps one id.
  final _ids = <Uri, int>{};

  var _lastId = noHyperlink;

  /// Registers [target] and returns the id to write into cells, or
  /// [noHyperlink] when the target is not one this terminal will open.
  int open(String target) {
    if (target.length > maxHyperlinkTargetLength) return noHyperlink;

    final uri = parseWebUri(target);
    if (uri == null) return noHyperlink;

    final known = _ids[uri];
    if (known != null) {
      // Re-insert to refresh recency: a target that keeps being printed must
      // not age out from under the cells that still point at it.
      _targets.remove(known);
      _targets[known] = uri;
      return known;
    }

    if (_lastId >= greatestId) {
      // The id space is exhausted, and starting over is not an option: an
      // open costs no printed text, so a remote can spend every id without
      // ever scrolling the cells that hold them, and a reused id would then
      // send one of those cells to whatever registers next. Further targets
      // stay unlinked, which is the state a refused one already leaves, and
      // the targets already registered keep resolving.
      return noHyperlink;
    }

    final id = ++_lastId;
    _targets[id] = uri;
    _ids[uri] = id;

    if (_targets.length > capacity) {
      final oldest = _targets.keys.first;
      _ids.remove(_targets.remove(oldest));
    }

    return id;
  }

  /// The target of [id], or null when there is none — either the cell carries
  /// no hyperlink or its target has aged out of the table.
  Uri? operator [](int id) => _targets[id];

  /// Forgets every target. Ids keep counting up, so cells written before the
  /// call resolve to nothing rather than to whatever is registered next.
  void clear() {
    _targets.clear();
    _ids.clear();
  }
}
