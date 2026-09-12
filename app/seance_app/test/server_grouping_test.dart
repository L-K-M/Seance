import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/server_grouping.dart';
import 'package:seance_core/seance_core.dart';

ServerConfig _server(String label, {String? group}) => ServerConfig(
  id: label,
  label: label,
  host: '$label.example.com',
  username: 'ops',
  authMethod: AuthMethod.password,
  group: group,
  createdAt: 0,
  updatedAt: 0,
);

/// Each section as `[name, [member labels]]` — enough to assert membership and
/// both orders at once. Nested lists rather than records because `equals`
/// compares collections structurally and records only field-by-field, where a
/// `List` field falls back to identity.
List<List<Object?>> _shape(List<ServerGroupSection> sections) => [
  for (final section in sections)
    [section.name, [for (final s in section.servers) s.label]],
];

void main() {
  group('groupServers', () {
    test('a list with no groups stays one anonymous section', () {
      final sections = groupServers([_server('a'), _server('b')]);
      expect(sections, hasLength(1));
      expect(sections.single.name, isNull);
      expect(sections.single.servers.map((s) => s.label), ['a', 'b']);
    });

    test('empty in, empty section out', () {
      final sections = groupServers([]);
      expect(sections, hasLength(1));
      expect(sections.single.servers, isEmpty);
    });

    test('sections are sorted by name with the ungrouped remainder last', () {
      final sections = groupServers([
        _server('loose'),
        _server('web', group: 'Production'),
        _server('runner', group: 'CI'),
        _server('also-loose'),
        _server('db', group: 'Production'),
      ]);
      expect(_shape(sections), [
        ['CI', ['runner']],
        ['Production', ['web', 'db']],
        [null, ['loose', 'also-loose']],
      ]);
    });

    test('grouping folds case but keeps the first member\'s spelling', () {
      final sections = groupServers([
        _server('a', group: 'Prod'),
        _server('b', group: 'prod'),
        _server('c', group: 'PROD'),
      ]);
      expect(_shape(sections), [
        ['Prod', ['a', 'b', 'c']],
      ]);
    });

    test('a blank or whitespace-only group is no group at all', () {
      final sections = groupServers([
        _server('a', group: '   '),
        _server('b', group: ''),
        _server('c', group: 'Real'),
      ]);
      expect(_shape(sections), [
        ['Real', ['c']],
        [null, ['a', 'b']],
      ]);
    });

    test('edge whitespace does not fork a near-identical group', () {
      final sections = groupServers([
        _server('a', group: 'Home lab'),
        _server('b', group: '  Home lab  '),
      ]);
      expect(sections, hasLength(1));
      expect(sections.single.servers, hasLength(2));
    });
  });

  group('pinning', () {
    test('pinned servers lead, in the list\'s own order', () {
      final sections = groupServers(
        [_server('a'), _server('b'), _server('c')],
        pinnedIds: {'c', 'a'},
      );
      expect(sections.first.key, kPinnedKey);
      expect(sections.first.header, kPinnedLabel);
      // 'a' before 'c' — the shortlist keeps the list's order, not the order
      // the two were pinned in.
      expect(sections.first.servers.map((s) => s.label), ['a', 'c']);
      expect(sections.last.servers.map((s) => s.label), ['b']);
    });

    test('the leftovers are headed even when nothing is grouped', () {
      final sections = groupServers(
        [_server('a'), _server('b')],
        pinnedIds: {'a'},
      );
      // Without a header of its own the remainder would read as more of the
      // pinned section.
      expect(sections.map((s) => s.header), [kPinnedLabel, kUnpinnedLabel]);
    });

    test('a pinned server leaves its group rather than appearing twice', () {
      final sections = groupServers(
        [
          _server('web', group: 'Production'),
          _server('db', group: 'Production'),
        ],
        pinnedIds: {'web'},
      );
      expect(_shape(sections), [
        [null, ['web']],
        ['Production', ['db']],
      ]);
      // The group's count is what is left in it, so folding it away never
      // claims to hide a row that is sitting at the top of the list.
      expect(sections.last.servers, hasLength(1));
    });

    test('the ungrouped leftovers keep their own name beside real groups', () {
      final sections = groupServers(
        [
          _server('web', group: 'Production'),
          _server('loose'),
          _server('pinned-one'),
        ],
        pinnedIds: {'pinned-one'},
      );
      expect(sections.map((s) => s.header), [
        kPinnedLabel,
        'Production',
        kUngroupedLabel,
      ]);
    });

    test('pinning everything leaves no empty remainder behind', () {
      final sections = groupServers(
        [_server('a'), _server('b')],
        pinnedIds: {'a', 'b'},
      );
      expect(sections, hasLength(1));
      expect(sections.single.key, kPinnedKey);
    });

    test('an id that names no server pins nothing', () {
      final sections = groupServers(
        [_server('a')],
        pinnedIds: {'deleted-elsewhere'},
      );
      // Exactly the anonymous, headerless list an unpinned one renders as.
      expect(sections, hasLength(1));
      expect(sections.single.header, isNull);
    });

    test('a group literally named "Pinned" cannot claim the shortlist', () {
      final sections = groupServers(
        [_server('a', group: 'Pinned'), _server('b'), _server('c')],
        pinnedIds: {'b'},
      );
      final keys = sections.map((s) => s.key).toList();
      expect(keys, [kPinnedKey, serverGroupKey('Pinned'), kUngroupedKey]);
      // Distinct keys are what keep folding one from folding the other.
      expect(keys.toSet(), hasLength(3));
    });

    test('no spelling of a group name can reach the shortlist\'s key', () {
      // [kPinnedKey] is collision-free only because [normalizeServerGroup]
      // trims, which is an invariant in another function with nothing tying
      // it to this constant. If trimming ever stopped, a user-typed group
      // would start folding the pinned section away with it.
      for (final spelling in [
        'Pinned',
        'pinned',
        ' pinned',
        'pinned ',
        '  Pinned  ',
        kPinnedKey,
      ]) {
        final section = groupServers(
          [_server('a', group: spelling)],
        ).single;
        expect(section.key, isNot(kPinnedKey));
        expect(section.key, isNot(kUngroupedKey));
      }
    });

    test('the shortlist folds away like any other section', () {
      final rows = serverListRows(
        sections: groupServers(
          [_server('a'), _server('b')],
          pinnedIds: {'a'},
        ),
        collapsedKeys: {kPinnedKey},
      );
      expect(rows.whereType<ServerRow>().map((r) => r.server.label), ['b']);
      // The header stays — it is the only way back.
      final header = rows.whereType<ServerGroupHeaderRow>().first;
      expect(header.name, kPinnedLabel);
      expect(header.collapsed, isTrue);
      expect(header.count, 1);
    });
  });

  group('serverListRows', () {
    List<ServerListRow> rowsFor(
      List<ServerConfig> servers, {
      Set<String> collapsed = const {},
    }) => serverListRows(
      sections: groupServers(servers),
      collapsedKeys: collapsed,
    );

    test('an ungrouped list renders no headers at all', () {
      final rows = rowsFor([_server('a'), _server('b')]);
      expect(rows.whereType<ServerGroupHeaderRow>(), isEmpty);
      expect(rows, hasLength(2));
    });

    test('each section gets a header carrying its member count', () {
      final rows = rowsFor([
        _server('web', group: 'Production'),
        _server('db', group: 'Production'),
        _server('loose'),
      ]);
      final headers = rows.whereType<ServerGroupHeaderRow>().toList();
      expect(headers.map((h) => h.name), ['Production', kUngroupedLabel]);
      expect(headers.map((h) => h.count), [2, 1]);
      expect(rows.whereType<ServerRow>(), hasLength(3));
    });

    test('a collapsed section keeps its header and drops its members', () {
      final rows = rowsFor(
        [
          _server('web', group: 'Production'),
          _server('db', group: 'Production'),
          _server('runner', group: 'CI'),
        ],
        collapsed: {'production'},
      );
      final headers = rows.whereType<ServerGroupHeaderRow>().toList();
      expect(headers.map((h) => h.name), ['CI', 'Production']);
      expect(
        headers.firstWhere((h) => h.name == 'Production').collapsed,
        isTrue,
      );
      // The count still reports what is folded away, and only CI's member
      // survives as a row.
      expect(headers.firstWhere((h) => h.name == 'Production').count, 2);
      expect(
        rows.whereType<ServerRow>().map((r) => r.server.label),
        ['runner'],
      );
    });

    test('the ungrouped section collapses like any other', () {
      final rows = rowsFor(
        [_server('web', group: 'Production'), _server('loose')],
        collapsed: {kUngroupedKey},
      );
      expect(
        rows.whereType<ServerRow>().map((r) => r.server.label),
        ['web'],
      );
    });

    test('collapsing keys are case-folded like the groups they name', () {
      final rows = rowsFor(
        [_server('web', group: 'Production'), _server('loose')],
        collapsed: {serverGroupKey('PRODUCTION')},
      );
      expect(
        rows.whereType<ServerRow>().map((r) => r.server.label),
        ['loose'],
      );
    });

    test('a stale key for a group that no longer exists is harmless', () {
      final rows = rowsFor(
        [_server('a'), _server('b')],
        collapsed: {'a-group-that-was-renamed'},
      );
      expect(rows.whereType<ServerRow>(), hasLength(2));
    });
  });

  group('existingServerGroups', () {
    test('lists each group once, sorted, in its first spelling', () {
      final groups = existingServerGroups([
        _server('a', group: 'Production'),
        _server('b', group: 'CI'),
        _server('c', group: 'production'),
        _server('d'),
      ]);
      expect(groups, ['CI', 'Production']);
    });

    test('is empty when nothing is grouped', () {
      expect(existingServerGroups([_server('a'), _server('b')]), isEmpty);
    });
  });
}
