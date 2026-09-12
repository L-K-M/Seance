import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/ui/server_grouping.dart';
import 'package:seance_app/ui/server_list_density.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The server list's two view options: the density switch in the app bar, and
/// pinning a server to the top.
///
/// Both are device-local preferences, so what is asserted here is the rendered
/// list and the in-memory settings the pane writes through — the JSON these
/// settle into is `app_settings_test.dart`'s job, and the sectioning rules are
/// `server_grouping_test.dart`'s.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    await services?.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    // Handles can linger briefly after dispose; the OS reaps system temp
    // dirs, so cleanup must not fail the suite.
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored.
    }
    // Cleared, not just disposed: `boot` assigns these one at a time, so a
    // throw partway through it would leave the *previous* test's disposed
    // instances here for the next tearDown to dispose a second time — which
    // throws, and buries the failure that actually mattered.
    state = null;
    services = null;
    directory = null;
  });

  ServerConfig server(String id, {String? group}) => ServerConfig(
    id: id,
    label: id,
    host: '$id.example.com',
    username: 'deploy',
    group: group,
    createdAt: 1,
    updatedAt: 1,
  );

  /// Stand up a real [AppServices] over a temp directory and file the given
  /// servers. `AppServices.initialize()` touches the disk, which a widget
  /// test's fake-async zone never completes — hence [WidgetTester.runAsync].
  Future<void> boot(WidgetTester tester, List<ServerConfig> servers) =>
      tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('seance-view-opts-');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              _pathChannel,
              (call) async => directory!.path,
            );
        FlutterSecureStorage.setMockInitialValues({});
        services = await AppServices.initialize();
        state = AppState(services!);
        for (final config in servers) {
          await state!.saveServer(config);
        }
      });

  Future<void> pumpPane(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(state: state!, child: ServerListPane(onOpen: (_) {})),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The row labels in the order they are drawn, which is the whole point of
  /// pinning and is not the order the store hands them over in.
  List<String> renderedLabels(WidgetTester tester) => tester
      .widgetList<ServerTile>(find.byType(ServerTile))
      .map((tile) => tile.server.label)
      .toList();

  group('density', () {
    testWidgets('compact rows are shorter than comfortable ones', (
      tester,
    ) async {
      await boot(tester, [server('alpha'), server('bravo')]);
      await pumpPane(tester);

      final comfortable = tester.getSize(find.byType(ServerTile).first).height;
      expect(
        find.text('deploy@alpha.example.com:22'),
        findsOneWidget,
        reason: 'the comfortable row spells the address out on its own line',
      );

      await tester.runAsync(
        () => state!.setServerListDensity(ServerListDensity.compact),
      );
      await tester.pumpAndSettle();

      final compact = tester.getSize(find.byType(ServerTile).first).height;
      expect(
        compact,
        lessThan(comfortable),
        reason: 'the point of the mode is fitting more servers in the same '
            'vertical space',
      );
      expect(
        find.text('deploy@alpha.example.com:22'),
        findsNothing,
        reason: 'the address line is what the compact row trades away',
      );
    });

    testWidgets('a compact row still tells a screen reader the address', (
      tester,
    ) async {
      await boot(tester, [server('alpha')]);
      await tester.runAsync(
        () => state!.setServerListDensity(ServerListDensity.compact),
      );
      await pumpPane(tester);

      // Read off the row's merged node, which is what a screen reader is
      // handed: dropping the second line must not drop the information.
      final semantics = tester.getSemantics(find.byType(ServerTile));
      expect(semantics.label, contains('alpha'));
      expect(semantics.label, contains('deploy@alpha.example.com:22'));
    });

    testWidgets('the app-bar menu switches density and records the choice', (
      tester,
    ) async {
      await boot(tester, [server('alpha')]);
      await pumpPane(tester);

      expect(find.byIcon(Icons.density_medium), findsOneWidget);
      await tester.tap(find.byIcon(Icons.density_medium));
      await tester.pumpAndSettle();
      // The menu item, not its label: a CheckedPopupMenuItem puts the text
      // inside an ignore-pointer ListTile, so tapping the paragraph lands on
      // the item by luck rather than by hit test.
      await tester.tap(
        find.widgetWithText(
          CheckedPopupMenuItem<ServerListDensity>,
          ServerListDensity.compact.label,
        ),
      );
      await tester.pumpAndSettle();

      expect(state!.serverListDensity, ServerListDensity.compact);
      expect(
        services!.settings.serverListDensity,
        ServerListDensity.compact,
        reason: 'the choice has to reach the settings the next launch loads',
      );
      // The button reflects what the list is now doing, so the mode is
      // readable without counting row heights.
      expect(find.byIcon(Icons.density_small), findsOneWidget);
    });
  });

  group('pinning', () {
    testWidgets('the row menu pins a server to the top of the list', (
      tester,
    ) async {
      await boot(tester, [server('alpha'), server('zulu')]);
      await pumpPane(tester);
      expect(renderedLabels(tester), ['alpha', 'zulu']);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('zulu')),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin to top'));
      await tester.pumpAndSettle();

      expect(state!.pinnedServerIds, {'zulu'});
      expect(renderedLabels(tester), ['zulu', 'alpha']);
      // Both sections are headed, or the rows after the shortlist would read
      // as still being part of it.
      expect(find.text(kPinnedLabel), findsOneWidget);
      expect(find.text(kUnpinnedLabel), findsOneWidget);
    });

    testWidgets('the same menu unpins, and the list goes back', (
      tester,
    ) async {
      await boot(tester, [server('alpha'), server('zulu')]);
      await tester.runAsync(() => state!.toggleServerPin('zulu'));
      await pumpPane(tester);
      expect(renderedLabels(tester), ['zulu', 'alpha']);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('zulu')),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Pin to top'),
        findsNothing,
        reason: 'a pinned row offers the other half of the toggle',
      );
      await tester.tap(find.text('Unpin'));
      await tester.pumpAndSettle();

      expect(state!.pinnedServerIds, isEmpty);
      expect(renderedLabels(tester), ['alpha', 'zulu']);
      expect(find.text(kPinnedLabel), findsNothing);
    });

    testWidgets('a pinned server leaves its group for the shortlist', (
      tester,
    ) async {
      await boot(tester, [
        server('db', group: 'Production'),
        server('web', group: 'Production'),
      ]);
      await tester.runAsync(() => state!.toggleServerPin('web'));
      await pumpPane(tester);

      expect(renderedLabels(tester), ['web', 'db']);
      final headers = tester
          .widgetList<ServerGroupHeader>(find.byType(ServerGroupHeader))
          .toList();
      expect(headers.map((h) => h.name), [kPinnedLabel, 'Production']);
      // The group's count is what is left in it — one, not two — so folding
      // it away never claims to hide the row sitting at the top of the list.
      expect(headers.map((h) => h.count), [1, 1]);
    });

    testWidgets('deleting a server takes its pin with it', (tester) async {
      await boot(tester, [server('alpha'), server('zulu')]);
      await tester.runAsync(() async {
        await state!.toggleServerPin('zulu');
        expect(services!.settings.pinnedServerIds, {'zulu'});
        await state!.deleteServer('zulu');
      });

      expect(
        services!.settings.pinnedServerIds,
        isEmpty,
        reason: 'a pin that names no server would linger in settings forever',
      );
    });

    testWidgets('Enter opens the first row shown, not the first stored', (
      tester,
    ) async {
      // Enough servers for the filter field to appear at all.
      await boot(tester, [
        for (final name in ['alpha', 'bravo', 'delta', 'echo', 'zulu'])
          server(name),
      ]);
      await tester.runAsync(() => state!.toggleServerPin('zulu'));

      ServerConfig? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(
            state: state!,
            child: ServerListPane(onOpen: (s) => opened = s),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Matches every server; the pinned one is the row the eye lands on.
      await tester.enterText(find.byType(TextField), 'example.com');
      await tester.pumpAndSettle();
      expect(renderedLabels(tester).first, 'zulu');

      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(opened?.label, 'zulu');
    });
  });
}
