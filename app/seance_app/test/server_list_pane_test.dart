import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/app_menus.dart';
import 'package:seance_app/ui/server_grouping.dart';
import 'package:seance_app/ui/server_list_density.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_app/ui/server_status_dot.dart';
import 'package:seance_app/ui/server_tile.dart';
import 'package:seance_app/ui/sidebar/sidebar_kit.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// A session the app believes is open, without a network.
class _OpenSshSession implements SshSession {
  _OpenSshSession(this.engine);

  @override
  final TerminalEngine engine;

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => engine.dispose();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The pane in its two postures: the desktop rail (the sibling sidebar
/// anatomy, Poltergeist's plan 10 §5) and the phone home (§9), whose
/// floating "+" shares a Scaffold with the list, so anything the list
/// scrolls under the button must stay reachable.
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

  /// A real [AppServices] over a temp directory, which touches the disk — a
  /// widget test's fake-async zone never completes that, hence runAsync.
  Future<void> boot(WidgetTester tester, List<ServerConfig> servers) =>
      tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('seance-list-pane-');
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

  /// The rail as the wide layout mounts it, on a desktop theme.
  Future<void> pumpRail(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.macOS,
    void Function(ServerConfig)? onOpen,
  }) async {
    tester.view.physicalSize = const Size(300, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: platform),
        home: AppScope(
          state: state!,
          child: AppMenus(
            child: ServerListPane(
              posture: ServerListPosture.rail,
              onOpen: onOpen ?? (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> rendered(WidgetTester tester) => tester
      .widgetList<ServerTile>(find.byType(ServerTile))
      .map((tile) => tile.server.label)
      .toList();

  testWidgets('the phone home draws the Android list; compact density keeps '
      'one-line touch rows; a desktop window stays rail-drawn', (
    tester,
  ) async {
    await boot(tester, [server('web')]);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> pumpHome(TargetPlatform platform) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SeanceTheme.light(platform: platform),
          home: AppScope(
            state: state!,
            child: ServerListPane(
              posture: ServerListPosture.home,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    double rowHeight() => tester.getSize(find.byType(SidebarRow)).height;
    double markSize() => tester.getSize(find.byType(ServerRailMark)).width;

    // The default comfortable density: Poltergeist's Home list (§10.6).
    await pumpHome(TargetPlatform.android);
    expect(rowHeight(), 56);
    expect(markSize(), 40);
    expect(find.text('deploy@web.example.com'), findsOneWidget);

    await tester.runAsync(
      () => state!.setServerListDensity(ServerListDensity.compact),
    );
    await tester.pumpAndSettle();
    expect(rowHeight(), 48);
    expect(markSize(), lessThan(40));

    await tester.runAsync(
      () => state!.setServerListDensity(ServerListDensity.comfortable),
    );
    await pumpHome(TargetPlatform.linux);
    expect(markSize(), lessThan(40));
  });

  testWidgets('the last row\'s menu is tappable at the deepest scroll '
      '(the home screen\'s "+" must not cover it)', (tester) async {
    // Enough rows to force scrolling on the 800x600 test surface.
    // Zero-padded ids because the list sorts by label: "box19" would sort
    // before "box9" and the last row would not be the one named last.
    await boot(tester, [
      for (var i = 0; i < 20; i++) server('box${i.toString().padLeft(2, '0')}'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state!,
          child: ServerListPane(
            posture: ServerListPosture.home,
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Settled steps until the list rests exactly at its real max extent —
    // the premise of this test is "deepest scroll", not a fixed drag budget.
    // Scoped under the ListView because the filter TextField has its own
    // Scrollable too.
    final scrollPosition = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(
      scrollPosition.maxScrollExtent,
      greaterThan(0),
      reason:
          'the list must overflow the viewport for this test to '
          'be meaningful',
    );
    var dragsLeft = 50;
    while (scrollPosition.pixels < scrollPosition.maxScrollExtent) {
      if (dragsLeft-- == 0) {
        fail(
          'List never settled at maxScrollExtent '
          '(${scrollPosition.pixels}/${scrollPosition.maxScrollExtent}).',
        );
      }
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
    }

    final lastMenu = find.descendant(
      of: find.byKey(const ValueKey('box19')),
      matching: find.byTooltip(serverSidebarStrings.rowMenu),
    );
    expect(tester.any(lastMenu), isTrue, reason: 'last row is scrolled in');

    // Assert the guard itself, not just a lucky center-tap: the floating
    // button must be in the tree and must sit strictly below the last row's
    // menu, otherwise this test passes even when the clearance is wrong.
    final addButton = find.byType(FloatingActionButton);
    expect(
      addButton,
      findsOneWidget,
      reason:
          'without the "+" button in the tree, no widget can intercept '
          'the tap and this test cannot fail',
    );
    expect(
      tester.getTopLeft(addButton).dy,
      greaterThan(tester.getBottomLeft(lastMenu).dy),
    );

    await tester.tap(lastMenu);
    await tester.pumpAndSettle();

    // If the button had covered the menu, this tap would have opened the
    // server editor instead of the row's verbs.
    expect(find.text('Duplicate'), findsOneWidget);
  });

  group('the rail', () {
    testWidgets('has no app bar; the bottom bar carries +, sync and gear', (
      tester,
    ) async {
      await boot(tester, [server('alpha')]);
      await pumpRail(tester);

      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      final bar = find.byType(SidebarBottomBar);
      expect(tester.getSize(bar).height, 30);
      // Sync is not set up on a fresh install.
      expect(find.text('Sync off'), findsOneWidget);
      expect(find.byTooltip('Sync & settings'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('servers.add')));
      await tester.pumpAndSettle();
      expect(find.text('New server…'), findsOneWidget);
      expect(find.text('Import SSH config…'), findsOneWidget);
      // Groups are a field on a server, not a thing of their own: there is
      // no "New group" to make.
      expect(
        find.textContaining(RegExp('group', caseSensitive: false)),
        findsNothing,
      );
    });

    testWidgets('sections: PINNED, then SERVERS with its groups nested', (
      tester,
    ) async {
      await boot(tester, [
        server('db', group: 'Production'),
        server('web', group: 'Production'),
        server('loose'),
        server('zulu'),
      ]);
      await tester.runAsync(() => state!.toggleServerPin('zulu'));
      await pumpRail(tester);

      expect(find.text('PINNED'), findsOneWidget);
      expect(find.text('SERVERS'), findsOneWidget);
      expect(rendered(tester), ['zulu', 'loose', 'db', 'web']);
      final nested = tester
          .widgetList<SidebarSectionHeader>(find.byType(SidebarSectionHeader))
          .where((h) => h.nested)
          .map((h) => h.title);
      expect(nested, ['Production']);
      expect(
        tester
            .widgetList<ServerTile>(find.byType(ServerTile))
            .map((t) => t.depth),
        [0, 0, 1, 1],
      );
    });

    testWidgets('folding a group persists and a query looks inside it', (
      tester,
    ) async {
      await boot(tester, [
        for (final name in ['a', 'b', 'c', 'd', 'e', 'f'])
          server(name, group: 'Production'),
        server('x'),
        server('y'),
      ]);
      await pumpRail(tester);
      await tester.tap(find.text('Production'));
      await tester.pumpAndSettle();
      final key = serverGroupKey('Production');
      expect(state!.collapsedServerGroups, {key});
      expect(services!.settings.collapsedServerGroups, {
        key,
      }, reason: 'the fold has to reach the settings the next launch loads');
      expect(rendered(tester), ['x', 'y']);
      // The count shows only while collapsed.
      expect(find.text('6'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('servers.filter.field')),
        'b',
      );
      await tester.pumpAndSettle();
      expect(rendered(tester), ['b']);
      expect(find.text('1 of 8 · ↵ opens the first'), findsOneWidget);
    });

    testWidgets('the filter shows at five servers, not before', (tester) async {
      final field = find.byKey(const ValueKey('servers.filter.field'));
      await boot(tester, [
        for (final name in ['a', 'b', 'c', 'd']) server(name),
      ]);
      await pumpRail(tester);
      expect(field, findsNothing);

      await tester.runAsync(() => state!.saveServer(server('e')));
      await tester.pumpAndSettle();
      expect(field, findsOneWidget);
    });

    testWidgets('the count says what Enter does, and only when there is '
        'something to open', (tester) async {
      await boot(tester, [
        for (final name in ['alpha', 'bravo', 'charlie', 'delta', 'echo'])
          server(name),
      ]);
      await pumpRail(tester);
      final field = find.byKey(const ValueKey('servers.filter.field'));

      await tester.enterText(field, 'ha');
      await tester.pumpAndSettle();
      expect(find.text('2 of 5 · ↵ opens the first'), findsOneWidget);

      await tester.enterText(field, 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('0 of 5'), findsOneWidget);
    });

    for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
      testWidgets('the chord reveals the filter below the threshold, and Esc '
          'puts it away (${platform.name})', (tester) async {
        final field = find.byKey(const ValueKey('servers.filter.field'));
        await boot(tester, [server('alpha'), server('bravo')]);
        await pumpRail(tester, platform: platform);
        expect(field, findsNothing);

        // Focus somewhere in the app, as a real window always has.
        await tester.tap(find.text('alpha'));
        await tester.pump();
        final apple = platform == TargetPlatform.macOS;
        final modifier = apple
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
        expect(field, findsOneWidget);
        expect(
          tester.widget<TextField>(field).focusNode?.hasFocus,
          isTrue,
          reason: 'the chord is for typing straight away',
        );

        await tester.enterText(field, 'bra');
        await tester.pumpAndSettle();
        expect(rendered(tester), ['bravo']);
        // Esc clears first, then closes.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(rendered(tester), ['alpha', 'bravo']);
        expect(field, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(field, findsNothing);
      });
    }

    testWidgets('with nothing to filter a reveal is refused, and does not '
        'pop the field open once the first server arrives', (tester) async {
      final field = find.byKey(const ValueKey('servers.filter.field'));
      await boot(tester, []);
      await pumpRail(tester);

      expect(
        ServerListPane.revealFilter(),
        isFalse,
        reason: 'the chord found nothing to reveal and must say so',
      );
      await tester.pumpAndSettle();
      expect(field, findsNothing);

      await tester.runAsync(() => state!.saveServer(server('alpha')));
      await tester.pumpAndSettle();
      expect(
        field,
        findsNothing,
        reason: 'a refused reveal must not latch the field open for later',
      );
    });

    testWidgets('Windows leaves AltGr+F to text input: AltGr arrives as '
        'Ctrl + right Alt, and "[" is AltGr+F on Czech and other layouts', (
      tester,
    ) async {
      final field = find.byKey(const ValueKey('servers.filter.field'));
      await boot(tester, [server('alpha'), server('bravo')]);
      await pumpRail(tester, platform: TargetPlatform.windows);
      await tester.tap(find.text('alpha'));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      final result = await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(result, isFalse, reason: 'unhandled, so the character types');

      // The real chord, with the left Alt, still reveals the filter.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(field, findsOneWidget);
    });

    testWidgets('the row of the focused session wears the pill', (
      tester,
    ) async {
      await boot(tester, [server('alpha'), server('bravo')]);
      final tab = TerminalSession(
        id: 'tab',
        serverId: 'bravo',
        config: state!.servers.last,
        engine: XtermTerminalEngine(),
      );
      state!
        ..tabs.add(tab)
        ..activeTabId = 'tab';
      await pumpRail(tester);
      final selected = {
        for (final tile in tester.widgetList<ServerTile>(
          find.byType(ServerTile),
        ))
          tile.server.label: tile.selected,
      };
      expect(selected, {'alpha': false, 'bravo': true});
    });

    testWidgets('a session refused at a changed host key marks its row '
        'blocked, not merely failed', (tester) async {
      await boot(tester, [server('alpha'), server('bravo')]);
      TerminalSession failed(String id, String serverId) => TerminalSession(
        id: id,
        serverId: serverId,
        config: state!.servers.firstWhere((s) => s.id == serverId),
        engine: XtermTerminalEngine(),
        connecting: false,
        error: 'SSH error connecting',
      );
      state!.tabs.addAll([
        failed('t1', 'alpha')..hostKeyBlocked = true,
        failed('t2', 'bravo'),
      ]);
      await pumpRail(tester);
      final dots = {
        for (final tile in tester.widgetList<ServerTile>(
          find.byType(ServerTile),
        ))
          tile.server.label: tile.dot,
      };
      expect(dots, {'alpha': ServerDot.blocked, 'bravo': ServerDot.failed});
    });

    testWidgets('a folded group or a filter keeps a live connection in '
        'view, as a dot on the header that hides it', (tester) async {
      await boot(tester, [
        server('db', group: 'Production'),
        server('web', group: 'Production'),
        server('alpha'),
        server('bravo'),
      ]);
      final tab = TerminalSession(
        id: 't',
        serverId: 'db',
        config: state!.servers.firstWhere((s) => s.id == 'db'),
        engine: XtermTerminalEngine(),
        connecting: false,
      );
      tab.session = _OpenSshSession(tab.engine);
      state!.tabs.add(tab);
      await pumpRail(tester);
      final online = StatusColors.online(
        tester.element(find.byType(ServerListPane)),
      );
      SidebarStatusDot? dotOn(String key) =>
          tester.widget<SidebarSectionHeader>(find.byKey(ValueKey(key))).status;
      final production = 'servers.group.${serverGroupKey('Production')}';
      const servers = 'servers.section.$kServersKey';

      // In view, the row carries its own dot; the headers carry none.
      expect(dotOn(production), isNull);
      expect(dotOn(servers), isNull);

      await tester.tap(find.text('Production'));
      await tester.pumpAndSettle();
      expect(dotOn(production)?.color, online);
      expect(
        dotOn(servers),
        isNull,
        reason: 'the group row already shows it; SERVERS would say it twice',
      );

      await tester.tap(find.text('Production'));
      await tester.pumpAndSettle();
      expect(ServerListPane.revealFilter(), isTrue);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('servers.filter.field')),
        'alpha',
      );
      await tester.pumpAndSettle();
      // The filter dropped db and its group's row: SERVERS holds the dot.
      expect(find.text('Production'), findsNothing);
      expect(dotOn(servers)?.color, online);
    });

    testWidgets('the sync chip says what sync is doing', (tester) async {
      await boot(tester, [server('alpha')]);
      services!.settings.syncBaseUrl = 'https://sync.example.com';
      state!.lastSyncAt = DateTime.now().subtract(const Duration(minutes: 2));
      await pumpRail(tester);
      expect(find.text('Synced · 2 min'), findsOneWidget);

      state!
        ..syncing = true
        ..notifyListeners();
      await tester.pump();
      expect(find.text('Syncing…'), findsOneWidget);

      state!
        ..syncing = false
        ..lastSyncError = 'Connection refused'
        ..notifyListeners();
      await tester.pump();
      expect(find.text('Sync failed'), findsOneWidget);
      // A click retries rather than leading off to settings.
      final chip = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Sync failed'),
          matching: find.byType(TextButton),
        ),
      );
      expect(chip.onPressed, isNotNull);
      expect(find.byTooltip('Connection refused\nClick to retry'), findsOne);
    });

    testWidgets('right-click pins; the row moves to PINNED', (tester) async {
      await boot(tester, [server('alpha'), server('zulu')]);
      await pumpRail(tester);
      expect(rendered(tester), ['alpha', 'zulu']);

      await tester.tap(
        find.text('zulu'),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin to top'));
      await tester.pumpAndSettle();
      expect(state!.pinnedServerIds, {'zulu'});
      expect(rendered(tester), ['zulu', 'alpha']);
      expect(find.text('PINNED'), findsOneWidget);
    });

    testWidgets('the arrows and Tab get past the SERVERS header and its +', (
      tester,
    ) async {
      await boot(tester, [server('alpha'), server('zulu')]);
      final opened = <String>[];
      await pumpRail(tester, onOpen: (config) => opened.add(config.id));
      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      opened.clear();

      // Up lands on the header (its "+" drawn for the keyboard); Down
      // comes straight back to the row rather than bouncing off the "+".
      await press(LogicalKeyboardKey.arrowUp);
      await press(LogicalKeyboardKey.arrowDown);
      await press(LogicalKeyboardKey.enter);
      expect(opened, ['alpha']);
      opened.clear();

      // Tab takes the header's "+" as a stop of its own, then the row.
      await press(LogicalKeyboardKey.arrowUp);
      await press(LogicalKeyboardKey.tab);
      final add = find.descendant(
        of: find.byKey(const ValueKey('servers.section.add')),
        matching: find.byIcon(Icons.add),
      );
      expect(Focus.of(tester.element(add)).hasPrimaryFocus, isTrue);
      await press(LogicalKeyboardKey.tab);
      await press(LogicalKeyboardKey.enter);
      expect(opened, ['alpha']);
    });

    testWidgets('a row\'s verbs reach a screen reader', (tester) async {
      final semantics = tester.ensureSemantics();
      await boot(tester, [server('alpha')]);
      await pumpRail(tester);

      // Its verbs are the row's own semantics actions, pointer or not; a
      // verb greyed out in the menu is not offered.
      final row = find.semantics.byLabel(RegExp(r'^alpha, '));
      final ids = row
          .evaluate()
          .single
          .getSemanticsData()
          .customSemanticsActionIds;
      final labels = [
        for (final id in ids ?? const <int>[])
          CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(labels, [
        'Connect',
        'Connect in new tab',
        'Pin to top',
        'Edit…',
        'Duplicate',
        'Delete…',
      ]);
      tester.semantics.customAction(
        row,
        const CustomSemanticsAction(label: 'Pin to top'),
      );
      await tester.pumpAndSettle();
      expect(state!.pinnedServerIds, {'alpha'});

      // And an open menu's verbs are nodes a screen reader can reach.
      await tester.tap(
        find.text('alpha'),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.semantics.byLabel('Duplicate'), findsOne);
      semantics.dispose();
    });

    testWidgets('no servers: the onboarding state, with no filter', (
      tester,
    ) async {
      await boot(tester, []);
      await pumpRail(tester);
      expect(find.text('No servers yet'), findsOneWidget);
      expect(find.text('New server'), findsOneWidget);
      expect(find.text('Import SSH config'), findsOneWidget);
      expect(find.byKey(const ValueKey('servers.filter.field')), findsNothing);
    });
  });
}
