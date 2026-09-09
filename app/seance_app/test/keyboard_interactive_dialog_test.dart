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

  /// Opens the dialog above a pushed page, as a real prompt does, so the
  /// page below is a concrete route a stray pop could take with it.
  Future<List<List<String>>> openAbovePushedPage(
    WidgetTester tester, {
    required GlobalKey<NavigatorState> navigatorKey,
  }) async {
    final recorded = <List<String>>[];
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Center(child: Text('home-page'))),
    ));
    navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () async => recorded.add(
                  await showKeyboardInteractiveDialog(
                      context,
                      const ['Password', 'One-time code'],
                      'Authentication',
                      'Answer the server challenge.')),
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

  testWidgets('a rapid double submit cannot pop the page below the dialog',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final recorded =
        await openAbovePushedPage(tester, navigatorKey: navigatorKey);
    await tester.enterText(find.byType(TextField).at(0), 'a password');
    await tester.enterText(find.byType(TextField).at(1), '012345');

    // Two activations in one turn: the first starts the exit animation, and
    // the second must not pop whatever sits below the half-dismissed dialog.
    final submit =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Submit'));
    submit.onPressed!();
    submit.onPressed!();
    await tester.pumpAndSettle();

    expect(recorded, [
      ['a password', '012345']
    ]); // the first answer survives, unchanged
    expect(find.text('home-page'), findsNothing); // the pushed page was not popped
    expect(find.text('open-dialog'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rapid double cancel keeps the empty-list answer',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final recorded =
        await openAbovePushedPage(tester, navigatorKey: navigatorKey);

    final cancel =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'));
    cancel.onPressed!();
    cancel.onPressed!();
    await tester.pumpAndSettle();

    expect(recorded, [
      <String>[]
    ]); // one cancel; the second activation is a no-op
    expect(find.text('home-page'), findsNothing);
    expect(find.text('open-dialog'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a callback from an obscured dialog cannot answer the newer route',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final recorded =
        await openAbovePushedPage(tester, navigatorKey: navigatorKey);
    await tester.enterText(find.byType(TextField).at(0), 'a password');
    await tester.enterText(find.byType(TextField).at(1), '012345');
    final submit =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Submit'));

    navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Center(child: Text('newer-page'))),
    ));
    await tester.pumpAndSettle();

    // The dialog is no longer the current route, so its submit must be a
    // no-op — an unguarded pop would dismiss and answer the *newer* page.
    submit.onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('newer-page'), findsOneWidget);
    expect(recorded, isEmpty); // the dialog was never answered
    expect(tester.takeException(), isNull);

    // Unwind: the dialog itself is intact and still answerable underneath.
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'other');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(recorded, [
      <String>[]
    ]);
  });

  testWidgets('answers are hidden and excluded from keyboard learning', (
    tester,
  ) async {
    await openDialog(tester);
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.obscureText, isTrue);
      expect(field.keyboardType, TextInputType.visiblePassword);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
    }
  });

  testWidgets('reveals only the chosen answer and can hide it again', (
    tester,
  ) async {
    await openDialog(tester);
    await tester.enterText(find.byType(TextField).first, 'operator');
    await tester.tap(find.byTooltip('Show answer').first);
    await tester.pump();

    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.obscureText, isFalse);
    expect(fields.first.controller!.text, 'operator');
    expect(fields.last.obscureText, isTrue);
    expect(fields.first.enableIMEPersonalizedLearning, isFalse);
    final editable = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(editable.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.byTooltip('Hide answer'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField).first).obscureText,
        isTrue);
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
    final controller =
        tester.widget<TextField>(find.byType(TextField).first).controller!;
    expect(controller.text, 'secret');
    expect(controller.value.composing, const TextRange(start: 0, end: 6));
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
    final keyboardTop = (tester.view.physicalSize.height -
            tester.view.viewInsets.bottom) /
        tester.view.devicePixelRatio;
    expect(tester.getRect(find.text('Submit')).bottom, lessThan(keyboardTop));
    expect(tester.getRect(find.text('Cancel')).bottom, lessThan(keyboardTop));
    expect(tester.getRect(find.byType(TextField).last).bottom,
        lessThan(keyboardTop));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
