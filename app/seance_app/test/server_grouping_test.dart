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

/// The named groups as `[name, [member labels]]` — enough to assert
/// membership and both orders at once. Nested lists rather than records
/// because `equals` compares collections structurally and records only
/// field-by-field, where a `List` field falls back to identity.
List<List<Object?>> _shape(ServerSidebarSections sections) => [
  for (final group in sections.groups)
    [
      group.name,
      [for (final s in group.servers) s.label],
    ],
];

List<String> _labels(List<ServerConfig> servers) => [
  for (final s in servers) s.label,
];

/// The rendered rows as short strings: `#TITLE:count` for a section,
/// `>name:count` for a group, `-` (or `--` nested) plus a label for a row,
/// with a trailing `+` on anything collapsed.
List<String> _rendered(List<ServerListRow> rows) => [
  for (final row in rows)
    switch (row) {
      ServerSectionRow(:final title, :final count, :final collapsed) =>
        '#$title:$count${collapsed ? '+' : ''}',
      ServerGroupHeaderRow(:final name, :final count, :final collapsed) =>
        '>$name:$count${collapsed ? '+' : ''}',
      ServerRow(:final server, :final depth) =>
        '${depth == 0 ? '-' : '--'}${server.label}',
    },
];

void main() {
  group('groupServers', () {
    test('a list with no groups is all ungrouped', () {
      final sections = groupServers([_server('a'), _server('b')]);
      expect(sections.groups, isEmpty);
      expect(sections.pinned, isEmpty);
      expect(_labels(sections.ungrouped), ['a', 'b']);
    });

    test('empty in, empty sections out', () {
      final sections = groupServers([]);
      expect(sections.pinned, isEmpty);
      expect(sections.ungrouped, isEmpty);
      expect(sections.groups, isEmpty);
      expect(sections.unpinnedCount, 0);
    });

    test('groups are sorted by name; the ungrouped are kept apart', () {
      final sections = groupServers([
        _server('loose'),
        _server('web', group: 'Production'),
        _server('runner', group: 'CI'),
        _server('also-loose'),
        _server('db', group: 'Production'),
      ]);
      expect(_shape(sections), [
        [
          'CI',
          ['runner'],
        ],
        [
          'Production',
          ['web', 'db'],
        ],
      ]);
      expect(_labels(sections.ungrouped), ['loose', 'also-loose']);
      expect(sections.unpinnedCount, 5);
    });

    test('grouping folds case but keeps the first member\'s spelling', () {
      final sections = groupServers([
        _server('a', group: 'Prod'),
        _server('b', group: 'prod'),
        _server('c', group: 'PROD'),
      ]);
      expect(_shape(sections), [
        [
          'Prod',
          ['a', 'b', 'c'],
        ],
      ]);
    });

    test('a blank or whitespace-only group is no group at all', () {
      final sections = groupServers([
        _server('a', group: '   '),
        _server('b', group: ''),
        _server('c', group: 'Real'),
      ]);
      expect(_shape(sections), [
        [
          'Real',
          ['c'],
        ],
      ]);
      expect(_labels(sections.ungrouped), ['a', 'b']);
    });

    test('edge whitespace does not fork a near-identical group', () {
      final sections = groupServers([
        _server('a', group: 'Home lab'),
        _server('b', group: '  Home lab  '),
      ]);
      expect(sections.groups, hasLength(1));
      expect(sections.groups.single.servers, hasLength(2));
    });
  });

  group('pinning', () {
    test('pinned servers lead, in the list\'s own order', () {
      final sections = groupServers(
        [_server('a'), _server('b'), _server('c')],
        pinnedIds: {'c', 'a'},
      );
      // 'a' before 'c' — the shortlist keeps the list's order, not the order
      // the two were pinned in.
      expect(_labels(sections.pinned), ['a', 'c']);
      expect(_labels(sections.ungrouped), ['b']);
    });

    test('a pinned server leaves its group rather than appearing twice', () {
      final sections = groupServers(
        [
          _server('web', group: 'Production'),
          _server('db', group: 'Production'),
        ],
        pinnedIds: {'web'},
      );
      expect(_labels(sections.pinned), ['web']);
      // The group's count is what is left in it, so folding it away never
      // claims to hide a row that is sitting at the top of the list.
      expect(_shape(sections), [
        [
          'Production',
          ['db'],
        ],
      ]);
    });

    test('an id that names no server pins nothing', () {
      final sections = groupServers(
        [_server('a')],
        pinnedIds: {'deleted-elsewhere'},
      );
      expect(sections.pinned, isEmpty);
      expect(_labels(sections.ungrouped), ['a']);
    });

    test('no spelling of a group name can reach a section\'s key', () {
      // [kPinnedKey] and [kServersKey] are collision-free only because
      // [normalizeServerGroup] trims, which is an invariant in another
      // function with nothing tying it to these constants. If trimming ever
      // stopped, a user-typed group would start folding a whole section
      // away with it.
      for (final spelling in [
        'Pinned',
        'pinned',
        ' pinned',
        'pinned ',
        '  Pinned  ',
        kPinnedKey,
        'Servers',
        ' servers',
        kServersKey,
      ]) {
        final group = groupServers([
          _server('a', group: spelling),
        ]).groups.single;
        expect(group.key, isNot(kPinnedKey));
        expect(group.key, isNot(kServersKey));
      }
    });
  });

  group('serverListRows', () {
    List<String> rowsFor(
      List<ServerConfig> servers, {
      Set<String> pinned = const {},
      Set<String> collapsed = const {},
    }) => _rendered(
      serverListRows(
        sections: groupServers(servers, pinnedIds: pinned),
        collapsedKeys: collapsed,
      ),
    );

    test('a flat list sits under one SERVERS header', () {
      expect(rowsFor([_server('a'), _server('b')]), [
        '#$kServersLabel:2',
        '-a',
        '-b',
      ]);
    });

    test('nothing to show renders nothing, not an empty caption', () {
      expect(rowsFor([]), isEmpty);
    });

    test('PINNED leads; SERVERS takes the rest', () {
      expect(rowsFor([_server('a'), _server('b')], pinned: {'b'}), [
        '#$kPinnedLabel:1',
        '-b',
        '#$kServersLabel:1',
        '-a',
      ]);
    });

    test('pinning everything leaves no empty SERVERS behind', () {
      expect(rowsFor([_server('a'), _server('b')], pinned: {'a', 'b'}), [
        '#$kPinnedLabel:2',
        '-a',
        '-b',
      ]);
    });

    test('ungrouped rows lead; groups nest their members beneath them', () {
      expect(
        rowsFor([
          _server('web', group: 'Production'),
          _server('db', group: 'Production'),
          _server('runner', group: 'CI'),
          _server('loose'),
        ]),
        [
          '#$kServersLabel:4',
          '-loose',
          '>CI:1',
          '--runner',
          '>Production:2',
          '--web',
          '--db',
        ],
      );
    });

    test('a collapsed group keeps its header and drops its members', () {
      expect(
        rowsFor(
          [
            _server('web', group: 'Production'),
            _server('db', group: 'Production'),
            _server('runner', group: 'CI'),
          ],
          collapsed: {'production'},
        ),
        // The count still reports what is folded away.
        ['#$kServersLabel:3', '>CI:1', '--runner', '>Production:2+'],
      );
    });

    test('the shortlist folds away like any group', () {
      expect(
        rowsFor(
          [_server('a'), _server('b')],
          pinned: {'a'},
          collapsed: {kPinnedKey},
        ),
        // The header stays — it is the only way back.
        ['#$kPinnedLabel:1+', '#$kServersLabel:1', '-b'],
      );
    });

    test('folding SERVERS folds its groups with it', () {
      expect(
        rowsFor(
          [_server('web', group: 'Production'), _server('loose')],
          collapsed: {kServersKey},
        ),
        ['#$kServersLabel:2+'],
      );
    });

    test('collapsing keys are case-folded like the groups they name', () {
      expect(
        rowsFor(
          [_server('web', group: 'Production'), _server('loose')],
          collapsed: {serverGroupKey('PRODUCTION')},
        ),
        ['#$kServersLabel:2', '-loose', '>Production:1+'],
      );
    });

    test('a stale key for a group that no longer exists is harmless', () {
      expect(
        rowsFor(
          [_server('a'), _server('b')],
          collapsed: {'a-group-that-was-renamed', ''},
        ),
        ['#$kServersLabel:2', '-a', '-b'],
      );
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
