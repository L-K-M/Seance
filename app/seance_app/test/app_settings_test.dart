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
      remoteFileEditor: RemoteFileEditor.bbedit,
      remotePathBookmarks: {
        'server': ['/var/log', '/home/test'],
      },
      remoteShowHidden: {'server': false},
    );

    final restored = AppSettings.fromJson(settings.toJson());

    expect(restored.remoteFileEditor, RemoteFileEditor.bbedit);
    expect(restored.remotePathBookmarks['server'], ['/home/test', '/var/log']);
    expect(restored.remoteShowHidden['server'], isFalse);
  });

  test('unknown editor and malformed bookmarks fall back safely', () {
    final json = AppSettings().toJson()
      ..['remoteFileEditor'] = 'missing'
      ..['remotePathBookmarks'] = {
        'server': ['relative', '/valid', 7],
        8: ['/ignored'],
      }
      ..['remoteShowHidden'] = {'server': true, 'bad': 'yes', 7: false};

    final restored = AppSettings.fromJson(json);

    expect(restored.remoteFileEditor, RemoteFileEditor.systemDefault);
    expect(restored.remotePathBookmarks, {
      'server': ['/valid'],
    });
    expect(restored.remoteShowHidden, {'server': true});
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
