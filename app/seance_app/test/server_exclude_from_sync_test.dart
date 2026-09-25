import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/server_editor.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_app/ui/server_status_dot.dart';
import 'package:seance_app/ui/server_tile.dart';
import 'package:seance_app/ui/sidebar/sidebar_kit.dart';
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
          theme: SeanceTheme.light(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: SidebarKitScope(
              strings: serverSidebarStrings,
              child: ServerTile(
                server: config(excluded: excluded),
                dot: ServerDot.none,
                tabCount: 0,
                selected: false,
                pinned: false,
                onOpen: () {},
                onNewTab: () {},
                onEdit: () {},
                onDuplicate: () {},
                onDelete: () {},
                onTogglePin: () {},
              ),
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
    final semantics = tester.ensureSemantics();
    try {
      await pump(tester, excluded: true);
      // Read off the row's node, which is what a screen reader is handed:
      // the row's visuals are excluded from semantics, so the description
      // has to arrive in its label.
      final data = tester
          .getSemantics(
            find
                .descendant(
                  of: find.byType(SidebarRow),
                  matching: find.byType(Listener),
                )
                .first,
          )
          .getSemanticsData();
      expect(data.label, contains('Excluded from sync'));
      expect(data.label, contains('this device only'));
      // Still described for a pointer, in the row's tooltip (the one over
      // its title, not the "⋮" beside it).
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(of: find.text('laptop'), matching: find.byType(Tooltip)),
      );
      expect(tooltip.message, contains('Excluded from sync'));
    } finally {
      semantics.dispose();
    }
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
      // Already excluded: the retraction happened the first time, so flipping
      // the switch off and back on within one editor session asks nothing.
      expect(
        excludingNeedsConfirmation(
          existing: config(excluded: true),
          syncConfigured: true,
        ),
        isFalse,
      );
    });
  });

  group('confirmSyncExclusion', () {
    Future<bool?> tapThrough(WidgetTester tester, String? answer) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await confirmSyncExclusion(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => confirmSyncExclusion(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final body = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data ?? '')
          .join(' ');
      // Naming the credential is the part a user cannot infer from "sync".
      expect(body, contains('your other devices'));
      expect(body, contains('credential'));
      expect(body, contains('This device keeps its copy'));
    });
  });

  group('nextUpdatedAt', () {
    test('uses the wall clock when it is already ahead', () {
      expect(nextUpdatedAt(100, now: 5000), 5000);
    });

    test('a new server has nothing to outrank', () {
      expect(nextUpdatedAt(null, now: 5000), 5000);
    });

    test('a clock behind the stored stamp still moves the record forward', () {
      // The case that matters: this device pulled a record another device
      // wrote under a faster clock. Stamping an honest "now" would tie with or
      // lose to it, so the edit — an exclusion, most expensively — would take
      // here and nowhere else.
      expect(nextUpdatedAt(5000, now: 100), 5001);
    });

    test('a tie is not good enough', () {
      // Last-write-wins breaks a tie by device id and sequence, not in the
      // editing device's favour, so an equal stamp is a coin flip.
      expect(nextUpdatedAt(5000, now: 5000), 5001);
    });
  });
}
