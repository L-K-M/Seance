import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  testWidgets('a single session still shows the new-tab affordance', (
    tester,
  ) async {
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
      log: SshConnectionLog(),
      connecting: false,
    );
    var newTabCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [tab],
            activeSessionId: tab.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () => newTabCalls++,
          ),
        ),
      ),
    );

    expect(find.text('Session 1'), findsOneWidget);
    expect(find.byTooltip('New tab'), findsOneWidget);

    await tester.tap(find.byTooltip('New tab'));
    expect(newTabCalls, 1);
  });
}
