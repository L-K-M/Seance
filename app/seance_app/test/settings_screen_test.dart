import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/external_file_opener.dart';
import 'package:seance_app/services/settings_backend.dart';
import 'package:seance_app/services/system_fonts.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/theme/app_appearance.dart';
import 'package:seance_app/theme/theme_palette.dart';
import 'package:seance_app/theme/theme_presets.dart';
import 'package:seance_app/ui/settings_screen.dart';
import 'package:seance_app/ui/terminal_appearance.dart';
import 'package:seance_core/seance_core.dart';

/// Records what the screen asks for and answers with what the test says.
class _FakeBackend extends ChangeNotifier implements SettingsBackend {
  @override
  AppSettings settings = AppSettings();

  @override
  int llmConfigVersion = 3;

  @override
  SyncStatus syncStatus = const SyncStatus();

  final List<String> calls = [];
  AssistantDraft? lastDraft;
  AssistantSaveResult Function(AssistantDraft draft)? onSave;
  Object? failWrites;

  Future<void> _write(String call) async {
    calls.add(call);
    if (failWrites != null) throw failWrites!;
  }

  @override
  Future<void> setCheckForUpdates(bool enabled) =>
      _write('setCheckForUpdates($enabled)');

  @override
  Future<void> setKeepSessionsAlive(bool enabled) =>
      _write('setKeepSessionsAlive($enabled)');

  @override
  Future<void> setCommandSuggestions(bool enabled) =>
      _write('setCommandSuggestions($enabled)');

  @override
  Future<void> setTerminalAppearance({
    required double fontSize,
    required String fontFamily,
    required TerminalPalette palette,
  }) => _write('setTerminalAppearance($fontSize, $fontFamily, $palette)');

  /// Every theme written, in order.
  final List<(ThemePalette, ThemeModePreference)> appearances = [];

  /// When set, theme writes wait for it: a write still in flight.
  Completer<void>? holdAppearance;

  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async {
    appearances.add((palette, mode));
    await holdAppearance?.future;
    return _write('setAppearance');
  }

  @override
  Future<void> setEditorRegistry(EditorRegistry registry) =>
      _write('setEditorRegistry');

  @override
  Future<ExternalEditorDefinition?> pickEditor() async => null;

  @override
  Future<List<String>> fetchModels(ModelQuery query) async => const [];

  @override
  Future<AssistantSaveResult> saveAssistant(AssistantDraft draft) async {
    lastDraft = draft;
    return onSave!(draft);
  }

  @override
  Future<SyncPrefsResult> setSyncPrefs({
    required bool autoSync,
    required bool syncSecrets,
    required bool syncAssistant,
  }) async => SyncPrefsResult(
    autoSync: autoSync,
    syncSecrets: syncSecrets,
    syncAssistant: syncAssistant,
    current: AssistantFields.of(settings),
    version: llmConfigVersion,
  );

  @override
  Future<void> enrollSync(SyncEnrollment enrollment) async {}

  @override
  Future<SyncCounts> syncNow() async => const SyncCounts(pulled: 0, pushed: 0);
}

AssistantFields _fields(String model) => AssistantFields(
  kind: LlmProviderKind.anthropic,
  baseUrl: 'https://api.anthropic.com',
  model: model,
  searxngUrl: '',
  zaiEnabled: false,
  redactionEnabled: true,
);

