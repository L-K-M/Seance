import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/system_fonts.dart';
import 'package:seance_app/ui/font_picker.dart';

/// The terminal font picker. Driven with a stand-in font source, so what the
/// dialog offers never depends on what is installed on the machine running
/// the suite.
void main() {
  const families = [
    SystemFontFamily(name: 'Cantarell', monospaced: false),
    SystemFontFamily(name: 'Hack', monospaced: true),
    SystemFontFamily(name: 'Iosevka Term', monospaced: true),
  ];

  /// Holds what the picker returned. A box rather than a bare variable so the
  /// distinction between "not closed yet" and "dismissed" — both of which read
  /// as null — cannot be lost.
  final picked = <String?>[];

  setUp(picked.clear);

  /// Pumps a screen with one button and taps it, leaving the picker open.
  Future<void> open(
    WidgetTester tester, {
    List<SystemFontFamily> available = families,
    String current = '',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked.add(
                await showFontPicker(
                  context,
                  fonts: _FakeFonts(available),
                  current: current,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('starts filtered to fixed-pitch families', (tester) async {
    await open(tester);

    // A terminal wants fixed pitch, so that is the list you land on.
    expect(find.text('Hack'), findsOneWidget);
    expect(find.text('Iosevka Term'), findsOneWidget);
    expect(find.text('Cantarell'), findsNothing);

    // …and the proportional ones are one tap away, because the flag the
    // filter reads is the font's own and some faces get it wrong.
    await tester.tap(find.widgetWithText(FilterChip, 'Monospace only'));
    await tester.pumpAndSettle();
    expect(find.text('Cantarell'), findsOneWidget);
  });

  testWidgets('previews each family in its own face', (tester) async {
    await open(tester);

    // The whole point of the list: the name is drawn in the face it names, so
    // a family can be judged rather than guessed at from its name.
    final label = tester.widget<Text>(find.text('Hack'));
    expect(label.style?.fontFamily, 'Hack');
    // …with the app's own stack behind it, so a family the engine declines
    // still reads as text instead of as missing-glyph boxes.
    expect(label.style?.fontFamilyFallback, contains('JetBrains Mono'));
  });

  testWidgets('the search field narrows the list', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), 'iose');
    await tester.pumpAndSettle();
    expect(find.text('Iosevka Term'), findsOneWidget);
    expect(find.text('Hack'), findsNothing);

    // A query that matches nothing says which of the two filters to loosen.
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.textContaining('No font matches'), findsOneWidget);
  });

  testWidgets('picking a family returns it', (tester) async {
    await open(tester);
    await tester.tap(find.text('Iosevka Term'));
    await tester.pumpAndSettle();
    expect(picked, ['Iosevka Term']);
  });

  testWidgets('marks the family already in force', (tester) async {
    await open(tester, current: 'Hack');
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Hack')).selected,
      isTrue,
    );
  });

  testWidgets('the family in force survives the fixed-pitch filter', (
    tester,
  ) async {
    // The dialog starts filtered and the flag is the font's own, so a face
    // that is fixed-pitch without declaring it — typed into the free-text
    // field — would open the picker with nothing selected, reading as "your
    // font is not installed".
    await open(tester, current: 'Cantarell');
    expect(find.text('Cantarell'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    // Still filtered for everything else.
    expect(find.text('Iosevka Term'), findsOneWidget);
  });

  testWidgets('the built-in stack is its own choice', (tester) async {
    await open(tester, current: 'Hack');
    await tester.tap(find.text('Use built-in stack'));
    await tester.pumpAndSettle();
    // The empty string, not null: null is "dismissed, change nothing", and if
    // the two collapsed then Cancel would clear the field.
    expect(picked, [kBuiltInFontStack]);
  });

  testWidgets('cancelling changes nothing', (tester) async {
    await open(tester, current: 'Hack');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(picked, [null]);
  });

  testWidgets('a host with nothing readable says to type the name', (
    tester,
  ) async {
    await open(tester, available: const []);
    expect(find.textContaining('Type the family name'), findsOneWidget);
  });
}

class _FakeFonts implements SystemFonts {
  final List<SystemFontFamily> available;
  const _FakeFonts(this.available);

  @override
  bool get isSupported => true;

  @override
  Future<List<SystemFontFamily>> families() async => available;
}
