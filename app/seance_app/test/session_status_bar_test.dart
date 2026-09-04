import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  for (final width in [240.0, 320.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final cwd in <String?>[null, '/srv/production/application/logs']) {
        testWidgets('footer fits $width px at $scale× with cwd=$cwd', (
          tester,
        ) async {
          final engine = XtermTerminalEngine();
          addTearDown(engine.dispose);
          final config = ServerConfig(
            id: 'server',
            label: 'Production',
            host: 'production-application.eu-west-1.internal.example.com',
            username: 'deployment-operator',
            authMethod: AuthMethod.password,
            createdAt: 0,
            updatedAt: 0,
          );
          final session = TerminalSession(
            id: 'session',
            serverId: config.id,
            config: config,
            engine: engine,
            connecting: false,
            initialMetadata: SessionMetadata(workingDirectory: cwd),
          );
          addTearDown(session.dispose);
          final target = '${config.username}@${config.host}:${config.port}';

          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      child: SessionStatusBar(session: session),
                    ),
                  ),
                ),
              ),
            ),
          );

          expect(tester.takeException(), isNull);
          expect(find.byTooltip(target), findsOneWidget);
          expect(find.bySemanticsLabel(target), findsOneWidget);
          if (scale > 1) {
            expect(
              tester.getSize(find.byType(SessionStatusBar)).height,
              greaterThan(24),
            );
          }
          if (cwd != null) {
            expect(find.bySemanticsLabel(cwd), findsOneWidget);
          }
        });
      }
    }
  }
}