void main() {
  late _FakeBackend backend;

  setUp(() => backend = _FakeBackend());

  Future<void> pumpScreen(
    WidgetTester tester, {
    SettingsTab tab = SettingsTab.general,
    SettingsPresentation presentation = SettingsPresentation.route,
    Stream<SettingsTab>? tabRequests,
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          backend: backend,
          initialTab: tab,
          presentation: presentation,
          tabRequests: tabRequests,
          systemFonts: const NoSystemFonts(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );

  testWidgets('the window shows the tabs without the route\'s title bar', (
    tester,
  ) async {
    await pumpScreen(tester, presentation: SettingsPresentation.window);

    expect(find.text('Settings'), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    expect(find.text('Assistant'), findsOneWidget);
  });

  testWidgets('the route keeps its title', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('a switch writes through the backend', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(backend.calls, ['setCheckForUpdates(false)']);
  });

  testWidgets('a failed write says so instead of failing silently', (
    tester,
  ) async {
    backend.failWrites = const SettingsBackendException('disk full');
    await pumpScreen(tester);

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.text('Update check not saved — disk full'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a failed keep-alive write says so and turns the switch back', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      backend.failWrites = const SettingsBackendException('disk full');
      await pumpScreen(tester);
      final toggle = find.widgetWithText(
        SwitchListTile,
        'Keep sessions alive in the background',
      );
      final before = tester.widget<SwitchListTile>(toggle).value;

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(
        find.text('Keep sessions alive not saved — disk full'),
        findsOneWidget,
      );
      expect(tester.widget<SwitchListTile>(toggle).value, before);
      await tester.pump(const Duration(seconds: 5));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Save sends the form and clears a key once it is stored', (
    tester,
  ) async {
    backend.onSave = (draft) => AssistantSaveResult(
      status: AssistantSaveStatus.saved,
      current: draft.fields,
      version: draft.versionSeen + 1,
      keysStored: true,
    );
    await pumpScreen(tester, tab: SettingsTab.assistant);

    await tester.enterText(
      field('API key (OS keystore; synced if assistant sync is on)'),
      'sk-typed',
    );
    await tester.tap(find.text('Save assistant settings'));
    await tester.pumpAndSettle();

    expect(backend.lastDraft?.llmApiKey, 'sk-typed');
    expect(backend.lastDraft?.versionSeen, 3);
    expect(find.text('sk-typed'), findsNothing);
    expect(find.text('Saved'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a refused save reloads the fields and keeps the typed key', (
    tester,
  ) async {
    backend.settings.llmModel = 'old-model';
    backend.onSave = (draft) => AssistantSaveResult(
      status: AssistantSaveStatus.adoptedBeforeSave,
      current: _fields('adopted-model'),
      version: 9,
    );
    await pumpScreen(tester, tab: SettingsTab.assistant);

    await tester.enterText(
      field('API key (OS keystore; synced if assistant sync is on)'),
      'sk-typed',
    );
    await tester.tap(find.text('Save assistant settings'));
    await tester.pumpAndSettle();

    expect(find.text('adopted-model'), findsOneWidget);
    expect(find.text('sk-typed'), findsOneWidget);
    expect(find.textContaining('changed on another device'), findsOneWidget);

    // The next save is made against the version the fields now show.
    backend.onSave = (draft) => AssistantSaveResult(
      status: AssistantSaveStatus.saved,
      current: draft.fields,
      version: 10,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('Save assistant settings'));
    await tester.pumpAndSettle();
    expect(backend.lastDraft?.versionSeen, 9);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a keystore failure names the key that failed', (tester) async {
    backend.onSave = (draft) => AssistantSaveResult(
      status: AssistantSaveStatus.keystoreFailed,
      current: draft.fields,
      version: draft.versionSeen,
      failedKey: AssistantKey.zai,
      error: 'keyring locked',
    );
    await pumpScreen(tester, tab: SettingsTab.assistant);

    await tester.tap(find.text('Save assistant settings'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Settings not saved — could not store the Z.AI key: keyring locked',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a tab request switches the open screen', (tester) async {
    final requests = StreamController<SettingsTab>();
    addTearDown(requests.close);
    await pumpScreen(tester, tabRequests: requests.stream);
    expect(find.text('Check for updates'), findsOneWidget);

    requests.add(SettingsTab.sync);
    await tester.pumpAndSettle();

    expect(find.text('Sync automatically'), findsOneWidget);
  });

  testWidgets('a tab swaps its page in place instead of sliding to it', (
    tester,
  ) async {
    await pumpScreen(tester);
    final general = tester.getRect(
      find.byKey(const PageStorageKey('general-settings')),
    );

    await tester.tap(find.widgetWithText(Tab, 'Sync'));
    await tester.pump();

    // The first frame after the tap: all of the new page, where the old one
    // was, and none of the old.
    expect(find.text('Check for updates'), findsNothing);
    expect(
      tester.getRect(find.byKey(const PageStorageKey('sync-settings'))),
      general,
    );
  });

  testWidgets('a sideways swipe does not change the tab', (tester) async {
    await pumpScreen(tester);

    await tester.fling(
      find.text('Check for updates'),
      const Offset(-600, 0),
      2000,
    );
    await tester.pumpAndSettle();

    expect(find.text('Check for updates'), findsOneWidget);
  });

  testWidgets('the sync status line follows the backend', (tester) async {
    await pumpScreen(tester, tab: SettingsTab.sync);
    expect(find.textContaining('Last sync failed'), findsNothing);

    backend
      ..syncStatus = const SyncStatus(lastSyncError: 'server down')
      ..notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('Last sync failed: server down'), findsOneWidget);
  });

  group('Appearance', () {
    /// Tall enough that the whole tab is built at once.
    Future<void> pumpAppearance(WidgetTester tester) async {
      await pumpScreen(tester, tab: SettingsTab.appearance);
      tester.view.physicalSize = const Size(1000, 4200);
      await tester.pumpAndSettle();
    }

    ThemePalette lastPalette() => backend.appearances.last.$1;

    Finder automatic(String label) => find.byWidgetPredicate(
      (w) => w is Checkbox && w.semanticLabel == '$label: Automatic',
    );

    /// What the clipboard holds, as the platform channel answers for it.
    String? clipboard;
    setUp(() => clipboard = null);

    void mockClipboard(WidgetTester tester) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard = (call.arguments as Map)['text'] as String?;
            case 'Clipboard.getData':
              return clipboard == null ? null : {'text': clipboard};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
    }

    testWidgets('sits second, after General', (tester) async {
      await pumpScreen(tester);
      final tabs = tester.widget<TabBar>(find.byType(TabBar)).tabs;
      expect(tabs.map((tab) => (tab as Tab).text), [
        'General',
        'Appearance',
        'Assistant',
        'Files',
        'Sync',
      ]);
      expect(SettingsTab.values.map((tab) => tab.name), [
        'general',
        'appearance',
        'assistant',
        'files',
        'sync',
      ]);
    });

    testWidgets('picking a preset writes that preset', (tester) async {
      await pumpAppearance(tester);
      expect(find.text('Using Séance.'), findsOneWidget);

      await tester.tap(find.byTooltip('Use the Midnight theme'));
      await tester.pumpAndSettle();

      expect(backend.appearances, [
        (ThemePresets.midnight, ThemeModePreference.system),
      ]);
      expect(find.text('Using Midnight.'), findsOneWidget);
      // A surface of its own decides the brightness, so the mode is moot.
      final mode = tester.widget<SegmentedButton<ThemeModePreference>>(
        find.byType(SegmentedButton<ThemeModePreference>),
      );
      expect(mode.onSelectionChanged, isNull);
      expect(find.textContaining('always dark'), findsOneWidget);
    });

    testWidgets('the selected preset says so to a screen reader', (
      tester,
    ) async {
      backend.settings.themePalette = ThemePresets.paper;
      // Released in `finally`, not by a tear-down: the tester checks for a
      // live handle before tear-downs run.
      final handle = tester.ensureSemantics();
      try {
        await pumpAppearance(tester);

        expect(
          tester.getSemantics(find.byTooltip('Use the Paper theme')),
          matchesSemantics(
            label: 'Paper',
            tooltip: 'Use the Paper theme',
            isButton: true,
            hasSelectedState: true,
            isSelected: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets('the mode writes through while the surface is Automatic', (
      tester,
    ) async {
      await pumpAppearance(tester);

      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();

      expect(backend.appearances.last.$2, ThemeModePreference.dark);
      expect(lastPalette(), ThemePresets.initial);
    });

    testWidgets('Automatic hands a colour back, and back again restores it', (
      tester,
    ) async {
      backend.settings.themePalette = ThemePresets.paper;
      await pumpAppearance(tester);

      await tester.tap(automatic('Sidebar'));
      await tester.pumpAndSettle();
      expect(lastPalette().sidebar, isNull);
      expect(lastPalette().name, ThemePalette.customName);
      expect(find.text('Using your own colours.'), findsOneWidget);

      await tester.tap(automatic('Sidebar'));
      await tester.pumpAndSettle();
      expect(lastPalette().sidebar, ThemePresets.paper.sidebar);
      // Back to exactly the preset, it is the preset again.
      expect(lastPalette(), ThemePresets.paper);
    });

    testWidgets('leaving Automatic starts from the colour drawn now', (
      tester,
    ) async {
      await pumpAppearance(tester);

      await tester.tap(automatic('Text'));
      await tester.pumpAndSettle();

      // The test's platform is light, so Automatic text is the light
      // table's, not black and not the dark table's.
      expect(
        lastPalette().text,
        SeanceTheme.resolvedSlots(
          ThemePresets.initial,
          Brightness.light,
        )[ThemeSlot.text],
      );
    });

    testWidgets('a swatch opens the picker and writes what it returns', (
      tester,
    ) async {
      await pumpAppearance(tester);

      await tester.tap(find.byTooltip('Choose the Accent colour'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, 'Accent'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '1e90ff',
      );
      await tester.tap(find.text('Use colour'));
      await tester.pumpAndSettle();

      expect(lastPalette().accent, const Color(0xFF1E90FF));
      expect(lastPalette().name, ThemePalette.customName);
    });

    testWidgets('the lines colour may be translucent', (tester) async {
      await pumpAppearance(tester);

      await tester.tap(find.byTooltip('Choose a Lines colour (now Automatic)'));
      await tester.pumpAndSettle();
      // Hue, saturation, brightness and opacity.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Slider),
        ),
        findsNWidgets(4),
      );
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '11223380',
      );
      await tester.tap(find.text('Use colour'));
      await tester.pumpAndSettle();

      expect(lastPalette().hairline, const Color(0x80112233));
    });

    testWidgets('the terminal switch starts from the built-in colours', (
      tester,
    ) async {
      await pumpAppearance(tester);
      expect(find.text('Normal'), findsNothing);

      await tester.tap(find.text("Use the theme's terminal colours"));
      await tester.pumpAndSettle();

      expect(
        lastPalette().terminal,
        SeanceTerminalThemes.toColors(SeanceTerminalThemes.light),
      );
      expect(find.text('Normal'), findsOneWidget);
      expect(find.byTooltip('Choose the Bright cyan colour'), findsOneWidget);

      await tester.tap(find.text("Use the theme's terminal colours"));
      await tester.pumpAndSettle();
      expect(lastPalette().terminal, isNull);
    });

    testWidgets('the corners slider writes the scale', (tester) async {
      await pumpAppearance(tester);
      final slider = find.byWidgetPredicate(
        (w) => w is Slider && w.max == ThemePalette.maxCornerScale,
      );

      await tester.drag(slider, Offset(-tester.getSize(slider).width, 0));
      await tester.pumpAndSettle();

      expect(lastPalette().cornerScale, 0);
      expect(find.text('Square'), findsWidgets);
    });

    testWidgets('reset asks first, and keeps the mode', (tester) async {
      backend.settings
        ..themePalette = ThemePresets.vapor
        ..themeMode = ThemeModePreference.dark;
      await pumpAppearance(tester);

      await tester.tap(find.text('Reset to Séance'));
      await tester.pumpAndSettle();
      expect(find.text('Reset the theme?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.appearances, isEmpty);

      await tester.tap(find.text('Reset to Séance'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await tester.pumpAndSettle();
      expect(backend.appearances, [
        (ThemePresets.initial, ThemeModePreference.dark),
      ]);
    });

    testWidgets('copy puts the theme on the clipboard as JSON', (tester) async {
      mockClipboard(tester);
      backend.settings.themePalette = ThemePresets.solarized;
      await pumpAppearance(tester);

      await tester.tap(find.text('Copy theme'));
      await tester.pumpAndSettle();

      expect(
        ThemePalette.decodeStored(jsonDecode(clipboard!)),
        ThemePresets.solarized,
      );
      expect(find.text('Theme copied.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('pasting something that is not a theme changes nothing', (
      tester,
    ) async {
      mockClipboard(tester);
      clipboard = 'ssh deploy@web.example.com';
      await pumpAppearance(tester);

      await tester.tap(find.text('Paste theme'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('The clipboard does not hold a theme'),
        findsOneWidget,
      );
      expect(backend.appearances, isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('pasting a theme adopts it whole', (tester) async {
      mockClipboard(tester);
      clipboard = jsonEncode(ThemePresets.terminal.toJson());
      await pumpAppearance(tester);

      await tester.tap(find.text('Paste theme'));
      await tester.pumpAndSettle();

      expect(lastPalette(), ThemePresets.terminal);
      expect(find.text('Using Terminal.'), findsOneWidget);
    });

    testWidgets('fits a phone', (tester) async {
      backend.settings.themePalette = ThemePresets.paper;
      await pumpScreen(tester, tab: SettingsTab.appearance);
      tester.view.physicalSize = const Size(360, 4200);
      await tester.pumpAndSettle();

      // Two presets to a row, and every section drawn without overflowing.
      final first = tester.getRect(find.byTooltip('Use the Séance theme'));
      final second = tester.getRect(find.byTooltip('Use the Graphite theme'));
      final third = tester.getRect(find.byTooltip('Use the Paper theme'));
      expect(second.top, first.top);
      expect(third.top, greaterThan(first.bottom));
      expect(find.byTooltip('Choose the Bright white colour'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed write says so', (tester) async {
      backend.failWrites = const SettingsBackendException('disk full');
      await pumpAppearance(tester);

      await tester.tap(find.byTooltip('Use the Graphite theme'));
      await tester.pumpAndSettle();

      expect(find.text('Appearance not saved: disk full'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a failing streak says so once, for the last write', (
      tester,
    ) async {
      backend.failWrites = const SettingsBackendException('disk full');
      backend.holdAppearance = Completer<void>();
      await pumpAppearance(tester);

      await tester.tap(find.byTooltip('Use the Graphite theme'));
      await tester.pump();
      await tester.tap(find.byTooltip('Use the Paper theme'));
      await tester.pump();
      backend.holdAppearance!.complete();
      await tester.pumpAndSettle();

      expect(backend.appearances, hasLength(2));
      expect(find.text('Appearance not saved: disk full'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
