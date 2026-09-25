import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/color_picker.dart';

/// The picker the server colour picker is built on, in the two ways only
/// the Appearance tab uses it: without a preview of its own, and with an
/// opacity slider. The server picker's own test covers the rest.
void main() {
  final picked = <Color?>[];
  setUp(picked.clear);

  Future<void> open(
    WidgetTester tester, {
    required Color start,
    bool allowAlpha = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked.add(
                await showColorPicker(
                  context,
                  initial: start,
                  title: 'Lines',
                  allowAlpha: allowAlpha,
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

  String hex(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('each slider is named to a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await open(tester, start: const Color(0xFF3366CC), allowAlpha: true);
      // The slider's own node carries the name, not only a text beside it.
      final names = ['Hue', 'Saturation', 'Brightness', 'Opacity'];
      for (var i = 0; i < names.length; i++) {
        expect(
          tester.getSemantics(find.byType(Slider).at(i)).label,
          contains(names[i]),
          reason: names[i],
        );
      }
    } finally {
      handle.dispose();
    }
  });

  testWidgets('without a preview it shows the colour as a swatch', (
    tester,
  ) async {
    await open(tester, start: const Color(0xFF336699));
    expect(find.text('Lines'), findsOneWidget);
    expect(
      tester.widget<ColorSwatchBox>(find.byType(ColorSwatchBox)).color,
      const Color(0xFF336699),
    );
    expect(find.byType(Slider), findsNWidgets(3));
  });

  testWidgets('with alpha, the opacity slider and eight digits', (
    tester,
  ) async {
    await open(tester, start: const Color(0x80336699), allowAlpha: true);
    expect(find.byType(Slider), findsNWidgets(4));
    expect(hex(tester), '33669980');

    final opacity = find.byType(Slider).last;
    await tester.drag(opacity, Offset(tester.getSize(opacity).width, 0));
    await tester.pumpAndSettle();
    // Fully opaque is written as six digits again.
    expect(hex(tester), '336699');

    await tester.enterText(find.byType(TextField), '3366990');
    await tester.pump();
    expect(find.text('Six or eight hex digits'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '33669940');
    await tester.pump();
    await tester.tap(find.text('Use colour'));
    await tester.pumpAndSettle();
    expect(picked.single, const Color(0x40336699));
  });

  testWidgets('without alpha, a translucent colour comes back opaque', (
    tester,
  ) async {
    await open(tester, start: const Color(0x80336699));
    expect(hex(tester), '336699');
    await tester.tap(find.text('Use colour'));
    await tester.pumpAndSettle();
    expect(picked.single, const Color(0xFF336699));
  });
}
