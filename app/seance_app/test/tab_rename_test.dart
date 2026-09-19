import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/session_label.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

/// Manual tab naming: an explicit name from the user outranks everything the
/// shell reports, survives a reconnect, and can be cleared back to automatic.
void main() {
  ServerConfig config() => ServerConfig(
    id: 'server',
    label: 'Server',
    host: 'example.com',
    port: 22,
    username: 'user',
    authMethod: AuthMethod.password,
    createdAt: 0,
    updatedAt: 0,
  );

  TerminalSession session({
    String id = 'tab',
    SessionMetadata metadata = const SessionMetadata(),
    String? customName,
  }) {
    final engine = XtermTerminalEngine();
    addTearDown(engine.dispose);
    final tab = TerminalSession(
      id: id,
      serverId: 'server',
      config: config(),
      engine: engine,
      connecting: false,
      initialMetadata: metadata,
      initialCustomName: customName,
    );
    addTearDown(tab.dispose);
    return tab;
  }

  group('sessionTabLabel with a custom name', () {
    test('outranks the running command and the directory', () {
      expect(
        sessionTabLabel(
          ordinal: 1,
          customName: 'deploy',
          workingDirectory: '/srv/app',
          terminalTitle: 'ops@web: /srv/app',
          runningCommand: 'tail -f app.log',
        ),
        'deploy',
      );
    });

    test('keeps the head when it is too long, like a command', () {
      expect(
        sessionTabLabel(
          ordinal: 1,
          customName: 'production database migration',
          maxLength: 12,
        ),
        'production…',
      );
    });

    test('a blank name falls through to automatic naming', () {
      expect(
        sessionTabLabel(
          ordinal: 1,
          customName: '   ',
          workingDirectory: '/srv/app',
        ),
        'app',
      );
    });

    test('a pasted newline cannot break the one-line strip', () {
      expect(
        sessionTabLabel(ordinal: 1, customName: 'logs\nrm -rf /'),
        'logs rm -rf /',
      );
    });
  });

  test('a reconnect carries the name the user chose', () {
    final engine = XtermTerminalEngine();
    addTearDown(engine.dispose);
    // What AppState.reconnect hands the replacement session: the metadata
    // minus the dead command, and the name verbatim.
    final replacement = TerminalSession(
      id: 'new',
      serverId: 'server',
      config: config(),
      engine: engine,
      connecting: false,
      initialMetadata: const SessionMetadata(
        workingDirectory: '/srv/app',
        runningCommand: 'tail -f app.log',
      ).withoutRunningCommand,
      initialCustomName: 'deploy',
    );
    addTearDown(replacement.dispose);

    expect(replacement.customName.value, 'deploy');
    expect(replacement.metadata.value.workingDirectory, '/srv/app');
    expect(replacement.metadata.value.runningCommand, isNull);
  });

  test('the tooltip carries a name too long for the chip', () {
    const name = 'production database migration';
    // The chip truncates it; the tooltip is the only other place it appears,
    // so the full text has to survive here.
    expect(
      sessionTabLabel(ordinal: 1, customName: name),
      isNot(contains('migration')),
    );
    expect(
      sessionTabTooltip(ordinal: 1, target: 'a@b:22', customName: name),
      contains(name),
    );
  });

  group('a named tab still disambiguates', () {
    test('two tabs named the same still get ordinals', () {
      expect(disambiguateTabLabels(['deploy', 'deploy']), [
        'deploy ·1',
        'deploy ·2',
      ]);
    });
  });

  /// Long-press stands in for both entry points: it and right-click open the
  /// same menu. `tester.longPress` also proves the [Tooltip] no longer eats
  /// the gesture, which it did while its trigger mode was the default.
  Future<void> openTabMenu(WidgetTester tester, Finder tab) async {
    await tester.longPress(tab);
    await tester.pumpAndSettle();
  }

  testWidgets('the tab menu renames, and Reset clears it', (tester) async {
    final tab = session(
      metadata: const SessionMetadata(workingDirectory: '/home/user'),
    );
    final renames = <(String, String?)>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [tab],
            activeTabId: tab.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
            onRename: (id, name) {
              renames.add((id, name));
              tab.customName.value = name;
            },
          ),
        ),
      ),
    );
    expect(find.text('user'), findsOneWidget);

    await openTabMenu(tester, find.text('user'));
    await tester.tap(find.text('Rename tab…'));
    await tester.pumpAndSettle();

    expect(find.text('Rename tab'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'deploy');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(renames, [('tab', 'deploy')]);
    expect(find.text('deploy'), findsOneWidget);

    // Reopen: the field is prefilled and Reset returns to automatic naming.
    await openTabMenu(tester, find.text('deploy'));
    await tester.tap(find.text('Rename tab…'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'deploy'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.pumpAndSettle();

    expect(renames.last, ('tab', null));
    expect(find.text('user'), findsOneWidget);
  });

  testWidgets('the menu carries the session details touch cannot hover for', (
    tester,
  ) async {
    final tab = session(
      metadata: const SessionMetadata(
        workingDirectory: '/srv/app',
        runningCommand: 'tail -f app.log',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [tab],
            activeTabId: tab.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
            onRename: (_, _) {},
          ),
        ),
      ),
    );

    await openTabMenu(tester, find.text('tail -f app.log'));
    expect(
      find.textContaining('user@example.com:22'),
      findsOneWidget,
      reason: 'the menu header replaces the tooltip on touch',
    );
    expect(find.textContaining('/srv/app'), findsOneWidget);
  });

  testWidgets('switching tabs is not delayed by the rename affordance', (
    tester,
  ) async {
    final tab = session(
      metadata: const SessionMetadata(workingDirectory: '/home/user'),
    );
    var focused = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [tab],
            activeTabId: tab.id,
            onFocus: (_) => focused++,
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
            onRename: (_, _) {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('user'));
    await tester.pump();
    // An onDoubleTap handler here would hold this back for the double-tap
    // timeout, taxing every tab switch for the sake of a rare rename.
    expect(focused, 1, reason: 'a tab switch must resolve on the tap itself');
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling leaves the name alone', (tester) async {
    final tab = session(customName: 'deploy');
    var renameCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [tab],
            activeTabId: tab.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
            onRename: (_, _) => renameCalls++,
          ),
        ),
      ),
    );

    await openTabMenu(tester, find.text('deploy'));
    await tester.tap(find.text('Rename tab…'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(renameCalls, 0);
    expect(tab.customName.value, 'deploy');
  });

  testWidgets('an unnamed tab is not offered a Reset it cannot use', (
    tester,
  ) async {
    final tab = session(
      metadata: const SessionMetadata(workingDirectory: '/home/user'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [tab],
            activeTabId: tab.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
            onRename: (_, _) {},
          ),
        ),
      ),
    );

    await openTabMenu(tester, find.text('user'));
    await tester.tap(find.text('Rename tab…'));
    await tester.pumpAndSettle();

    expect(find.text('Rename tab'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Reset'), findsNothing);
  });
}
