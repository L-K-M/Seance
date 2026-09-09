import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/host_key_dialog.dart';
import 'package:seance_core/seance_core.dart';

/// Widget tests for the TOFU dialog — this also proves the app's widget layer
/// actually compiles and renders under the Flutter engine.
void main() {
  HostKey key(String fp) => HostKey(
      host: 'example.com',
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:$fp',
      pinnedAt: 0);

  Future<bool?> pumpAndOpen(WidgetTester tester, HostKeyDecision decision) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async =>
                result = await showHostKeyDialog(context, decision),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  /// Opens the dialog above a pushed page, as a real prompt does: the page
  /// below must survive the dialog's dismissal. Returns a recorder the
  /// dialog's answer is written to.
  Future<List<bool?>> openAbovePushedPage(
      WidgetTester tester,
      HostKeyDecision decision,
      {required GlobalKey<NavigatorState> navigatorKey}) async {
    final recorded = <bool?>[];
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Center(child: Text('home-page'))),
    ));
    navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async =>
                  recorded.add(await showHostKeyDialog(context, decision)),
              child: const Text('open-dialog'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-dialog'));
    await tester.pumpAndSettle();
    return recorded;
  }

  testWidgets('a rapid double trust cannot pop the page below the dialog',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final decision = HostKeyDecision(
        verdict: HostKeyVerdict.firstUse, presented: key('AAA'));
    final recorded = await openAbovePushedPage(tester, decision,
        navigatorKey: navigatorKey);

    // Two activations in one turn: the first starts the exit animation, and
    // the second must not pop whatever sits below the half-dismissed dialog.
    final trust = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Trust and connect'));
    trust.onPressed!();
    trust.onPressed!();
    await tester.pumpAndSettle();

    expect(recorded, [true]); // the first answer survives, unchanged
    expect(find.text('home-page'), findsNothing); // the pushed page was not popped
    expect(find.text('open-dialog'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rapid double cancel keeps the first cancel answer',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final decision = HostKeyDecision(
        verdict: HostKeyVerdict.changed,
        presented: key('NEW'),
        pinned: key('OLD'));
    final recorded = await openAbovePushedPage(tester, decision,
        navigatorKey: navigatorKey);

    final cancel =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'));
    cancel.onPressed!();
    cancel.onPressed!();
    await tester.pumpAndSettle();

    expect(recorded, [false]);
    expect(find.text('home-page'), findsNothing);
    expect(find.text('open-dialog'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a callback from an obscured dialog cannot pop the newer route',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final decision = HostKeyDecision(
        verdict: HostKeyVerdict.firstUse, presented: key('AAA'));
    final recorded = await openAbovePushedPage(tester, decision,
        navigatorKey: navigatorKey);

    final trust = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Trust and connect'));
    navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Center(child: Text('newer-page'))),
    ));
    await tester.pumpAndSettle();

    // The dialog is no longer the current route, so its trust button must be
    // a no-op — an unguarded pop would dismiss the *newer* page instead.
    trust.onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('newer-page'), findsOneWidget);
    expect(recorded, isEmpty); // the dialog was never answered
    expect(tester.takeException(), isNull);

    // Unwind: the dialog itself is intact and still answerable underneath.
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(recorded, [false]);
  });

  testWidgets('first-use dialog shows the fingerprint and can trust',
      (tester) async {
    final decision = HostKeyDecision(
        verdict: HostKeyVerdict.firstUse, presented: key('AAA'));
    await pumpAndOpen(tester, decision);

    expect(find.text('Unknown host key'), findsOneWidget);
    expect(find.textContaining('SHA256:AAA'), findsOneWidget);
    expect(find.text('Trust and connect'), findsOneWidget);

    await tester.tap(find.text('Trust and connect'));
    await tester.pumpAndSettle();
    expect(find.text('Unknown host key'), findsNothing); // dismissed
  });

  testWidgets('changed-key dialog is a hard block showing both fingerprints',
      (tester) async {
    final decision = HostKeyDecision(
      verdict: HostKeyVerdict.changed,
      presented: key('NEW'),
      pinned: key('OLD'),
    );
    await pumpAndOpen(tester, decision);

    expect(find.text('HOST KEY CHANGED'), findsOneWidget);
    expect(find.textContaining('SHA256:NEW'), findsOneWidget);
    expect(find.textContaining('SHA256:OLD'), findsOneWidget);
    expect(find.text('Trust the new key'), findsOneWidget);
    // A changed-key prompt must not be dismissable by tapping outside.
    expect(find.text('Cancel'), findsOneWidget);
  });
}
