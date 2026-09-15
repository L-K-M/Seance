import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/ui/server_appearance.dart';
import 'package:seance_app/ui/server_list_density.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_core/seance_core.dart';

/// What a row in the server list says about itself: which one is selected,
/// and which have a session open. Both in both densities, since the compact
/// row is not the comfortable one with a line removed.
void main() {
  ServerConfig server({ServerColor? color}) => ServerConfig(
    id: 'box',
    label: 'box',
    host: 'box.example.com',
    username: 'deploy',
    color: color,
    createdAt: 1,
    updatedAt: 1,
  );

  Future<void> pump(
    WidgetTester tester, {
    required ServerListDensity density,
    bool selected = false,
    int tabCount = 0,
    TerminalStatus connection = TerminalStatus.disconnected,
    ServerColor? color,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServerTile(
            density: density,
            server: server(color: color),
            connection: connection,
            tabCount: tabCount,
            reachability: ProbeStatus.unknown,
            selected: selected,
            onTap: () {},
            onNewTab: () {},
            onEdit: () {},
            onDuplicate: () {},
            onDelete: () {},
            onDisconnect: () {},
            onReconnect: null,
            pinned: false,
            onTogglePin: () {},
          ),
        ),
      ),
    );
    // Past the tile's own style transition, which animates a change of
    // selection rather than cutting to it.
    await tester.pump(const Duration(milliseconds: 400));
  }

  ListTile tile(WidgetTester tester) =>
      tester.widget<ListTile>(find.byType(ListTile));

  /// The title's effective style, as the text under it is drawn.
  TextStyle titleStyle(WidgetTester tester) =>
      DefaultTextStyle.of(tester.element(find.text('box'))).style;

  for (final density in ServerListDensity.values) {
    group(density.label, () {
      testWidgets('the selected row is filled, barred and bold', (
        tester,
      ) async {
        await pump(
          tester,
          density: density,
          selected: true,
          color: ServerColor.red,
        );
        final scheme = Theme.of(
          tester.element(find.byType(ListTile)),
        ).colorScheme;
        final selected = tile(tester);
        // Where the row's content starts. A shape border on the tile would
        // inset this by the border's width; the bar must not move it.
        final leadingEdge = tester
            .getTopLeft(find.byType(ServerAccentBar))
            .dx;
        // Three signals, because a tinted title alone is what the eye is
        // worst at picking out of a list of tinted badges.
        expect(selected.selectedTileColor, scheme.secondaryContainer);
        // The bar is a foreground decoration: the tile's own shape must stay
        // empty even when selected, or the border would inset the content.
        expect(selected.shape, isNull);
        // The bar is a foreground decoration, not the tile's shape: a shape
        // border insets the content by its width and the row would sit a few
        // pixels right of every unselected one.
        final bar = find.ancestor(
          of: find.byType(ListTile),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.position == DecorationPosition.foreground &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).border
                    is BorderDirectional,
          ),
        );
        expect(bar, findsOneWidget);
        final border =
            (tester.widget<DecoratedBox>(bar).decoration as BoxDecoration)
                    .border!
                as BorderDirectional;
        expect(border.start.color, scheme.primary);
        expect(border.start.width, greaterThan(0));
        expect(titleStyle(tester).fontWeight, FontWeight.w600);

        await pump(
          tester,
          density: density,
          selected: false,
          color: ServerColor.red,
        );
        expect(tile(tester).shape, isNull);
        expect(bar, findsNothing);
        expect(titleStyle(tester).fontWeight, isNot(FontWeight.w600));
        expect(
          tester.getTopLeft(find.byType(ServerAccentBar)).dx,
          leadingEdge,
          reason: 'selecting a row must not shift its content',
        );
      });

      testWidgets('the row carries the server\'s colour as its bar', (
        tester,
      ) async {
        // The composition the whole treatment rests on. The badge carries
        // the same colour as a fill, so a tint that stopped reaching the bar
        // would take the one carrier an image mark cannot cover out of the
        // list while the bar's own tests, and the badge's, stayed green.
        const red = ServerTint(named: ServerColor.red);
        await pump(tester, density: density, color: ServerColor.red);
        final bar = find.byType(ServerAccentBar);
        expect(tester.widget<ServerAccentBar>(bar).tint, red);
        final painted = tester.widget<DecoratedBox>(
          find.descendant(of: bar, matching: find.byType(DecoratedBox)),
        );
        expect(
          (painted.decoration as BoxDecoration).color,
          serverAccent(tester.element(bar), red)!.line,
        );
        // As tall as the whole mark beside it, ring included, at either
        // density — the two read as one block or as two stray shapes.
        expect(
          tester.getSize(bar).height,
          ServerAvatar.extentFor(tester.getSize(find.byType(ServerBadge)).width),
        );

        // No colour: nothing painted, but the slot stays, so the marks of
        // coloured and uncoloured rows line up in one column.
        await pump(tester, density: density);
        expect(
          find.descendant(of: bar, matching: find.byType(DecoratedBox)),
          findsNothing,
        );
        expect(tester.getSize(bar).width, ServerAccentBar.width);
      });

      testWidgets('a row with a session wears the ring, others do not', (
        tester,
      ) async {
        await pump(
          tester,
          density: density,
          tabCount: 1,
          connection: TerminalStatus.connected,
        );
        expect(find.byTooltip('connected'), findsOneWidget);
        final ringed = tester.getSize(find.byType(ServerAvatar));

        // A dropped session is not connected: no ring. The footprint is
        // reserved either way, so rows do not shift as sessions come and go.
        await pump(tester, density: density, tabCount: 1);
        expect(find.byTooltip('connected'), findsNothing);
        expect(find.byTooltip('disconnected'), findsNothing);
        expect(tester.getSize(find.byType(ServerAvatar)), ringed);

        // Nor is a connecting one: no ring, no sweep, no tooltip.
        await pump(
          tester,
          density: density,
          tabCount: 1,
          connection: TerminalStatus.connecting,
        );
        expect(find.byTooltip('connected'), findsNothing);
        expect(find.byTooltip('connecting'), findsNothing);
        expect(tester.getSize(find.byType(ServerAvatar)), ringed);

        await pump(tester, density: density);
        expect(find.byTooltip('connected'), findsNothing);
        expect(find.byTooltip('disconnected'), findsNothing);
        expect(tester.getSize(find.byType(ServerAvatar)), ringed);
      });
    });
  }

  testWidgets('the compact ring is smaller than the comfortable one', (
    tester,
  ) async {
    // The ring scales with the badge rather than swallowing a small one.
    await pump(
      tester,
      density: ServerListDensity.comfortable,
      tabCount: 1,
      connection: TerminalStatus.connected,
    );
    final comfortable = tester.getSize(find.byType(ServerAvatar));
    await pump(
      tester,
      density: ServerListDensity.compact,
      tabCount: 1,
      connection: TerminalStatus.connected,
    );
    final compact = tester.getSize(find.byType(ServerAvatar));
    expect(compact.width, lessThan(comfortable.width));
  });
}
