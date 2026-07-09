import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/snippets_pane.dart';

/// Regression tests for the placeholder fill-in dialog's controller lifecycle.
///
/// The controllers must survive the dialog's exit animation: `showDialog`'s
/// future completes when the pop *starts*, but the fields stay mounted for the
/// reverse transition, and the framework may still write to a controller (e.g.
/// `clearComposing()` when the focused field loses focus). Disposing right
/// after the await therefore throws "used after being disposed" in debug
/// builds whenever an IME composing region is active — the normal state while
/// typing on Android/iOS.
void main() {
  Future<Map<String, String>?> openAndCapture(
    WidgetTester tester, {
    required List<String> names,
  }) async {
    Map<String, String>? result;
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showPlaceholderDialog(
                  context,
                  'tail -f …',
                  names,
                );
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(done, isFalse);
    return result;
  }

  testWidgets('insert with an active IME composing region survives the '
      'exit animation and returns the values', (tester) async {
    Map<String, String>? result;
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showPlaceholderDialog(
                  context,
                  'tail -f {{logfile}}',
                  const ['logfile'],
                );
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Type into the autofocused field the way an IME does: with a live
    // composing region (the word being typed is not yet committed).
    await tester.showKeyboard(find.byType(TextField));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'app.log',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 0, end: 7),
      ),
    );
    await tester.pump();

    // Pop via Insert, then pump the whole exit animation. With the old
    // dispose-after-await shape this throws "A TextEditingController was
    // used after being disposed" from the focus-change microtask.
    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(done, isTrue);
    expect(result, {'logfile': 'app.log'});
  });

  testWidgets('cancel returns null and disposes cleanly', (tester) async {
    final result = await openAndCapture(tester, names: const ['a', 'b']);
    expect(result, isNull); // still open

    await tester.showKeyboard(find.byType(TextField).first);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'x',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
