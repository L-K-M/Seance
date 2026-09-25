import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/settings_backend.dart';
import 'package:seance_app/services/settings_window.dart';
import 'package:seance_app/settings_window_app.dart';
import 'package:seance_app/theme/theme_presets.dart';
import 'package:seance_app/ui/settings_screen.dart';

const _link = MethodChannel('test/settings_window_app/link');

/// The settings window draws itself in the app's theme, from the snapshots
/// the app sends, and rebuilds its MaterialApp only when one moves it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, dynamic> snapshot(AppSettings settings) => {
    'settings': settings.toJson(),
    'llmConfigVersion': 1,
    'syncStatus': const SyncStatus().toJson(),
  };

  /// What the app's side sends the window: a call on its end of the link.
  Future<void> fromApp(String method, Object argument) =>
      messenger.handlePlatformMessage(
        _link.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, jsonEncode(argument)),
        ),
        (_) {},
      );

  testWidgets('the window follows the app\'s theme, and only its theme', (
    tester,
  ) async {
    final settings = AppSettings(themePalette: ThemePresets.midnight);
    messenger.setMockMethodCallHandler(_link, (call) async {
      if (call.method != 'hello') return null;
      return jsonEncode({'snapshot': snapshot(settings), 'tab': 'general'});
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_link, null));
    final backend = await RemoteSettingsBackend.connect(link: _link);
    addTearDown(backend.dispose);

    await tester.pumpWidget(SettingsWindowApp(backend: backend));
    await tester.pumpAndSettle();
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().theme?.colorScheme.surface, ThemePresets.midnight.surface);

    // Most snapshots carry nothing about the theme.
    final before = app();
    settings.terminalFontSize = 20;
    await fromApp('snapshot', snapshot(settings));
    await tester.pumpAndSettle();
    expect(backend.settings.terminalFontSize, 20);
    expect(app(), same(before));

    settings.themePalette = ThemePresets.paper;
    await fromApp('snapshot', snapshot(settings));
    await tester.pumpAndSettle();
    expect(app().theme?.colorScheme.surface, ThemePresets.paper.surface);
    final screen = tester.element(find.byType(SettingsScreen));
    expect(Theme.of(screen).colorScheme.surface, ThemePresets.paper.surface);
  });
}
