import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_core/seance_core.dart';

/// A server excluded from sync looks no different from any other one unless the
/// row says so, and "cloud with a slash" is not self-describing — so both the
/// condition and the announcement are asserted here.
void main() {
  ServerConfig config({required bool excluded}) => ServerConfig(
    id: 's1',
    label: 'laptop',
    host: 'localhost',
    username: 'me',
    excludeFromSync: excluded,
    createdAt: 1,
    updatedAt: 2,
  );

  Future<void> pump(WidgetTester tester, {required bool excluded}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServerTile(
              server: config(excluded: excluded),
              connection: TerminalStatus.disconnected,
              tabCount: 0,
              reachability: ProbeStatus.unknown,
              selected: false,
              onTap: () {},
              onNewTab: () {},
              onEdit: () {},
              onDuplicate: () {},
              onDelete: () {},
              onDisconnect: () {},
              onReconnect: null,
            ),
          ),
        ),
      );

  testWidgets('an excluded server is marked, a synced one is not', (
    tester,
  ) async {
    await pump(tester, excluded: false);
    expect(find.byIcon(Icons.cloud_off_outlined), findsNothing);

    await pump(tester, excluded: true);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });

  testWidgets('the mark says what it means rather than only drawing it', (
    tester,
  ) async {
    await pump(tester, excluded: true);
    // Read off the row's merged node, which is what a screen reader is
    // handed. A tooltip would not survive that merge — the row carries others
    // and only one wins — so the description has to arrive as a label.
    final data = tester
        .getSemantics(find.byIcon(Icons.cloud_off_outlined))
        .getSemanticsData();
    expect(data.label, contains('Excluded from sync'));
    expect(data.label, contains('this device only'));
    // Still described for a pointer, just not through the semantics tree.
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.byIcon(Icons.cloud_off_outlined),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, contains('Excluded from sync'));
    expect(tooltip.excludeFromSemantics, isTrue);
  });
}
