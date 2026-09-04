import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/keyboard_interactive_dialog.dart';

void main() {
  Future<void> openDialog(
    WidgetTester tester, {
    List<String> prompts = const ['Password', 'One-time code'],
    ValueChanged<List<String>>? onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showKeyboardInteractiveDialog(
                  context,
                  prompts,
                  'Authentication',
                  'Answer the server challenge.',
                );
                onResult?.call(result);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('answers are hidden and excluded from keyboard learning', (
    tester,
  ) async {
    await openDialog(tester);
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
    }
  });

  testWidgets('submits every answer in prompt order', (tester) async {
    List<String>? result;
    await openDialog(tester, onResult: (value) => result = value);
    await tester.enterText(find.byType(TextField).at(0), 'a password');
    await tester.enterText(find.byType(TextField).at(1), '012345');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(result, ['a password', '012345']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel with active composition returns no answers', (
    tester,
  ) async {
    List<String>? result;
    await openDialog(tester, onResult: (value) => result = value);
    await tester.showKeyboard(find.byType(TextField).first);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'secret',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long challenges fit above a phone keyboard', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    addTearDown(tester.view.reset);
    await openDialog(
      tester,
      prompts: List.generate(10, (index) => 'Challenge $index'),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byType(TextField).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'last');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
