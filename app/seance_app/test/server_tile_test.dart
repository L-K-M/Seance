import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/middle_ellipsis_text.dart';
import 'package:seance_app/ui/server_appearance.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_app/ui/server_status_dot.dart';
import 'package:seance_app/ui/server_tile.dart';
import 'package:seance_app/ui/sidebar/sidebar_kit.dart';
import 'package:seance_core/seance_core.dart';

/// What a row in the server list says about itself: which one is selected,
/// what state it is in, which colour it carries, and which verbs it offers.
void main() {
  ServerConfig server({
    ServerColor? color,
    ServerIcon? icon,
    String? iconImage,
  }) => ServerConfig(
    id: 'box',
    label: 'box',
    host: 'box.example.com',
    username: 'deploy',
    color: color,
    icon: icon,
    iconImage: iconImage,
    createdAt: 1,
    updatedAt: 1,
  );

  /// Every callback, counted by name.
  final calls = <String>[];
  setUp(calls.clear);

  Future<void> pump(
    WidgetTester tester, {
    ServerConfig? config,
    ServerDot dot = ServerDot.none,
    bool selected = false,
    bool pinned = false,
    int tabCount = 0,
    bool connected = false,
    bool reconnectable = false,
    bool showAddress = false,
    TargetPlatform platform = TargetPlatform.macOS,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: platform),
        home: Scaffold(
          body: SidebarKitScope(
            strings: serverSidebarStrings,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 260,
                child: ServerTile(
                  server: config ?? server(),
                  dot: dot,
                  tabCount: tabCount,
                  selected: selected,
                  pinned: pinned,
                  showAddress: showAddress,
                  onOpen: () => calls.add('open'),
                  onNewTab: () => calls.add('newTab'),
                  onEdit: () => calls.add('edit'),
                  onDuplicate: () => calls.add('duplicate'),
                  onDelete: () => calls.add('delete'),
                  onTogglePin: () => calls.add('pin'),
                  onDisconnect: connected
                      ? () => calls.add('disconnect')
                      : null,
                  onReconnect: reconnectable
                      ? () => calls.add('reconnect')
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  TextStyle? titleStyle(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byType(MiddleEllipsisText),
          matching: find.byType(Text),
        ),
      )
      .style;

  /// The row's own pill: the decorated box directly under its margin.
  BoxDecoration? pill(WidgetTester tester) => tester
      .widgetList<Container>(
        find.descendant(
          of: find.byType(SidebarRow),
          matching: find.byType(Container),
        ),
      )
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((d) => d.shape == BoxShape.rectangle);

  testWidgets('one 26 px line on desktop: the name, no address line', (
    tester,
  ) async {
    await pump(tester);
    expect(tester.getSize(find.byType(SidebarRow)).height, 26);
    expect(find.text('box'), findsOneWidget);
    expect(find.text('deploy@box.example.com:22'), findsNothing);
    // Not lost: the tooltip carries it for a pointer.
    expect(find.byTooltip('deploy@box.example.com:22'), findsOneWidget);
  });

  testWidgets('the selected row wears the pill and a semibold title', (
    tester,
  ) async {
    await pump(tester, selected: true);
    final chrome = SeanceChrome.of(tester.element(find.byType(SidebarRow)));
    final markEdge = tester.getTopLeft(find.byType(ServerRailMark)).dx;
    expect(pill(tester)?.color, chrome.inactiveSelectionFill);
    expect(pill(tester)?.borderRadius, isNotNull);
    expect(titleStyle(tester)?.fontWeight, FontWeight.w600);

    await pump(tester);
    expect(pill(tester)?.color, isNull);
    expect(titleStyle(tester)?.fontWeight, FontWeight.w400);
    expect(
      tester.getTopLeft(find.byType(ServerRailMark)).dx,
      markEdge,
      reason: 'selecting a row must not shift its content',
    );
  });

  group('the mark', () {
    testWidgets('an uncoloured glyph draws alone, like the sibling rail', (
      tester,
    ) async {
      await pump(tester, config: server(icon: ServerIcon.database));
      expect(find.byType(ServerBadge), findsNothing);
      expect(find.byIcon(serverIconData(ServerIcon.database)), findsOneWidget);
    });

    testWidgets('a coloured server gets its badge, at the mark extent', (
      tester,
    ) async {
      await pump(tester, config: server(color: ServerColor.red));
      final badge = tester.widget<ServerBadge>(find.byType(ServerBadge));
      expect(badge.tint, const ServerTint(named: ServerColor.red));
      expect(badge.size, 18);

      // Touch rows are 48 dp and the mark grows with them.
      await pump(
        tester,
        config: server(color: ServerColor.red),
        platform: TargetPlatform.android,
      );
      expect(tester.widget<ServerBadge>(find.byType(ServerBadge)).size, 24);
    });

    testWidgets('a coloured image mark is framed in the colour', (
      tester,
    ) async {
      // An image covers the badge's fill, so without the frame the colour
      // would have nowhere to show at 18 px.
      final png = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawRect(
          const ui.Rect.fromLTWH(0, 0, 8, 8),
          ui.Paint()..color = const ui.Color(0xFF00FF00),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(8, 8);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        picture.dispose();
        image.dispose();
        return base64Encode(data!.buffer.asUint8List());
      });
      await pump(
        tester,
        config: server(color: ServerColor.red, iconImage: png),
      );
      final frame = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(ServerRailMark),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.position == DecorationPosition.foreground,
          ),
        ),
      );
      final border = (frame.decoration as BoxDecoration).border! as Border;
      expect(
        border.top.color,
        serverAccent(
          tester.element(find.byType(ServerRailMark)),
          const ServerTint(named: ServerColor.red),
        )!.line,
      );
    });
  });

  group('the dot', () {
    for (final dot in ServerDot.values) {
      testWidgets('$dot is drawn and announced', (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await pump(tester, dot: dot);
          final row = tester.widget<SidebarRow>(find.byType(SidebarRow));
          final context = tester.element(find.byType(SidebarRow));
          expect(row.status?.color, dot.color(context));
          if (row.status != null) expect(row.status!.style, dot.style);
          // Read off a widget inside the row's container node: getSemantics
          // walks up to the nearest node, which from the row widget itself
          // would be the route above it.
          final label = tester
              .getSemantics(
                find
                    .descendant(
                      of: find.byType(SidebarRow),
                      matching: find.byType(Listener),
                    )
                    .first,
              )
              .getSemanticsData()
              .label;
          expect(label, startsWith('box'));
          expect(label, contains('deploy@box.example.com:22'));
          if (dot.description case final said?) {
            expect(label, contains(said));
          }
        } finally {
          semantics.dispose();
        }
      });
    }
  });

  testWidgets('×N shows only past one tab', (tester) async {
    await pump(tester, tabCount: 1);
    expect(find.textContaining('×'), findsNothing);
    await pump(tester, tabCount: 3);
    expect(find.text('×3'), findsOneWidget);
  });

  testWidgets('a connected row offers the disconnect glyph on hover', (
    tester,
  ) async {
    await pump(tester, connected: true, tabCount: 2, dot: ServerDot.connected);
    final glyph = find.byKey(const ValueKey('server.disconnect.box'));
    expect(glyph, findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(SidebarRow)));
    await tester.pump();
    expect(find.byTooltip('Disconnect all'), findsOneWidget);
    await tester.tap(glyph);
    expect(calls, ['disconnect']);

    // Nothing connected, nothing to eject.
    await pump(tester);
    await mouse.moveTo(Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(SidebarRow)));
    await tester.pump();
    expect(glyph, findsNothing);
  });

  group('activation', () {
    Future<void> clickWith(
      WidgetTester tester,
      LogicalKeyboardKey modifier,
    ) async {
      await tester.sendKeyDownEvent(modifier);
      await tester.tap(find.byType(SidebarRow));
      await tester.sendKeyUpEvent(modifier);
    }

    testWidgets('macOS: a click opens and ⌘-click opens another tab; a '
        'Control-click, the Mac secondary click, does neither', (tester) async {
      await pump(tester, platform: TargetPlatform.macOS);
      await tester.tap(find.byType(SidebarRow));
      await clickWith(tester, LogicalKeyboardKey.metaLeft);
      // The embedder delivers Control+click as a primary click; it must
      // not connect anything, let alone another SSH session.
      await clickWith(tester, LogicalKeyboardKey.controlLeft);
      // Enter from the keyboard is always the plain open.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, ['open', 'newTab', 'open']);
    });

    for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
      testWidgets('${platform.name}: Ctrl-click opens another tab', (
        tester,
      ) async {
        await pump(tester, platform: platform);
        await tester.tap(find.byType(SidebarRow));
        await clickWith(tester, LogicalKeyboardKey.controlLeft);
        // The Super/Windows key is the system's, not a tab modifier.
        await clickWith(tester, LogicalKeyboardKey.metaLeft);
        expect(calls, ['open', 'newTab', 'open']);
      });
    }
  });

  group('the menu', () {
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(
        find.byType(SidebarRow),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    MenuItemButton verb(WidgetTester tester, String label) =>
        tester.widget<MenuItemButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(MenuItemButton),
          ),
        );

    testWidgets('right-click opens the verbs the tile always offered', (
      tester,
    ) async {
      await pump(tester);
      await openMenu(tester);
      for (final label in [
        'Connect',
        'Connect in new tab',
        'Disconnect',
        'Pin to top',
        'Edit…',
        'Duplicate',
        'Delete…',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // Nothing connected: Disconnect stays, greyed, so the menu keeps its
      // shape; Reconnect is only for a lone dead tab.
      expect(verb(tester, 'Disconnect').onPressed, isNull);
      expect(find.text('Reconnect'), findsNothing);

      for (final (label, call) in [
        ('Connect', 'open'),
        ('Connect in new tab', 'newTab'),
        ('Pin to top', 'pin'),
        ('Edit…', 'edit'),
        ('Duplicate', 'duplicate'),
        ('Delete…', 'delete'),
      ]) {
        if (label != 'Connect') await openMenu(tester);
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(calls.last, call, reason: label);
      }
    });

    testWidgets('the verbs follow the row\'s state', (tester) async {
      await pump(tester, pinned: true, connected: true, tabCount: 2);
      await openMenu(tester);
      expect(find.text('Unpin'), findsOneWidget);
      expect(find.text('Pin to top'), findsNothing);
      expect(verb(tester, 'Disconnect all').onPressed, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await pump(tester, tabCount: 1, reconnectable: true);
      await openMenu(tester);
      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();
      expect(calls, ['reconnect']);
    });

    testWidgets('the home line names a non-default port and brackets an '
        'IPv6 host', (tester) async {
      ServerConfig at(String host, int port) => ServerConfig(
        id: 'box',
        label: 'box',
        host: host,
        port: port,
        username: 'deploy',
        createdAt: 1,
        updatedAt: 1,
      );
      await pump(
        tester,
        config: at('box.example.com', 2222),
        platform: TargetPlatform.android,
        showAddress: true,
      );
      expect(find.text('deploy@box.example.com:2222'), findsOneWidget);

      await pump(
        tester,
        config: at('fe80::1', 22),
        platform: TargetPlatform.android,
        showAddress: true,
      );
      expect(find.text('deploy@[fe80::1]'), findsOneWidget);
    });

    testWidgets('on touch a long-press opens the same verbs as a sheet', (
      tester,
    ) async {
      await pump(tester, platform: TargetPlatform.android, showAddress: true);
      // The touch home spells the address out (SSH's default port left
      // implied, as Poltergeist's Home does), and is 48 dp or more.
      expect(find.text('deploy@box.example.com'), findsOneWidget);
      expect(
        tester.getSize(find.byType(SidebarRow)).height,
        greaterThanOrEqualTo(48),
      );
      await tester.longPress(find.byType(SidebarRow));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect(calls, ['duplicate']);
    });
  });
}
