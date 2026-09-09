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

    /// Opens the dialog inside a phone-shaped, height-constrained surface with
  /// accessibility-large text — the layout where the review content must stay
  /// reachable by scrolling instead of overflowing past the dialog's bounds.
  Future<void> openConstrained(
      WidgetTester tester, HostKeyDecision decision) async {
    tester.view.physicalSize = const Size(390, 644);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => ElevatedButton(
                    onPressed: () => showHostKeyDialog(context, decision),
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Whether any part of [finder]'s render box is visible — clipped to the
  /// dialog's scroll viewport when the widget scrolls (its layout space
  /// extends below the viewport's bottom even where nothing is painted), or
  /// to the test surface for pinned widgets like the action buttons.
  bool onScreen(WidgetTester tester, Finder finder) {
    final box = tester.renderObject<RenderBox>(finder);
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final scrollFinder = find.ancestor(
        of: finder, matching: find.byType(SingleChildScrollView));
    if (scrollFinder.evaluate().isEmpty) {
      final surfaceHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      return top < surfaceHeight && bottom > 0;
    }
    final viewport = tester.renderObject<RenderBox>(scrollFinder);
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewport.size.height;
    return top < viewportBottom && bottom > viewportTop;
  }

  /// Drags the dialog's scroll view until [done] holds (or the drag cap
  /// runs out, which fails the test) — the dialog's own scroll view is the
  /// drag anchor, so the gesture can never be claimed by the pinned action
  /// bar instead of the scrolling content.
  Future<void> scrollUntil(WidgetTester tester,
      {required bool Function() done,
      Offset delta = const Offset(0, -80)}) async {
    for (var i = 0; i < 40 && !done(); i++) {
      await tester.drag(find.byType(SingleChildScrollView), delta);
      await tester.pumpAndSettle();
    }
    expect(done(), isTrue, reason: 'scroll target never came into view');
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

  // Realistic lengths matter here: a 43-character base64 fingerprint and a
  // multi-label hostname are what make the review tall enough to overflow.
  HostKey realisticKey(String fingerprint) => HostKey(
      host: 'build-server.internal.example.com',
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:$fingerprint',
      pinnedAt: 0);

  testWidgets(
      'changed-key review stays reachable in a constrained layout',
      (tester) async {
    final decision = HostKeyDecision(
      verdict: HostKeyVerdict.changed,
      presented:
          realisticKey('nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8'),
      pinned: realisticKey('br9jFZiF8YHDvV7cGqJ2Wk9mPq3xLz5tNo4vXaQwR2s'),
    );
    await openConstrained(tester, decision);

    // The review must render inside the dialog, not overflow its bounds —
    // the unscrollable content column previously overflowed by hundreds of
    // pixels at this size.
    expect(tester.takeException(), isNull);

    // The previously trusted fingerprint starts below the fold — asserted,
    // so this test cannot silently stop exercising the scroll path if a
    // future layout change ever makes the review fit without scrolling.
    // Scrolling must bring it on screen so the comparison the decision
    // rests on can actually be made.
    final oldPrint = find.textContaining('SHA256:br9jFZ');
    expect(oldPrint, findsOneWidget);
    expect(onScreen(tester, oldPrint), isFalse);
    await scrollUntil(tester, done: () => onScreen(tester, oldPrint));

    // And the scroll travels back: the warning and the new fingerprint
    // return into view from below.
    final warning = find.textContaining('man-in-the-middle');
    final newPrint = find.textContaining('SHA256:nThbg');
    await scrollUntil(
        tester,
        delta: const Offset(0, 80),
        done: () => onScreen(tester, warning) && onScreen(tester, newPrint));

    // The buttons never leave the screen: trust stays one tap away at every
    // scroll position, and the explicit answer still comes back.
    expect(onScreen(tester, find.text('Cancel')), isTrue);
    expect(onScreen(tester, find.text('Trust the new key')), isTrue);
    await tester.tap(find.text('Trust the new key'));
    await tester.pumpAndSettle();
    expect(find.text('HOST KEY CHANGED'), findsNothing); // dismissed
  });

  testWidgets('first-use fingerprint stays reachable in a constrained layout',
      (tester) async {
    final decision = HostKeyDecision(
      verdict: HostKeyVerdict.firstUse,
      presented:
          realisticKey('nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8'),
    );
    await openConstrained(tester, decision);

    expect(tester.takeException(), isNull);

    // The single fingerprint is already on screen at this size — its
    // reachability is what matters here, not a scroll round trip.
    final print = find.textContaining('SHA256:nThbg');
    expect(print, findsOneWidget);
    await scrollUntil(tester, done: () => onScreen(tester, print));

    expect(onScreen(tester, find.text('Cancel')), isTrue);
    expect(onScreen(tester, find.text('Trust and connect')), isTrue);
    await tester.tap(find.text('Trust and connect'));
    await tester.pumpAndSettle();
    expect(find.text('Unknown host key'), findsNothing); // dismissed
  });
}
