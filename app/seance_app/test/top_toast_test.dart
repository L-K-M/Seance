import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/top_toast.dart';

void main() {
  testWidgets('top toast shows its message then auto-dismisses', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showTopToast(
                Overlay.of(context),
                message: 'Inserted: ls -la',
                duration: const Duration(seconds: 3),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump(); // insert the overlay entry
    await tester.pump(const Duration(milliseconds: 200)); // fade/slide in
    expect(find.text('Inserted: ls -la'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4)); // past the duration
    await tester.pump(); // process removal
    expect(find.text('Inserted: ls -la'), findsNothing);
  });
}
