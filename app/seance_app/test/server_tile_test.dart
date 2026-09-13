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
  ServerConfig server() => ServerConfig(
    id: 'box',
    label: 'box',
    host: 'box.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  Future<void> pump(
    WidgetTester tester, {
    required ServerListDensity density,
    bool selected = false,
    int tabCount = 0,
    TerminalStatus connection = TerminalStatus.disconnected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServerTile(
            density: density,
            server: server(),
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
        await pump(tester, density: density, selected: true);
        final scheme = Theme.of(
          tester.element(find.byType(ListTile)),
        ).colorScheme;
        final selected = tile(tester);
        // Three signals, because a tinted title alone is what the eye is
        // worst at picking out of a list of tinted badges.
        expect(selected.selectedTileColor, scheme.secondaryContainer);
        final shape = selected.shape;
        expect(shape, isA<BorderDirectional>());
        expect((shape as BorderDirectional).start.color, scheme.primary);
        expect(shape.start.width, greaterThan(0));
        expect(titleStyle(tester).fontWeight, FontWeight.w600);

        await pump(tester, density: density, selected: false);
        expect(tile(tester).shape, isNull);
        expect(titleStyle(tester).fontWeight, isNot(FontWeight.w600));
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

        await pump(tester, density: density);
        expect(find.byTooltip('connected'), findsNothing);
        expect(find.byTooltip('disconnected'), findsNothing);
        // The same footprint either way: rows do not shift as sessions come
        // and go.
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
