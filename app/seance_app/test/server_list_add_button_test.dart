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

/// The floating "Add server" button is painted over the list, and nothing in
/// [Scaffold] reserves room for it. Scrolled to the end, the last row used to
/// sit underneath it with its three-dot menu unreachable — the button swallowed
/// every tap aimed at it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  late AppState state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-add-button-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    state.dispose();
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  /// Brings up the pane over real services with [count] servers in it.
  ///
  /// The services and the seeding run inside [WidgetTester.runAsync]: both do
  /// genuine file I/O, which completes on the real event loop and would never
  /// be reached from inside the test's fake-async zone.
  ///
  /// [count] is chosen so the list overflows the viewport set below and the
  /// last row can only be reached by scrolling to the very end.
  Future<void> pump(WidgetTester tester, {required int count}) async {
    await tester.runAsync(() async {
      services = await AppServices.initialize();
      state = AppState(services);
      for (var i = 0; i < count; i++) {
        await state.saveServer(
          ServerConfig(
            id: 'srv-$i',
            // Zero-padded so the stored order matches the list's own
            // alphabetical one and the last row is predictable.
            label: 'box-${i.toString().padLeft(2, '0')}',
            host: 'host$i.example.com',
            username: 'deploy',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
      }
    });

    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(state: state, child: ServerListPane(onOpen: (_) {})),
      ),
    );
    await tester.pump();
  }

  testWidgets('the last row keeps its menu when the list is scrolled home', (
    tester,
  ) async {
    await pump(tester, count: 12);

    // To the very end of the list, where the button floats.
    await tester.fling(find.byType(ListView), const Offset(0, -2000), 2000);
    await tester.pumpAndSettle();
    expect(find.text('box-11'), findsOneWidget);

    final menu = find.descendant(
      of: find.ancestor(
        of: find.text('box-11'),
        matching: find.byType(ListTile),
      ),
      matching: find.byType(PopupMenuButton<String>),
    );
    expect(menu, findsOneWidget);

    // The assertion that actually pins the bug: the button's painted rect must
    // not cover the menu. A tap alone would not be enough — WidgetTester.tap
    // sends the pointer at the target's center whatever is on top of it, and
    // `warnIfMissed` only checks that *something* was hit there, so the FAB
    // absorbing it still reads as a hit.
    expect(
      tester.getRect(find.byType(FloatingActionButton)).overlaps(
        tester.getRect(menu),
      ),
      isFalse,
      reason: 'the "Add server" button must not sit on the last row',
    );

    // And the tap really does reach the menu rather than the button.
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Duplicate'), findsOneWidget);
  });

  testWidgets('the reserved extent covers the button the framework builds', (
    tester,
  ) async {
    await pump(tester, count: 3);

    // The height is a framework default this app cannot read back
    // (`_FABDefaultsM3`), so it is mirrored as a constant. Measuring the real
    // button here means a framework change fails the build instead of quietly
    // re-covering the last row.
    final button = tester.getSize(find.byType(FloatingActionButton));
    expect(
      ServerListPane.addButtonReservedExtent,
      greaterThanOrEqualTo(button.height + kFloatingActionButtonMargin),
    );
  });
}
