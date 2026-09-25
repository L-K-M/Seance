import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/settings_backend.dart';
import 'package:seance_app/services/settings_window.dart';
import 'package:seance_app/theme/app_appearance.dart';
import 'package:seance_app/theme/theme_presets.dart';
import 'package:seance_app/ui/sync_enrollment_validation.dart';
import 'package:seance_app/ui/terminal_appearance.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

// One engine in a test, so the two ends of the link get a channel each and a
// relay between them stands in for the runners' byte-for-byte forwarding.
const _appLink = MethodChannel('test/settings_link/app');
const _windowLink = MethodChannel('test/settings_link/window');
const _control = MethodChannel('test/settings_window');

/// The settings window's link, end to end: [SettingsWindowHost] in the app,
/// [RemoteSettingsBackend] in the window, and the runner's relay between
/// them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late AppServices services;
  late AppState state;
  late SettingsWindowHost host;
  late List<String> controlCalls;

  /// Deliver what one end sends to the other end's handler, and its reply
  /// back — what the runners do between the two engines.
  void relay(MethodChannel from, MethodChannel to) {
    messenger.setMockMessageHandler(from.name, (message) {
      final reply = Completer<ByteData?>();
      ServicesBinding.instance.channelBuffers.push(
        to.name,
        message,
        reply.complete,
      );
      return reply.future;
    });
  }

  /// What the runner says when the user closes the window.
  Future<void> nativeClosed() async {
    final reply = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      _control.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('closed')),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-window-');
    messenger.setMockMethodCallHandler(
      _pathChannel,
      (call) async => directory.path,
    );
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services);
    relay(_appLink, _windowLink);
    relay(_windowLink, _appLink);
    controlCalls = [];
    messenger.setMockMethodCallHandler(_control, (call) async {
      controlCalls.add(call.method);
      return null;
    });
    host = SettingsWindowHost(state, control: _control, link: _appLink);
  });

  tearDown(() async {
    host.dispose();
    state.dispose();
    await services.probe.dispose();
    for (final channel in [_appLink, _windowLink]) {
      messenger.setMockMessageHandler(channel.name, null);
    }
    messenger.setMockMethodCallHandler(_control, null);
    messenger.setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  /// Open Settings on [tab] and start the window's side, as the runner does
  /// on the first open.
  Future<RemoteSettingsBackend> openWindow([
    SettingsTab tab = SettingsTab.general,
  ]) async {
    expect(await host.open(tab), isTrue);
    return RemoteSettingsBackend.connect(link: _windowLink);
  }

  test('hello brings the settings and the tab it was opened on', () async {
    services.settings.terminalFontSize = 17;
    final window = await openWindow(SettingsTab.sync);
    addTearDown(window.dispose);

    expect(controlCalls, ['open']);
    expect(host.connected, isTrue);
    expect(host.visible, isTrue);
    expect(window.page.value?.tab, SettingsTab.sync);
    expect(window.settings.terminalFontSize, 17);
    expect(window.llmConfigVersion, state.llmConfigVersion);
  });

  test('a write from the window lands in the app and on disk', () async {
    final window = await openWindow();
    addTearDown(window.dispose);

    await window.setTerminalAppearance(
      fontSize: 20,
      fontFamily: 'Mono Test',
      palette: TerminalPalette.alwaysDark,
    );

    expect(services.settings.terminalFontSize, 20);
    expect(services.settings.terminalFontFamily, 'Mono Test');
    final reread = await services.settingsStore.load();
    expect(reread.terminalPalette, TerminalPalette.alwaysDark);
  });

  test('a theme set in the window re-themes the app and the window', () async {
    final window = await openWindow();
    addTearDown(window.dispose);
    expect(window.appearance.value, AppAppearance.initial);
    final palette = ThemePresets.bubblegum.copyWith(cornerScale: 0.35);

    await window.setAppearance(palette, ThemeModePreference.light);

    expect(state.appearance.value.palette, palette);
    expect(state.appearance.value.mode, ThemeModePreference.light);
    expect((await services.settingsStore.load()).themePalette, palette);
    // The window's own theme follows through the snapshot that write sent.
    await pumpEventQueue();
    expect(
      window.appearance.value,
      AppAppearance(palette: palette, mode: ThemeModePreference.light),
    );
  });

  test('a snapshot that moves no theme leaves the window\'s alone', () async {
    final window = await openWindow();
    addTearDown(window.dispose);
    var rethemed = 0;
    window.appearance.addListener(() => rethemed++);

    services.settings.terminalFontSize = 21;
    state.terminalAppearanceChanged();
    await pumpEventQueue();

    expect(window.settings.terminalFontSize, 21);
    expect(rethemed, 0);
  });

  test('results cross back intact', () async {
    final window = await openWindow();
    addTearDown(window.dispose);

    final result = await window.saveAssistant(
      AssistantDraft(
        fields: AssistantFields.of(window.settings),
        llmApiKey: 'sk-typed',
        zaiApiKey: '',
        versionSeen: window.llmConfigVersion,
      ),
    );

    expect(result.status, AssistantSaveStatus.saved);
    expect(result.keysStored, isTrue);
    expect(result.version, state.llmConfigVersion);
    expect(await services.masterKeys.getApiKey('anthropic'), 'sk-typed');
  });

  test('a failure in the app reaches the window with its message', () async {
    final window = await openWindow();
    addTearDown(window.dispose);

    await expectLater(
      window.enrollSync(
        const SyncEnrollment(
          mode: SyncEnrollmentMode.login,
          baseUrl: 'https://sync.invalid',
          username: 'me',
          password: 'pw',
          encryptionPassphrase: 'passphrase',
        ),
      ),
      throwsA(
        isA<SettingsBackendException>().having(
          (e) => e.message,
          'message',
          isNotEmpty,
        ),
      ),
    );
  });

  test('the app sends a snapshot when its state changes', () async {
    final window = await openWindow();
    addTearDown(window.dispose);
    var notified = 0;
    window.addListener(() => notified++);

    services.settings.terminalFontSize = 22;
    state.terminalAppearanceChanged();
    await pumpEventQueue();

    expect(window.settings.terminalFontSize, 22);
    expect(notified, 1);

    // A change the window does not show is not sent again.
    state.terminalAppearanceChanged();
    await pumpEventQueue();
    expect(notified, 1);
  });

  test('closing hides the screen; opening again shows a fresh one', () async {
    final window = await openWindow();
    addTearDown(window.dispose);
    final first = window.page.value!;

    await nativeClosed();
    await pumpEventQueue();

    expect(host.visible, isFalse);
    expect(host.connected, isTrue);
    expect(window.page.value, isNull);

    // Nothing is sent to a hidden window…
    services.settings.terminalFontSize = 9;
    state.terminalAppearanceChanged();
    await pumpEventQueue();
    expect(window.settings.terminalFontSize, isNot(9));

    // …and showing it again carries the settings as they are by then.
    expect(await host.open(SettingsTab.files), isTrue);

    expect(controlCalls, ['open', 'open']);
    expect(host.visible, isTrue);
    final second = window.page.value!;
    expect(second.tab, SettingsTab.files);
    expect(second.generation, isNot(first.generation));
    expect(window.settings.terminalFontSize, 9);
  });

  test('opening a showing window switches its tab', () async {
    final window = await openWindow();
    addTearDown(window.dispose);
    final tabs = <SettingsTab>[];
    final subscription = window.tabRequests.listen(tabs.add);
    addTearDown(subscription.cancel);

    expect(await host.open(SettingsTab.assistant), isTrue);
    await pumpEventQueue();

    expect(tabs, [SettingsTab.assistant]);
    expect(window.page.value?.generation, 0);
  });

  test('a request to quit is the app\'s to answer', () async {
    host.dispose();
    var asked = 0;
    host = SettingsWindowHost(
      state,
      control: _control,
      link: _appLink,
      requestAppExit: () async {
        asked++;
        return AppExitResponse.cancel;
      },
    );
    final window = await openWindow();
    addTearDown(window.dispose);

    expect(await window.requestAppExit(), AppExitResponse.cancel);
    expect(asked, 1);

    // With no app left to ask, quitting is not held up.
    messenger.setMockMessageHandler(_windowLink.name, (_) async => null);
    expect(await window.requestAppExit(), AppExitResponse.exit);
  });

  test('a window with no app to answer fails to connect', () async {
    messenger.setMockMessageHandler(_windowLink.name, (_) async => null);

    await expectLater(
      RemoteSettingsBackend.connect(link: _windowLink),
      throwsA(isA<SettingsBackendException>()),
    );
  });

  test(
    'a runner without the window reports it, for the route fallback',
    () async {
      messenger.setMockMethodCallHandler(_control, null);

      expect(await host.open(SettingsTab.general), isFalse);
    },
  );

  test(
    'a runner that could not create the window reports it, for the route',
    () async {
      messenger.setMockMethodCallHandler(_control, (call) async {
        throw PlatformException(code: 'open_failed');
      });

      expect(await host.open(SettingsTab.general), isFalse);
    },
  );
}
