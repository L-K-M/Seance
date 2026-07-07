import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:seance_app/main.dart';

/// Regression tests for the bootstrap structure. Two real bugs shipped here:
///  - AppScope lived below the Navigator, so the pushed Settings route
///    couldn't resolve it (grey screen in release);
///  - the fix for that swapped whole MaterialApps between bootstrap phases,
///    moving the global navigatorKey mid-frame (frozen spinner in release).
///
/// The real _init() hangs in the widget-test environment (its
/// platform-channel futures never complete under fake-async), so the tests
/// drive the phase transition through SeanceApp's initOverride seam.
void main() {
  testWidgets('bootstrap phase changes stay inside one MaterialApp',
      (tester) async {
    await tester.pumpWidget(
      SeanceApp(initOverride: () async => throw StateError('boom')),
    );
    // Spinner first, then the error phase. With a per-phase MaterialApp swap
    // this transition throws a duplicate-GlobalKey error in debug (and
    // freezes the frame in release builds).
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed to start Séance'), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('routes pushed on the root navigator can see AppScope',
      (tester) async {
    await tester.pumpWidget(
      SeanceApp(initOverride: () async => throw StateError('boom')),
    );
    await tester.pumpAndSettle();

    // The Settings screen is a pushed route; it resolves AppScope from a
    // context that lives directly under the Navigator, not under `home:`.
    late BuildContext routeContext;
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) {
          routeContext = context;
          return const SizedBox();
        },
      ),
    );
    await tester.pumpAndSettle();

    final scope = routeContext.dependOnInheritedWidgetOfExactType<AppScope>();
    expect(scope, isNotNull,
        reason: 'AppScope must wrap the Navigator so pushed routes see it');
  });
}
