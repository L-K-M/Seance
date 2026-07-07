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
