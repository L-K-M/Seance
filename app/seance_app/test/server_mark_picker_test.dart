import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/server_mark_picker.dart';
import 'package:seance_core/seance_core.dart';

/// Choosing what a server is marked with. The image tab reads its bytes
/// through an injected function, because the platform file picker cannot be
/// driven from a widget test — everything after that point is the real path.
void main() {
  /// What the picker returned, as a list so "not closed yet" and "dismissed"
  /// stay distinguishable.
  final picked = <ServerMark?>[];

  setUp(picked.clear);

  Future<void> open(
    WidgetTester tester, {
    ServerMark current = const ServerGlyphMark(null),
    ServerColor? accent,
    Future<Uint8List?> Function()? readImage,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked.add(
                await showServerMarkPicker(
                  context,
                  current: current,
                  accent: accent,
                  readImage: readImage ?? () async => null,
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

  /// An 8x8 PNG, the shape a real import arrives in.
  Future<Uint8List> samplePng() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 8, 8),
      ui.Paint()..color = const ui.Color(0xFF00AAFF),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(8, 8);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    image.dispose();
    return data!.buffer.asUint8List();
  }

  group('icons', () {
    testWidgets('opens on the glyphs and files them under headings', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Infrastructure'), findsOneWidget);
      // Further headings are below the fold, and a lazy list has not built
      // them yet — scrolling to one is the assertion that it is really there.
      // The scrollable is named explicitly: a tabbed dialog has more than one.
      await tester.scrollUntilVisible(
        find.text('Services'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Services'), findsOneWidget);
    });

    testWidgets('searching matches the extra terms, not just labels', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'k8s');
      await tester.pumpAndSettle();
      // "Cluster" is not the word anyone types for this.
      expect(find.byTooltip('Cluster'), findsOneWidget);
      expect(find.byTooltip('Mail'), findsNothing);
      expect(find.text('Services'), findsNothing);
    });

    testWidgets('picking a glyph returns it', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'postgres');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Database'));
      await tester.pumpAndSettle();
      expect(picked, [const ServerGlyphMark(ServerIcon.database)]);
    });

    testWidgets('a search with no match says so', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('No icon matches.'), findsOneWidget);
    });
  });

  group('emoji', () {
    testWidgets('opens on the emoji tab when one is in force', (tester) async {
      // The picker should show what is actually on the badge rather than
      // always starting at the glyphs.
      await open(tester, current: ServerEmojiMark('\u{1F680}'));
      expect(find.byTooltip('\u{1F433}'), findsOneWidget);
    });

    testWidgets('a curated emoji can be picked in one tap', (tester) async {
      await open(tester, current: ServerEmojiMark('\u{1F680}'));
      final whale = find.byTooltip('\u{1F433}');
      await tester.ensureVisible(whale);
      await tester.pumpAndSettle();
      await tester.tap(whale);
      await tester.pumpAndSettle();
      expect(picked, [ServerEmojiMark('\u{1F433}')]);
    });

    testWidgets('a typed emoji is accepted and keeps the glyph as fallback', (
      tester,
    ) async {
      await open(tester, current: const ServerGlyphMark(ServerIcon.cloud));
      await tester.tap(find.text('Emoji'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Any emoji'),
          '\u{1F433}');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Use'));
      await tester.pumpAndSettle();
      // The glyph rides along so a build that predates emoji marks — or a
      // device with no emoji font — still draws something that was chosen.
      expect(picked, [ServerEmojiMark('\u{1F433}', fallback: ServerIcon.cloud)]);
    });

    testWidgets('more than one character is refused, not stored', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Emoji'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Any emoji'),
        'not one emoji',
      );
      await tester.pumpAndSettle();
      expect(find.text('One emoji, please.'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Use'))
            .onPressed,
        isNull,
      );
    });
  });

  group('image', () {
    testWidgets('an imported file becomes a mark the protocol will carry', (
      tester,
    ) async {
      final bytes = await tester.runAsync(samplePng);
      await open(
        tester,
        current: const ServerGlyphMark(ServerIcon.web),
        readImage: () async => bytes,
      );
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
      // The tap itself goes inside runAsync: encoding an image runs through
      // the engine's codec, which only completes on the real event loop — the
      // work started in a widget test's fake-async zone would simply hang.
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Choose image…'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      // Frames rather than pumpAndSettle: the preview the encode produced is
      // an Image whose own resolution never settles here.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      final mark = picked.single;
      expect(mark, isA<ServerImageMark>());
      expect(mark!.fallback, ServerIcon.web);
      // Re-encoded rather than passed through, so what the record stores is
      // bounded whatever was picked.
      expect(mark.stored.image, isNotNull);
    });

    testWidgets('a file that is not an image is reported, not stored', (
      tester,
    ) async {
      await open(
        tester,
        readImage: () async => Uint8List.fromList(List.filled(512, 0x41)),
      );
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Choose image…'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('could not be read as an image'),
          findsOneWidget);
      expect(picked, isEmpty, reason: 'the dialog stays open to try again');
    });

    testWidgets('cancelling the file picker leaves the dialog alone', (
      tester,
    ) async {
      await open(tester, readImage: () async => null);
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Choose image…'));
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
      expect(find.text('Server mark'), findsOneWidget);
    });

    testWidgets('removing an image falls back to the glyph beside it', (
      tester,
    ) async {
      final bytes = await tester.runAsync(samplePng);
      // Opens on the image tab, because that is what is in force. The badge
      // preview holds a live Image, so this cannot settle (see above).
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => picked.add(
                  await showServerMarkPicker(
                    context,
                    current: ServerImageMark(
                      bytes!,
                      fallback: ServerIcon.cluster,
                    ),
                    accent: null,
                    readImage: () async => null,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Remove image'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(picked, [const ServerGlyphMark(ServerIcon.cluster)]);
    });
  });

  testWidgets('cancelling changes nothing', (tester) async {
    await open(tester, current: const ServerGlyphMark(ServerIcon.lab));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(picked, [null]);
  });
}
