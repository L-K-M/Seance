import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/external_file_opener.dart';
import 'package:seance_app/services/settings_backend.dart';
import 'package:seance_app/services/system_fonts.dart';
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

  testWidgets('the sync status line follows the backend', (tester) async {
    await pumpScreen(tester, tab: SettingsTab.sync);
    expect(find.textContaining('Last sync failed'), findsNothing);

    backend
      ..syncStatus = const SyncStatus(lastSyncError: 'server down')
      ..notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('Last sync failed: server down'), findsOneWidget);
  });
}
