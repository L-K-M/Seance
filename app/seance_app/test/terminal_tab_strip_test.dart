import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  testWidgets('a single session keeps tab actions reachable at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = XtermTerminalEngine();
    addTearDown(engine.dispose);
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    final tab = TerminalSession(
      id: 'tab',
      serverId: config.id,
      config: config,
      engine: engine,
      connecting: false,
    );
    var newTabCalls = 0;
    var generateCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [tab],
            activeTabId: tab.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () => newTabCalls++,
            onGenerateCommand: () => generateCalls++,
          ),
        ),
      ),
    );

    expect(find.text('Session 1'), findsOneWidget);
    expect(find.byTooltip('New tab'), findsOneWidget);
    expect(find.byTooltip('Generate command'), findsOneWidget);

    await tester.tap(find.byTooltip('New tab'));
    await tester.tap(find.byTooltip('Generate command'));
    expect(newTabCalls, 1);
    expect(generateCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-place tabs get disambiguating suffixes', (tester) async {
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    TerminalSession tab(String id) {
      final engine = XtermTerminalEngine();
      addTearDown(engine.dispose);
      final t = TerminalSession(
        id: id,
        serverId: config.id,
        config: config,
        engine: engine,
        connecting: false,
        initialMetadata: const SessionMetadata(workingDirectory: '/home/user'),
      );
      addTearDown(t.dispose);
      return t;
    }

    final a = tab('a');
    final b = tab('b');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [a, b],
            activeTabId: a.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
          ),
        ),
      ),
    );

    expect(find.text('user \u00b71'), findsOneWidget);
    expect(find.text('user \u00b72'), findsOneWidget);

    // One tab moves elsewhere: both suffixes disappear on their own.
    b.metadata.value = const SessionMetadata(workingDirectory: '/var/log');
    await tester.pump();
    expect(find.text('user'), findsOneWidget);
    expect(find.text('log'), findsOneWidget);
  });

  testWidgets('an editor tab sits beside terminal tabs in the strip', (
    tester,
  ) async {
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    final engine = XtermTerminalEngine();
    addTearDown(engine.dispose);
    final terminal = TerminalSession(
      id: 'term',
      serverId: config.id,
      config: config,
      engine: engine,
      connecting: false,
    );
    addTearDown(terminal.dispose);
    final editor = EditorTab(
      id: 'edit',
      serverId: config.id,
      config: config,
      remotePath: '/etc/nginx/nginx.conf',
      localPath: 'nginx.conf',
      ownerEditSessionId: terminal.editSessionId,
    );
    var closed = '';
    var focused = '';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [terminal, editor],
            activeTabId: editor.id,
            onFocus: (id) => focused = id,
            onClose: (id) => closed = id,
            onNewTab: () {},
            onGenerateCommand: () {},
          ),
        ),
      ),
    );

    // The file's basename labels the tab; the shell keeps its own name.
    expect(find.text('nginx.conf'), findsOneWidget);
    expect(find.text('Session 1'), findsOneWidget);

    // The editor chip's close button doubles as the unsaved marker once the
    // buffer is dirty (the terminal's status dot is also a circle, so the
    // finders are scoped to the editor's chip).
    final editorChip = find.ancestor(
      of: find.text('nginx.conf'),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(of: editorChip, matching: find.byIcon(Icons.close)),
      findsOneWidget,
    );
    editor.dirty.value = true;
    await tester.pump();
    expect(
      find.descendant(of: editorChip, matching: find.byIcon(Icons.circle)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: editorChip, matching: find.byIcon(Icons.close)),
      findsNothing,
    );

    // Taps still focus and close by tab id.
    await tester.tap(find.text('Session 1'));
    expect(focused, terminal.id);
    await tester.tap(
      find.descendant(of: editorChip, matching: find.byType(IconButton)),
    );
    expect(closed, editor.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor tabs do not consume terminal ordinals', (tester) async {
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    TerminalSession term(String id) {
      final engine = XtermTerminalEngine();
      addTearDown(engine.dispose);
      final t = TerminalSession(
        id: id,
        serverId: config.id,
        config: config,
        engine: engine,
        connecting: false,
      );
      addTearDown(t.dispose);
      return t;
    }

    final first = term('term-1');
    final second = term('term-2');
    final editor = EditorTab(
      id: 'edit',
      serverId: config.id,
      config: config,
      remotePath: '/etc/motd',
      localPath: 'motd',
      ownerEditSessionId: first.editSessionId,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            // Terminal, editor, terminal: the editor sits between them in
            // the strip but must not shift the second shell's ordinal.
            tabs: [first, editor, second],
            activeTabId: second.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
          ),
        ),
      ),
    );

    expect(find.text('Session 1'), findsOneWidget);
    expect(find.text('Session 2'), findsOneWidget);
    expect(find.text('Session 3'), findsNothing);
    expect(find.text('motd'), findsOneWidget);
  });

  testWidgets('the server accent colours the strip\'s rule', (tester) async {
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    final engine = XtermTerminalEngine();
    addTearDown(engine.dispose);
    final tab = TerminalSession(
      id: 'tab',
      serverId: config.id,
      config: config,
      engine: engine,
      connecting: false,
    );
    addTearDown(tab.dispose);

    BorderSide ruleOf(WidgetTester tester) {
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(TerminalTabStrip),
              matching: find.byType(Container),
            )
            .first,
      );
      return (container.decoration as BoxDecoration).border!.bottom;
    }

    Future<void> pump(Color? accent) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [tab],
            activeTabId: tab.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
            accent: accent,
          ),
        ),
      ),
    );

    await pump(null);
    final plain = ruleOf(tester);
    expect(plain.width, 1, reason: 'an uncoloured server keeps the hairline');

    await pump(const Color(0xFFE03131));
    final accented = ruleOf(tester);
    expect(accented.color, const Color(0xFFE03131));
    expect(accented.width, greaterThan(plain.width));
  });
}
