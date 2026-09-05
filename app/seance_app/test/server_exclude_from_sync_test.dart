import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/ui/server_editor.dart';
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

  group('excludingNeedsConfirmation', () {
    ServerConfig existing() => config(excluded: false);

    test('asks only when another device could lose the server', () {
      // The one thing this editor does that deletes data elsewhere, sitting a
      // few rows from the colour picker — so it is confirmed rather than left
      // to a subtitle.
      expect(
        excludingNeedsConfirmation(existing: existing(), syncConfigured: true),
        isTrue,
      );
      // Nothing to retract: never uploaded, or nowhere to have uploaded it.
      expect(
        excludingNeedsConfirmation(existing: null, syncConfigured: true),
        isFalse,
      );
      expect(
        excludingNeedsConfirmation(existing: existing(), syncConfigured: false),
        isFalse,
      );
    });
  });

  group('confirmSyncExclusion', () {
    Future<bool?> tapThrough(WidgetTester tester, String? answer) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await confirmSyncExclusion(context),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Exclude from sync?'), findsOneWidget);
      if (answer == null) {
        // Barrier tap: the way a dialog is dismissed without answering it.
        await tester.tapAt(const Offset(10, 10));
      } else {
        await tester.tap(find.text(answer));
      }
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('Exclude proceeds', (tester) async {
      expect(await tapThrough(tester, 'Exclude'), isTrue);
    });

    testWidgets('Cancel does not', (tester) async {
      expect(await tapThrough(tester, 'Cancel'), isFalse);
    });

    testWidgets('dismissing without answering does not', (tester) async {
      // The null case: the one input that means the user never answered must
      // not be the one that deletes the server from their other devices.
      expect(await tapThrough(tester, null), isFalse);
    });

    testWidgets('says what it will take away', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => confirmSyncExclusion(context),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final body = tester
          .widgetList<Text>(find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Text),
          ))
          .map((t) => t.data ?? '')
          .join(' ');
      // Naming the credential is the part a user cannot infer from "sync".
      expect(body, contains('your other devices'));
      expect(body, contains('credential'));
      expect(body, contains('This device keeps its copy'));
    });
  });
}
