import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/server_appearance.dart';
import 'package:seance_app/ui/server_color_picker.dart';
import 'package:seance_core/seance_core.dart';

/// Choosing a colour of one's own for a server. The dialog holds the colour
/// two ways — exactly, and as the sliders — and the tests are mostly about the
/// two staying in step.
void main() {
  /// What the picker returned, as a list so "not closed yet" and "dismissed"
  /// stay distinguishable.
  final picked = <Color?>[];

  setUp(picked.clear);

  const initial = Color(0xFF2F6FED);

  Future<void> open(WidgetTester tester, {Color start = initial}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked.add(
                await showServerColorPicker(
                  context,
                  initial: start,
                  mark: const ServerGlyphMark(ServerIcon.rocket),
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

  /// The colour the preview badge is drawn with right now.
  Color preview(WidgetTester tester) =>
      tester.widget<ServerBadge>(find.byType(ServerBadge)).tint.custom!;

  /// The hue, saturation and brightness sliders, in that order.
  List<Slider> sliders(WidgetTester tester) =>
      tester.widgetList<Slider>(find.byType(Slider)).toList();

  Future<void> use(WidgetTester tester) async {
    await tester.tap(find.text('Use colour'));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the colour handed in and returns it as it was', (
    tester,
  ) async {
    await open(tester);
    expect(preview(tester), initial);
    expect(find.text('2F6FED'), findsOneWidget);
    // The mark is previewed on the colour, not a bare swatch: the whole
    // question is what this badge will look like.
    expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
    await use(tester);
    // Exactly, not after a trip through the sliders' floating point.
    expect(picked.single, initial);
  });

  testWidgets('a typed hex value moves the preview and the sliders', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'e03131');
    await tester.pump();
    expect(preview(tester), const Color(0xFFE03131));
    final hsv = HSVColor.fromColor(const Color(0xFFE03131));
    expect(sliders(tester)[0].value, closeTo(hsv.hue, 0.01));
    expect(sliders(tester)[1].value, closeTo(hsv.saturation, 0.01));
    expect(sliders(tester)[2].value, closeTo(hsv.value, 0.01));
    // Not re-cased under the caret while typing.
    expect(find.text('e03131'), findsOneWidget);
    await use(tester);
    expect(picked.single, const Color(0xFFE03131));
  });

  testWidgets('a value that is not a colour is flagged and changes nothing', (
    tester,
  ) async {
    await open(tester);
    // Letters past F never get in: the box filters, so junk is impossible to
    // type and a pasted `#` is dropped rather than refused.
    await tester.enterText(find.byType(TextField), 'zz');
    await tester.pump();
    expect(find.text('Six hex digits'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await tester.enterText(find.byType(TextField), '#e03131');
    await tester.pump();
    expect(preview(tester), const Color(0xFFE03131));
    // Too short is the one way to hold something that is not a colour.
    await tester.enterText(find.byType(TextField), '1e9');
    await tester.pump();
    expect(find.text('Six hex digits'), findsOneWidget);
    expect(preview(tester), const Color(0xFFE03131));
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Use colour'))
          .enabled,
      isFalse,
      reason: 'confirming would hand back a colour the box does not show',
    );
    // Emptying the box is not an error, just nothing yet.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('Six hex digits'), findsNothing);
    expect(preview(tester), const Color(0xFFE03131));
    await use(tester);
    expect(picked.single, const Color(0xFFE03131));
  });

  testWidgets('dragging a slider moves the preview and the hex box', (
    tester,
  ) async {
    await open(tester);
    final hue = find.byType(Slider).first;
    // Rightwards by a fifth of the track: hue goes up, whatever the exact
    // geometry of the slider.
    await tester.drag(hue, Offset(tester.getSize(hue).width / 5, 0));
    await tester.pumpAndSettle();
    final before = HSVColor.fromColor(initial);
    final after = HSVColor.fromColor(preview(tester));
    expect(after.hue, greaterThan(before.hue + 10));
    expect(
      (after.saturation - before.saturation).abs(),
      lessThan(0.02),
      reason: 'the other two axes hold still',
    );
    expect(find.text('2F6FED'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      formatServerCustomColor(preview(tester)).substring(1),
    );
  });

  testWidgets('a hue survives being desaturated', (tester) async {
    // A grey has no hue, so deriving the sliders from the colour would snap
    // the hue slider to zero the moment saturation hit the floor — and
    // bringing saturation back would come back red rather than blue.
    await open(tester);
    final startHue = sliders(tester)[0].value;
    final saturation = find.byType(Slider).at(1);
    await tester.drag(saturation, Offset(-tester.getSize(saturation).width, 0));
    await tester.pumpAndSettle();
    expect(sliders(tester)[1].value, 0);
    expect(sliders(tester)[0].value, startHue);
  });

  testWidgets('cancelling returns nothing', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '000000');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(picked, [null]);
  });
}
