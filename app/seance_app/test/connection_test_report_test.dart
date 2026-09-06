import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/connection_test_report.dart';
import 'package:seance_core/seance_core.dart';

/// The report is what a user reads when a server will not connect, so it has
/// to carry the reason, the caveats, and the transcript — not just a colour.
void main() {
  Future<void> pump(WidgetTester tester, ConnectionTestResult result) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConnectionTestReport(result: result),
            ),
          ),
        ),
      );

  testWidgets('a failure shows the reason, not only that it failed', (
    tester,
  ) async {
    await pump(
      tester,
      const ConnectionTestResult(
        ok: false,
        summary: 'Public key rejected by prod.example.com.',
        log: 'Auth method: public key\nrejected',
      ),
    );

    expect(find.text('Public key rejected by prod.example.com.'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
  });

  testWidgets('the outcome is spoken, not only coloured', (tester) async {
    // Success and failure differ by hue, which is the one difference some
    // readers do not get.
    await pump(
      tester,
      const ConnectionTestResult(ok: true, summary: 'Authenticated.', log: ''),
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.check_circle_outline)).semanticLabel,
      'Connection test succeeded',
    );

    await pump(
      tester,
      const ConnectionTestResult(ok: false, summary: 'Refused.', log: ''),
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.error_outline)).semanticLabel,
      'Connection test failed',
    );
  });

  testWidgets('notes qualify a success the summary would overstate', (
    tester,
  ) async {
    await pump(
      tester,
      const ConnectionTestResult(
        ok: true,
        summary: 'Authenticated as deploy@prod:22 (public key).',
        notes: ['Séance does not execute the jump host yet.'],
        log: '',
      ),
    );
    expect(
      find.text('Séance does not execute the jump host yet.'),
      findsOneWidget,
    );
  });

  testWidgets('the transcript is there but folded away', (tester) async {
    await pump(
      tester,
      const ConnectionTestResult(
        ok: false,
        summary: 'Could not reach prod.example.com:22.',
        log: 'Auth method: password\nConnection refused',
      ),
    );

    // Folded: the summary is the answer, the transcript is the evidence.
    expect(find.text('Connection log'), findsOneWidget);
    expect(find.textContaining('Connection refused'), findsNothing);

    await tester.tap(find.text('Connection log'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connection refused'), findsOneWidget);
  });

  testWidgets('an empty transcript says so rather than showing a blank box', (
    tester,
  ) async {
    await pump(
      tester,
      const ConnectionTestResult(ok: false, summary: 'Refused.', log: ''),
    );
    await tester.tap(find.text('Connection log'));
    await tester.pumpAndSettle();
    expect(find.text('(no log captured)'), findsOneWidget);
    // Nothing to copy, so the button says so by being unavailable.
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Copy'))
          .onPressed,
      isNull,
    );
  });
}
