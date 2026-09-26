import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/terminal_search.dart';
import 'package:xterm/xterm.dart';

Terminal _terminal({int width = 40, int height = 5, int maxLines = 1000}) =>
    Terminal(maxLines: maxLines)..resize(width, height);

List<TerminalSearchHit> _find(
  Terminal terminal,
  String query, {
  bool caseSensitive = false,
  int limit = terminalSearchHitLimit,
}) => searchTerminalBuffer(
  terminal.buffer,
  query,
  caseSensitive: caseSensitive,
  limit: limit,
).hits;

TerminalSearchHit _hit(int x1, int y1, int x2, int y2) =>
    TerminalSearchHit(CellOffset(x1, y1), CellOffset(x2, y2));

class _FakeViewport implements TerminalSearchViewport {
  @override
  ({int first, int last})? visibleRows;
  final List<int> centered = [];

  @override
  void centerRow(int row) => centered.add(row);
}

void main() {
  group('searchTerminalBuffer', () {
    test('ignores case unless asked not to', () {
      final terminal = _terminal()..write('Error error ERROR');
      expect(_find(terminal, 'error'), [
        _hit(0, 0, 5, 0),
        _hit(6, 0, 11, 0),
        _hit(12, 0, 17, 0),
      ]);
      expect(_find(terminal, 'error', caseSensitive: true), [
        _hit(6, 0, 11, 0),
      ]);
      expect(_find(terminal, 'ERROR'), hasLength(3));
    });

    test('finds a match across a soft wrap, never across a newline', () {
      final terminal = _terminal(width: 10)
        ..write('xxxxxxxhello\r\n')
        ..write('xxxxxxxhel\r\nlo');
      // Row 0 wraps into row 1; row 2 ends with a hard newline.
      expect(_find(terminal, 'hello'), [_hit(7, 0, 2, 1)]);
    });

    test('maps wide characters to both of their cells', () {
      final terminal = _terminal()..write('ab日本cd');
      // a b 日日 本本 c d
      expect(_find(terminal, '本c'), [_hit(4, 0, 7, 0)]);
      expect(_find(terminal, '日本'), [_hit(2, 0, 6, 0)]);
    });

    test('joins a wide character whose filler wrapped to the next row', () {
      final terminal = _terminal(width: 5)..write('abcd日x');
      // 日 sits in the last column; its filler starts row 1.
      expect(_find(terminal, 'd日x'), [_hit(3, 0, 2, 1)]);
    });

    test('reads an unwritten gap as spaces, as it looks on screen', () {
      final terminal = _terminal()..write('a\x1b[3Cb');
      expect(_find(terminal, 'a   b'), [_hit(0, 0, 5, 0)]);
    });

    test('folds non-ASCII case and surrogate pairs', () {
      final terminal = _terminal()..write('ÄRGER 🙂ok');
      expect(_find(terminal, 'ärger'), [_hit(0, 0, 5, 0)]);
      expect(_find(terminal, '🙂o'), [_hit(6, 0, 9, 0)]);
    });

    test('keeps the newest hits at the cap and says there are more', () {
      final terminal = _terminal();
      for (var i = 0; i < 30; i++) {
        terminal.write('hit $i\r\n');
      }
      final result = searchTerminalBuffer(terminal.buffer, 'hit', limit: 10);
      expect(result.capped, isTrue);
      expect(result.hits, hasLength(10));
      final rows = [for (final hit in result.hits) hit.start.y];
      final lastRow = terminal.buffer.lines.length - 1;
      // 30 lines written; the cursor sits on an empty last row.
      expect(rows, [for (var i = 20; i < 30; i++) lastRow - 30 + i]);
      expect(
        searchTerminalBuffer(terminal.buffer, 'hit', limit: 30).capped,
        isFalse,
      );
    });

    test('a paused scan drops hits whose lines were trimmed meanwhile', () {
      final terminal = _terminal(height: 5, maxLines: 30);
      for (var i = 0; i < 30; i++) {
        terminal.write('line $i\r\n');
      }
      var lines = 0;
      final scan = TerminalBufferScan(terminal.buffer, 'line');
      // Scan the bottom 10 rows, then pause.
      scan.run(shouldPause: () => ++lines >= 10);
      expect(scan.isDone, isFalse);
      for (var i = 0; i < 3; i++) {
        terminal.write('more\r\n'); // Each trims the oldest row.
      }
      scan.run();
      expect(scan.isDone, isTrue);
      final texts = [
        for (final hit in scan.result.hits)
          terminal.buffer.lines[hit.start.y].getText().trim(),
      ];
      // Line 0 was trimmed before the scan and lines 1 to 3 during it;
      // every hit still lands on its own text.
      expect(texts, [for (var i = 4; i < 30; i++) 'line $i']);
    });
  });

  group('TerminalSearchSession', () {
    late Terminal terminal;
    late TerminalController controller;
    late _FakeViewport viewport;

    TerminalSearchSession session() {
      final session = TerminalSearchSession(
        terminal: terminal,
        controller: controller,
        viewport: viewport,
        theme: TerminalThemes.defaultTheme,
      );
      addTearDown(session.dispose);
      return session;
    }

    setUp(() {
      terminal = _terminal(height: 5, maxLines: 30);
      controller = TerminalController();
      viewport = _FakeViewport();
      addTearDown(controller.dispose);
      for (var i = 0; i < 20; i++) {
        terminal.write('row $i ${i.isEven ? 'even' : 'odd'}\r\n');
      }
    });

    test('starts at the newest hit in view and steps with wrap-around', () {
      final search = session();
      final last = terminal.buffer.lines.length - 1;
      viewport.visibleRows = (first: last - 4, last: last);
      search.search('even');
      expect(search.hitCount, 10);
      expect(search.currentIndex, 9);
      // Already in view: no scrolling.
      expect(viewport.centered, isEmpty);

      search.next();
      expect(search.currentIndex, 0);
      expect(viewport.centered, [search.hits.first.start.y]);
      search.previous();
      expect(search.currentIndex, 9);
      expect(controller.highlights, hasLength(10));
      final current = controller.highlights.where(
        (h) =>
            h.color == TerminalThemes.defaultTheme.searchHitBackgroundCurrent,
      );
      expect(current, hasLength(1));
      expect(current.single.p1.offset, search.hits.last.start);
      expect(
        current.single.foreground,
        TerminalThemes.defaultTheme.searchHitForeground,
      );
    });

    test('highlights are not a selection', () {
      session().search('odd');
      expect(controller.highlights, isNotEmpty);
      expect(controller.selection, isNull);
    });

    test('clearing the query removes every highlight', () {
      final search = session();
      search.search('row');
      expect(controller.highlights, hasLength(20));
      search.search('');
      expect(controller.highlights, isEmpty);
      expect(search.currentIndex, isNull);
    });

    test('disposing removes every highlight', () {
      final search = TerminalSearchSession(
        terminal: terminal,
        controller: controller,
        viewport: viewport,
        theme: TerminalThemes.defaultTheme,
      )..search('row');
      expect(controller.highlights, isNotEmpty);
      search.dispose();
      expect(controller.highlights, isEmpty);
    });

    testWidgets('output refreshes the hits and keeps the current one', (
      tester,
    ) async {
      final search = session();
      search.search('even');
      search.previous();
      search.previous();
      final current = search.hits[search.currentIndex!];
      final text = terminal.buffer.lines[current.start.y].getText().trim();

      for (var i = 20; i < 32; i++) {
        terminal.write('row $i ${i.isEven ? 'even' : 'odd'}\r\n');
      }
      // Throttled, not per write.
      expect(search.hitCount, 10);
      await tester.pump(const Duration(milliseconds: 200));

      // The full buffer trimmed rows 0 to 2 (two hits); six new ones.
      expect(search.hitCount, 14);
      final now = search.hits[search.currentIndex!];
      expect(terminal.buffer.lines[now.start.y].getText().trim(), text);
    });

    test('a hit on a trimmed line detaches and is stepped over', () {
      final search = session();
      search.search('row 0 ');
      expect(search.hitCount, 1);
      for (var i = 0; i < 20; i++) {
        terminal.write('filler\r\n');
      }
      expect(search.hits, isEmpty);
      search.next();
      expect(search.hitCount, 0);
      expect(search.currentIndex, isNull);
    });

    test('case sensitivity re-runs the search', () {
      terminal.write('EVEN\r\n');
      final search = session();
      search.search('EVEN');
      expect(search.hitCount, 11);
      search.caseSensitive = true;
      expect(search.hitCount, 1);
    });
  });

  // Not a pass/fail gate: prints what one slice and a whole scan cost on a
  // full 10k-line scrollback, for the numbers in the change notes.
  test('bounded slices on a 10k-line scrollback', () {
    for (final width in [80, 200]) {
      final terminal = _terminal(width: width, height: 50, maxLines: 10000);
      final line = List.filled(width ~/ 8, 'deploy  ').join();
      for (var i = 0; i < 10100; i++) {
        terminal.write('$line\r\n');
      }
      final whole = Stopwatch()..start();
      searchTerminalBuffer(terminal.buffer, 'no such text');
      whole.stop();
      final scan = TerminalBufferScan(terminal.buffer, 'no such text');
      var slices = 0;
      var longest = Duration.zero;
      while (!scan.isDone) {
        final clock = Stopwatch()..start();
        scan.run(
          shouldPause: () => clock.elapsed >= const Duration(milliseconds: 4),
        );
        if (clock.elapsed > longest) longest = clock.elapsed;
        slices++;
      }
      // ignore: avoid_print
      print(
        '$width cols: whole scan ${whole.elapsedMilliseconds} ms, '
        '$slices slices, longest ${longest.inMicroseconds / 1000} ms',
      );
      expect(longest, lessThan(const Duration(milliseconds: 20)));
    }
  });
}
