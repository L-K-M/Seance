import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

const _bookmarkId = '5f0c2a7e-3c1b-4b8e-9a51-2f6f0e7d1c22';
const _recordId = 'bookmark:$_bookmarkId';
final _createdAt = DateTime.utc(2026, 8, 30, 10, 12);
final _updatedAt = DateTime.utc(2026, 8, 30, 11, 13);

Map<String, dynamic> _baseJson(BookmarkKind kind) => {
  'id': _bookmarkId,
  'kind': kind.name,
  'label': 'Work',
  'preferredPane': 'right',
  'sortKey': 'hm',
  'createdAt': _createdAt.toIso8601String(),
  'updatedAt': _updatedAt.toIso8601String(),
};

Map<String, dynamic> _identityJson() => const {
  'identity': {
    'host': 'nas.local',
    'port': 2222,
    'username': 'alice',
    'authMethod': 'privateKey',
    'secretRef': ' secret-1 ',
    'identityFilePath': ' ~/.ssh/id_ed25519 ',
  },
};

void main() {
  group('Bookmark JSON', () {
    test('round-trips every bookmark kind', () {
      final bookmarks = [
        Bookmark(
          id: _bookmarkId,
          kind: BookmarkKind.localFolder,
          label: 'Downloads',
          localPath: '~/Downloads',
          preferredPane: PreferredPane.left,
          sortKey: 'a',
          createdAt: _createdAt,
          updatedAt: _updatedAt,
        ),
        Bookmark(
          id: _bookmarkId,
          kind: BookmarkKind.remotePath,
          label: 'Logs',
          group: 'Work',
          color: ServerColor.violet,
          icon: ServerIcon.database,
          server: const BookmarkServerRef(serverConfigId: 'server-1'),
          remotePath: '/var/log/nginx',
          preferredPane: PreferredPane.right,
          sortKey: 'b',
          createdAt: _createdAt,
          updatedAt: _updatedAt,
        ),
        Bookmark(
          id: _bookmarkId,
          kind: BookmarkKind.workspace,
          label: 'Site',
          left: const BookmarkLocation(path: '~/site'),
          right: const BookmarkLocation(
            server: BookmarkServerRef(
              identity: EmbeddedHostIdentity(
                host: 'nas.local',
                username: 'alice',
                authMethod: AuthMethod.privateKey,
              ),
            ),
            path: '/srv/site',
          ),
          sortKey: 'c',
          createdAt: _createdAt,
          updatedAt: _updatedAt,
        ),
        Bookmark(
          id: _bookmarkId,
          kind: BookmarkKind.savedSync,
          label: 'Deploy',
          sync: SavedSyncSpec(
            source: const BookmarkLocation(path: '~/site'),
            destination: const BookmarkLocation(
              server: BookmarkServerRef(serverConfigId: 'server-1'),
              path: '/srv/site',
            ),
            ignoreRules: ['.git/**'],
            rulesVersion: 1,
            rules: {
              'direction': 'leftToRight',
              'future': {'enabled': true},
            },
          ),
          sortKey: 'd',
          createdAt: _createdAt,
          updatedAt: _updatedAt,
        ),
      ];

      for (final bookmark in bookmarks) {
        final decoded = Bookmark.fromJson(
          bookmark.toJson(),
          recordId: _recordId,
        );

        expect(decoded.toJson(), bookmark.toJson());
      }
    });

    test('cosmetic unknowns fall back without hiding the bookmark', () {
      final decoded = Bookmark.fromJson({
        ..._baseJson(BookmarkKind.localFolder),
        'localPath': '~/Downloads',
        'color': 'chartreuse',
        'icon': 'folder',
        'preferredPane': 'futurePane',
        'group': '   ',
      }, recordId: _recordId);

      expect(decoded.color, isNull);
      expect(decoded.icon, isNull);
      expect(decoded.preferredPane, PreferredPane.either);
      expect(decoded.group, isNull);
    });

    test('saved sync defaults and retains unknown rules deeply', () {
      final rules = <String, Object?>{
        'future': <String, Object?>{
          'list': <Object?>[1, true],
        },
      };
      final json = {
        ..._baseJson(BookmarkKind.savedSync),
        'sync': {
          'source': {'path': '~/site'},
          'destination': {'path': '~/backup'},
          'rules': rules,
        },
      };
      final decoded = Bookmark.fromJson(json, recordId: _recordId);

      rules['future'] = false;
      expect(decoded.sync!.ignoreRules, isEmpty);
      expect(decoded.sync!.rulesVersion, 1);
      expect(decoded.sync!.rules['future'], isA<Map<String, Object?>>());
      expect(() => decoded.sync!.rules['new'] = true, throwsUnsupportedError);
      expect(
        () => (decoded.sync!.rules['future']! as Map<String, Object?>)['new'] =
            true,
        throwsUnsupportedError,
      );
      expect(
        () =>
            ((decoded.sync!.rules['future']! as Map<String, Object?>)['list']!
                    as List<Object?>)
                .add(2),
        throwsUnsupportedError,
      );
      expect(
        decoded.toJson()['sync'],
        containsPair(
          'rules',
          containsPair('future', containsPair('list', [1, true])),
        ),
      );
    });

    test('saved sync constructor owns immutable rule inputs', () {
      final ignoreRules = <String>['.git/**'];
      final nestedRules = <Object?>[1];
      final futureRules = <String, Object?>{'list': nestedRules};
      final rules = <String, Object?>{'future': futureRules};
      final spec = SavedSyncSpec(
        source: const BookmarkLocation(path: '~/site'),
        destination: const BookmarkLocation(path: '~/backup'),
        ignoreRules: ignoreRules,
        rules: rules,
      );

      ignoreRules.add('build/**');
      nestedRules.add(2);
      futureRules['enabled'] = true;
      rules['replacement'] = false;

      expect(spec.ignoreRules, ['.git/**']);
      expect(spec.rules, {
        'future': {
          'list': [1],
        },
      });
      expect(() => spec.ignoreRules.add('tmp/**'), throwsUnsupportedError);
      expect(
        () => (spec.rules['future']! as Map<String, Object?>)['new'] = true,
        throwsUnsupportedError,
      );
    });

    test('future rule versions remain available to the execution gate', () {
      final decoded = Bookmark.fromJson({
        ..._baseJson(BookmarkKind.savedSync),
        'sync': {
          'source': {'path': '~/site'},
          'destination': {'path': '~/backup'},
          'rulesVersion': 2,
          'rules': {'future': true},
        },
      }, recordId: _recordId);

      expect(decoded.sync!.rulesVersion, 2);
      expect(decoded.sync!.rules, {'future': true});
    });
  });

  group('Bookmark strict decoding', () {
    test('rejects unknown kinds and an envelope id mismatch', () {
      expect(
        () => Bookmark.fromJson({
          ..._baseJson(BookmarkKind.localFolder),
          'kind': 'futureKind',
          'localPath': '~/Downloads',
        }, recordId: _recordId),
        throwsFormatException,
      );
      expect(
        () => Bookmark.fromJson({
          ..._baseJson(BookmarkKind.localFolder),
          'localPath': '~/Downloads',
        }, recordId: 'bookmark:different'),
        throwsFormatException,
      );
    });

    test('requires exactly the fields allowed by each kind', () {
      final validByKind = <BookmarkKind, Map<String, Object?>>{
        BookmarkKind.localFolder: {'localPath': '~/Downloads'},
        BookmarkKind.remotePath: {
          'server': {'serverConfigId': 'server-1'},
          'remotePath': '/srv',
        },
        BookmarkKind.workspace: {
          'left': {'path': '~/site'},
          'right': {'path': '~/backup'},
        },
        BookmarkKind.savedSync: {
          'sync': {
            'source': {'path': '~/site'},
            'destination': {'path': '~/backup'},
          },
        },
      };

      for (final entry in validByKind.entries) {
        expect(
          () => Bookmark.fromJson({
            ..._baseJson(entry.key),
            ...entry.value,
          }, recordId: _recordId),
          returnsNormally,
        );
        expect(
          () => Bookmark.fromJson(_baseJson(entry.key), recordId: _recordId),
          throwsFormatException,
        );
      }

      expect(
        () => Bookmark.fromJson({
          ..._baseJson(BookmarkKind.localFolder),
          'localPath': '~/Downloads',
          'remotePath': '/srv',
        }, recordId: _recordId),
        throwsFormatException,
      );
    });

    test('ignores and drops unknown top-level fields', () {
      final decoded = Bookmark.fromJson({
        ..._baseJson(BookmarkKind.localFolder),
        'localPath': '~/Downloads',
        'futureTopLevel': true,
      }, recordId: _recordId);

      expect(decoded.toJson(), isNot(contains('futureTopLevel')));
    });

    test('rejects blank structural strings and invalid timestamps', () {
      for (final field in ['id', 'label', 'sortKey', 'localPath']) {
        final json = {
          ..._baseJson(BookmarkKind.localFolder),
          'localPath': '~/Downloads',
          field: '   ',
        };
        expect(
          () => Bookmark.fromJson(json, recordId: _recordId),
          throwsFormatException,
          reason: field,
        );
      }
      expect(
        () => Bookmark.fromJson({
          ..._baseJson(BookmarkKind.localFolder),
          'localPath': '~/Downloads',
          'createdAt': 'not-a-date',
        }, recordId: _recordId),
        throwsFormatException,
      );
      expect(
        () => Bookmark.fromJson({
          ..._baseJson(BookmarkKind.localFolder),
          'localPath': '~/Downloads',
          'updatedAt': 'not-a-date',
        }, recordId: _recordId),
        throwsFormatException,
      );
      expect(
        () => Bookmark.fromJson({
          ..._baseJson(BookmarkKind.localFolder),
          'localPath': '~/Downloads',
          // Offset-less timestamps are ambiguous across devices.
          'createdAt': '2026-08-30T10:12:00',
        }, recordId: _recordId),
        throwsFormatException,
      );
    });

    test('rejects rule versions before the initial schema', () {
      for (final rulesVersion in [0, -1]) {
        expect(
          () => Bookmark.fromJson({
            ..._baseJson(BookmarkKind.savedSync),
            'sync': {
              'source': {'path': '~/site'},
              'destination': {'path': '~/backup'},
              'rulesVersion': rulesVersion,
            },
          }, recordId: _recordId),
          throwsFormatException,
        );
      }
    });

    test('rejects relative remote paths', () {
      expect(
        () => Bookmark.fromJson({
          ..._baseJson(BookmarkKind.remotePath),
          'server': {'serverConfigId': 'server-1'},
          'remotePath': 'srv/site',
        }, recordId: _recordId),
        throwsFormatException,
      );
      expect(
        () => BookmarkLocation.fromJson({
          'server': {'serverConfigId': 'server-1'},
          'path': 'srv/site',
        }),
        throwsFormatException,
      );
    });

    test('server refs are strict XOR unions', () {
      final valid = {
        ..._baseJson(BookmarkKind.remotePath),
        'server': {'serverConfigId': 'server-1'},
        'remotePath': '/srv',
      };
      for (final server in [
        <String, Object?>{},
        {'serverConfigId': 'server-1', ..._identityJson()},
        {'serverConfigId': '   '},
        {
          'identity': {
            'host': 'nas.local',
            'port': 0,
            'username': 'alice',
            'authMethod': 'agent',
          },
        },
        {
          'identity': {
            'host': 'nas.local',
            'port': 22,
            'username': 'alice',
            'authMethod': 'futureAuth',
          },
        },
      ]) {
        expect(
          () => Bookmark.fromJson({
            ...valid,
            'server': server,
          }, recordId: _recordId),
          throwsFormatException,
        );
      }

      final decoded = Bookmark.fromJson({
        ...valid,
        'server': _identityJson(),
      }, recordId: _recordId);
      expect(decoded.server!.identity!.port, 2222);
      expect(decoded.server!.identity!.secretRef, 'secret-1');
      expect(decoded.server!.identity!.identityFilePath, '~/.ssh/id_ed25519');

      final blankCredentials = Bookmark.fromJson({
        ...valid,
        'server': {
          'identity': {
            'host': 'nas.local',
            'username': 'alice',
            'authMethod': 'privateKey',
            'secretRef': '   ',
            'identityFilePath': '   ',
          },
        },
      }, recordId: _recordId);
      expect(blankCredentials.server!.identity!.secretRef, isNull);
      expect(blankCredentials.server!.identity!.identityFilePath, isNull);
    });
  });
}
