import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/local_settings_backend.dart';
import 'package:seance_app/theme/app_appearance.dart';
import 'package:seance_app/theme/theme_presets.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Regression tests for the bootstrap structure. Two real bugs shipped here:
///  - AppScope lived below the Navigator, so the pushed Settings route
///    couldn't resolve it (grey screen in release);
///  - the fix for that swapped whole MaterialApps between bootstrap phases,
///    moving the global navigatorKey mid-frame (frozen spinner in release).
///
/// The real _init() hangs in the widget-test environment (its
/// platform-channel futures never complete under fake-async), so the tests
/// drive the phase transition through SeanceApp's initOverride seam.
void main() {
  testWidgets('bootstrap phase changes stay inside one MaterialApp',
      (tester) async {
    await tester.pumpWidget(
      SeanceApp(initOverride: () async => throw StateError('boom')),
    );
    // Spinner first, then the error phase. With a per-phase MaterialApp swap
    // this transition throws a duplicate-GlobalKey error in debug (and
    // freezes the frame in release builds).
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed to start Séance'), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('routes pushed on the root navigator can see AppScope',
      (tester) async {
    await tester.pumpWidget(
      SeanceApp(initOverride: () async => throw StateError('boom')),
    );
    await tester.pumpAndSettle();

    // The Settings screen is a pushed route; it resolves AppScope from a
    // context that lives directly under the Navigator, not under `home:`.
    late BuildContext routeContext;
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) {
          routeContext = context;
          return const SizedBox();
        },
      ),
    );
    await tester.pumpAndSettle();

    final scope = routeContext.dependOnInheritedWidgetOfExactType<AppScope>();
    expect(scope, isNotNull,
        reason: 'AppScope must wrap the Navigator so pushed routes see it');
  });

  // AppState notifies for every connection, probe and tab change; the
  // MaterialApp above the whole app must not rebuild for any of them, only
  // for the theme.
  testWidgets('the MaterialApp rebuilds for a theme change and nothing else', (
    tester,
  ) async {
    late Directory directory;
    late AppServices services;
    late AppState state;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-boot-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _pathChannel,
            (call) async => directory.path,
          );
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services);
    });
    addTearDown(() async {
      state.dispose();
      await services.probe.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathChannel, null);
      await directory.delete(recursive: true);
    });

    await tester.pumpWidget(SeanceApp(initOverride: () async => state));
    await tester.pump();
    await tester.pump();
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    final before = app();
    // A fresh settings file: a new device starts in Terminal.
    expect(before.theme?.colorScheme.surface, ThemePresets.terminal.surface);

    state.terminalAppearanceChanged();
    await tester.pump();
    expect(app(), same(before));

    await tester.runAsync(
      () => LocalSettingsBackend(state)
          .setAppearance(ThemePresets.solarized, ThemeModePreference.system),
    );
    await tester.pump();
    expect(app(), isNot(same(before)));
    expect(app().theme?.colorScheme.surface, ThemePresets.solarized.surface);
    // Unmount before the teardown disposes the state the shell watches.
    await tester.pumpWidget(const SizedBox());
  });
}
