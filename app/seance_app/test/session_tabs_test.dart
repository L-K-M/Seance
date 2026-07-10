import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_core/seance_core.dart';

/// Unit tests for the per-server tab bookkeeping — the adjacency invariant and
/// the close-fallback chain, where off-by-one bugs would hide. These are pure
/// functions over a session list, so no SSH/services are needed.
void main() {
  ServerConfig cfg(String id) => ServerConfig(
    id: id,
    label: id,
    host: 'h',
    port: 22,
    username: 'u',
    authMethod: AuthMethod.password,
    createdAt: 0,
    updatedAt: 0,
  );

  final engines = <XtermTerminalEngine>[];
  TerminalSession session(String id, String serverId) {
    final engine = XtermTerminalEngine();
    engines.add(engine);
    return TerminalSession(
      id: id,
      serverId: serverId,
      config: cfg(serverId),
      engine: engine,
      log: SshConnectionLog(),
    );
  }

  tearDown(() async {
    for (final e in engines) {
      await e.dispose();
    }
    engines.clear();
  });

  group('insertIndexFor', () {
    test('appends to the end when the server has no sessions', () {
      final list = [session('a1', 'A'), session('a2', 'A')];
      expect(AppState.insertIndexFor(list, 'B'), 2);
    });

    test('inserts right after the server\'s last existing session', () {
      final list = [
        session('a1', 'A'),
        session('b1', 'B'),
        session('a2', 'A'),
        session('c1', 'C'),
      ];
      // A's last session is at index 2 → insert at 3, keeping A contiguous
      // once the caller also moves nothing else (A already contiguous here
      // only if inserted adjacent; the invariant is maintained by always
      // inserting via this index from an already-contiguous list).
      expect(AppState.insertIndexFor(list, 'A'), 3);
      expect(AppState.insertIndexFor(list, 'B'), 2);
      expect(AppState.insertIndexFor(list, 'C'), 4);
    });

    test('keeps a server contiguous across repeated inserts', () {
      final list = <TerminalSession>[];
      // Simulate newTab: A, B, then a second A — the second A must land
      // adjacent to the first, not at the end.
      list.insert(AppState.insertIndexFor(list, 'A'), session('a1', 'A'));
      list.insert(AppState.insertIndexFor(list, 'B'), session('b1', 'B'));
      list.insert(AppState.insertIndexFor(list, 'A'), session('a2', 'A'));
      expect(list.map((s) => s.id).toList(), ['a1', 'a2', 'b1']);
      expect(AppState.sessionsForServerIn(list, 'A').map((s) => s.id), [
        'a1',
        'a2',
      ]);
    });
  });

  group('fallbackAfterClosing', () {
    test('picks the next same-server tab', () {
      final a1 = session('a1', 'A');
      final a2 = session('a2', 'A');
      final a3 = session('a3', 'A');
      final siblingsBefore = [a1, a2, a3];
      final remaining = [a1, a3]; // closed a2
      final pick = AppState.fallbackAfterClosing(
        closed: a2,
        siblingsBefore: siblingsBefore,
        remaining: remaining,
        lastSessionForServer: const {},
      );
      expect(pick?.id, 'a3'); // successor at the closed position
    });

    test('picks the previous tab when the last same-server tab is closed', () {
      final a1 = session('a1', 'A');
      final a2 = session('a2', 'A');
      final pick = AppState.fallbackAfterClosing(
        closed: a2,
        siblingsBefore: [a1, a2],
        remaining: [a1], // closed a2 (the last)
        lastSessionForServer: const {},
      );
      expect(pick?.id, 'a1');
    });

    test('falls back to another server\'s most-recent tab', () {
      final a1 = session('a1', 'A');
      final b1 = session('b1', 'B');
      final pick = AppState.fallbackAfterClosing(
        closed: a1,
        siblingsBefore: [a1],
        remaining: [b1], // A has no tabs left
        lastSessionForServer: {'B': 'b1'},
      );
      expect(pick?.id, 'b1');
    });

    test('falls back to the last remaining session with no MRU hint', () {
      final a1 = session('a1', 'A');
      final b1 = session('b1', 'B');
      final pick = AppState.fallbackAfterClosing(
        closed: a1,
        siblingsBefore: [a1],
        remaining: [b1],
        lastSessionForServer: const {}, // no hint
      );
      expect(pick?.id, 'b1');
    });

    test('returns null when nothing is left', () {
      final a1 = session('a1', 'A');
      final pick = AppState.fallbackAfterClosing(
        closed: a1,
        siblingsBefore: [a1],
        remaining: const [],
        lastSessionForServer: const {},
      );
      expect(pick, isNull);
    });
  });
}
