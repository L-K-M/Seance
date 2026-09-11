import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Layout regressions of the pane itself: the floating Add-server button and
/// the list share one Scaffold, so anything the list scrolls under the button
/// must stay reachable.
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
    // Handles can linger briefly after dispose (notably on Windows CI); the
    // OS reaps system temp dirs, so cleanup must not fail the suite.
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored.
    }
  });

  ServerConfig server(String id) => ServerConfig(
        id: id,
        label: id,
        host: '$id.example.com',
        username: 'deploy',
        createdAt: 1,
        updatedAt: 1,
      );

  testWidgets(
      'the last row menu is tappable at the deepest scroll '
      '(the Add-server button must not cover it)', (tester) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-list-pane-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              _pathChannel, (call) async => directory!.path);
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      // Enough rows to force scrolling on the 800x600 test surface.
      // Zero-padded ids because the list sorts by label: "box19" would sort
      // before "box9" and the last row would not be the one named last.
      for (var i = 0; i < 20; i++) {
        await state!.saveServer(server('box${i.toString().padLeft(2, '0')}'));
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(state: state!, child: ServerListPane(onOpen: (_) {})),
      ),
    );
    await tester.pumpAndSettle();

    // Settled steps until the list rests exactly at its real max extent —
    // the premise of this test is "deepest scroll", not a fixed drag budget.
    // Scoped under the ListView because the filter TextField has its own
    // Scrollable too.
    final scrollPosition = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    ).position;
    expect(scrollPosition.maxScrollExtent, greaterThan(0),
        reason: 'the list must overflow the viewport for this test to '
            'be meaningful');
    var dragsLeft = 50;
    while (scrollPosition.pixels < scrollPosition.maxScrollExtent) {
      if (dragsLeft-- == 0) {
        fail('List never settled at maxScrollExtent '
            '(${scrollPosition.pixels}/${scrollPosition.maxScrollExtent}).');
      }
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
    }

    final lastMenu = find.descendant(
      of: find.byKey(const ValueKey('box19')),
      matching: find.byType(PopupMenuButton<String>),
    );
    expect(tester.any(lastMenu), isTrue, reason: 'last row is scrolled in');

    // Assert the guard itself, not just a lucky center-tap: the floating
    // button must be in the tree and must sit strictly below the last row's
    // menu, otherwise this test passes even when the clearance is wrong.
    final addButton = find.byType(FloatingActionButton);
    expect(addButton, findsOneWidget,
        reason: 'without the Add-server button in the tree, no widget can '
            'intercept the tap and this test cannot fail');
    expect(tester.getTopLeft(addButton).dy,
        greaterThan(tester.getBottomLeft(lastMenu).dy));

    await tester.tap(lastMenu);
    await tester.pumpAndSettle();

    // If the button had covered the menu, this tap would have opened the
    // server editor ("Add server") instead of the row's menu.
    expect(find.text('Duplicate'), findsOneWidget);
  });
}
