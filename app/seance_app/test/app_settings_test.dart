import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/external_file_opener.dart';

void main() {
  test('checkForUpdates defaults on and round-trips through JSON', () {
    expect(AppSettings().checkForUpdates, isTrue);

    final off = AppSettings(checkForUpdates: false);
    final restored = AppSettings.fromJson(off.toJson());
    expect(restored.checkForUpdates, isFalse);

    final on = AppSettings(checkForUpdates: true);
    expect(AppSettings.fromJson(on.toJson()).checkForUpdates, isTrue);
  });

  test('missing checkForUpdates in stored JSON defaults to on', () {
    final json = AppSettings().toJson()..remove('checkForUpdates');
    expect(AppSettings.fromJson(json).checkForUpdates, isTrue);
  });

  test('remote editor and path bookmarks round-trip safely', () {
    final settings = AppSettings(
      editorRegistry: EditorRegistry(
        defaultEditorId: 'editor.code',
        editors: const [
          ExternalEditorDefinition(
            id: 'editor.code',
            displayName: 'Code',
            platform: EditorHostPlatform.linux,
            launchTarget: '/usr/bin/code',
            acceptedExtensions: ['dart', 'json'],
          ),
        ],
      ),
      remotePathBookmarks: {
        'server': ['/var/log', '/home/test'],
      },
      remoteShowHidden: {'server': false},
    );

    final restored = AppSettings.fromJson(settings.toJson());

    expect(restored.editorRegistry.defaultEditorId, 'editor.code');
    expect(restored.editorRegistry.editors.single.displayName, 'Code');
    expect(restored.remotePathBookmarks['server'], ['/home/test', '/var/log']);
    expect(restored.remoteShowHidden['server'], isFalse);
  });

  test('identity file bookmarks round-trip and drop malformed entries', () {
    const entry = IdentityFileBookmark(
      path: '/Users/ada/keys/id_ed25519',
      bookmark: 'Ym9va21hcms=',
    );
    final settings = AppSettings(identityFileBookmarks: {'server': entry});
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.identityFileBookmarks, {'server': entry});

    final json = AppSettings().toJson()
      ..['identityFileBookmarks'] = {
        'server': {'path': '/k', 'bookmark': 'Ym9va21hcms='},
        'legacyString': 'Ym9va21hcms=',
        'emptyBookmark': {'path': '/k', 'bookmark': ''},
        'missingPath': {'bookmark': 'Ym9va21hcms='},
        8: {'path': '/k', 'bookmark': 'Ym9va21hcms='},
      };
    expect(AppSettings.fromJson(json).identityFileBookmarks, {
      'server': const IdentityFileBookmark(path: '/k', bookmark: 'Ym9va21hcms='),
    });
    expect(AppSettings.fromJson(json..remove('identityFileBookmarks'))
        .identityFileBookmarks, isEmpty);
  });

  test('unknown editor and malformed bookmarks fall back safely', () {
    final json = AppSettings().toJson()
      ..['editorRegistry'] = {
        'version': 1,
        'defaultEditorId': 'missing',
        'editors': [
          {'id': 7},
        ],
      }
      ..['remotePathBookmarks'] = {
        'server': ['relative', '/valid', 7],
        8: ['/ignored'],
      }
      ..['remoteShowHidden'] = {'server': true, 'bad': 'yes', 7: false};

    final restored = AppSettings.fromJson(json);

    expect(
      restored.editorRegistry.defaultEditorId,
      EditorRegistry.systemDefaultId,
    );
    expect(restored.remotePathBookmarks, {
      'server': ['/valid'],
    });
    expect(restored.remoteShowHidden, {'server': true});
  });

  test('malformed registry metadata does not discard other settings', () {
    final json =
        AppSettings(
            checkForUpdates: false,
            remotePathBookmarks: {
              'server': ['/srv'],
            },
          ).toJson()
          ..['editorRegistry'] = {
            'version': 1,
            'defaultEditorId': 42,
            'editors': const [],
          };

    final restored = AppSettings.fromJson(json);

    expect(restored.checkForUpdates, isFalse);
    expect(restored.remotePathBookmarks, {
      'server': ['/srv'],
    });
    expect(
      restored.editorRegistry.defaultEditorId,
      EditorRegistry.systemDefaultId,
    );
  });

  test('legacy BBEdit setting migrates into the editor registry', () {
    final json = AppSettings().toJson()
      ..remove('editorRegistry')
      ..['remoteFileEditor'] = 'bbedit';

    final restored = AppSettings.fromJson(json);

    expect(
      restored.editorRegistry.defaultEditorId,
      EditorRegistry.migratedBbeditId,
    );
    expect(restored.editorRegistry.editors.single.displayName, 'BBEdit');
  });

  test('collapsed server groups round-trip and are stored sorted', () {
    final settings = AppSettings(
      collapsedServerGroups: {'production', 'ci', 'home lab'},
    );
    final json = settings.toJson();
    expect(json['collapsedServerGroups'], ['ci', 'home lab', 'production']);
    expect(
      AppSettings.fromJson(json).collapsedServerGroups,
      {'ci', 'home lab', 'production'},
    );
  });

  test('a missing or malformed collapsed-group list reads as empty', () {
    expect(AppSettings().collapsedServerGroups, isEmpty);

    final missing = AppSettings().toJson()..remove('collapsedServerGroups');
    expect(AppSettings.fromJson(missing).collapsedServerGroups, isEmpty);

    // Hand-edited or downgraded: keep the strings, drop what isn't one,
    // rather than failing the whole settings load over folded sections.
    final messy = AppSettings().toJson()
      ..['collapsedServerGroups'] = ['ci', 7, null, 'ci'];
    expect(AppSettings.fromJson(messy).collapsedServerGroups, {'ci'});

    final wrongShape = AppSettings().toJson()
      ..['collapsedServerGroups'] = 'production';
    expect(AppSettings.fromJson(wrongShape).collapsedServerGroups, isEmpty);
  });

  test('pane widths round-trip and default to unset', () {
    expect(AppSettings().paneListWidth, isNull);
    expect(AppSettings().paneUtilityWidth, isNull);
    // Unset widths stay out of the JSON entirely, so an older version's
    // settings file is byte-identical until a handle is actually dragged.
    expect(AppSettings().toJson().containsKey('paneListWidth'), isFalse);
    expect(AppSettings().toJson().containsKey('paneUtilityWidth'), isFalse);

    final settings = AppSettings(paneListWidth: 420, paneUtilityWidth: 512.5);
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.paneListWidth, 420);
    expect(restored.paneUtilityWidth, 512.5);
  });

  test('malformed pane widths read as unset', () {
    for (final bad in <Object?>['wide', -1, 0, double.nan, double.infinity]) {
      final json = AppSettings().toJson()
        ..['paneListWidth'] = bad
        ..['paneUtilityWidth'] = bad;
      final restored = AppSettings.fromJson(json);
      expect(restored.paneListWidth, isNull, reason: '$bad');
      expect(restored.paneUtilityWidth, isNull, reason: '$bad');
    }
  });

  test(
    'concurrent saves are serialized without corrupting the index',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'seance-settings-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = SettingsStore(File('${directory.path}/settings.json'));
      final settings = AppSettings(checkForUpdates: false);

      final first = store.save(settings);
      settings.checkForUpdates = true;
      final second = store.save(settings);
      await Future.wait([first, second]);

      expect((await store.load()).checkForUpdates, isTrue);
    },
  );
}
