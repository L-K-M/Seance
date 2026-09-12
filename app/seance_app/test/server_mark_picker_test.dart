import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/server_appearance.dart';
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
    /// False when a mark in force holds a live [Image]: its resolution never
    /// completes here, so settling would spin forever (see AGENTS.md §5).
    bool settle = true,
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
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  /// A [side]x[side] PNG, the shape a real import arrives in.
  Future<Uint8List> samplePng({int side = 8}) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF00AAFF),
    );
    // Varied content, so a large source does not compress to nothing and the
    // size assertions below are about the re-encode rather than about PNG
    // being good at flat colour.
    for (var i = 0; i < side; i += 4) {
      canvas.drawCircle(
        ui.Offset(i.toDouble(), (i * 7 % side).toDouble()),
        side / 8,
        ui.Paint()
          ..color = ui.Color(0xFF000000 | ((i * 2654435761) & 0xFFFFFF)),
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(side, side);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// [samplePng] run on the real event loop, non-null. The image codec never
  /// completes inside a widget test's fake-async zone, and `runAsync` only
  /// returns null when nested inside another one, which no caller here does.
  Future<Uint8List> samplePngBytes(WidgetTester tester, {int side = 8}) async {
    final bytes = await tester.runAsync(() => samplePng(side: side));
    if (bytes == null) {
      // Rather than a bare null-check crash: runAsync returns null only when
      // it is nested inside another one, which is worth naming.
      throw StateError('samplePngBytes cannot run inside another runAsync');
    }
    return bytes;
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

    testWidgets('a joined emoji counts as the one character it looks like', (
      tester,
    ) async {
      // 👩🏽‍🚀 is four code points and seven code units. The rule is one
      // grapheme cluster, not one code point, so this is accepted whole —
      // the case that breaks first if that is ever rewritten.
      const astronaut = '\u{1F469}\u{1F3FD}\u200D\u{1F680}';
      await open(tester);
      await tester.tap(find.text('Emoji'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Any emoji'),
        astronaut,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Use'));
      await tester.pumpAndSettle();
      expect(picked, [ServerEmojiMark(astronaut)]);
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

  /// Switches to the image tab and presses Choose, with the tap itself inside
  /// [WidgetTester.runAsync]: encoding runs through the engine's codec, which
  /// only completes on the real event loop, and work started in the fake-async
  /// zone would simply hang (AGENTS.md §5). Centralized so a new image test
  /// cannot get the wrapping wrong.
  Future<void> chooseImage(WidgetTester tester) async {
    await tester.tap(find.text('Image'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => tester.tap(find.widgetWithText(FilledButton, 'Choose image…')),
    );
  }

  group('image', () {
    testWidgets('an imported file becomes a mark the protocol will carry', (
      tester,
    ) async {
      final bytes = await samplePngBytes(tester);
      await open(
        tester,
        current: const ServerGlyphMark(ServerIcon.web),
        readImage: () async => bytes,
      );
      await chooseImage(tester);
      // Frames rather than pumpAndSettle: the preview the encode produced is
      // an Image whose own resolution never settles here.
      await pumpUntil(tester, () => picked.isNotEmpty);

      final mark = picked.single;
      expect(mark, isA<ServerImageMark>());
      expect(mark!.fallback, ServerIcon.web);
      // Re-encoded rather than passed through, so what the record stores is
      // bounded whatever was picked.
      expect(mark.stored.image, isNotNull);
      // Decoded first: the cap is a byte budget and the stored form is
      // base64, which is about 4/3 the size. Comparing the string length
      // would be testing a stricter limit than production enforces.
      expect(
        base64Decode(mark.stored.image!).length,
        lessThanOrEqualTo(kMaxServerIconImageBytes),
      );
    });

    testWidgets('a source far larger than the badge is shrunk to fit', (
      tester,
    ) async {
      // The teeth behind the claim above: an 8x8 sample would store the same
      // handful of bytes whether it was re-encoded or passed through, so only
      // a source that has to shrink can show that it did.
      final bytes = await samplePngBytes(tester, side: 1024);
      await open(tester, readImage: () async => bytes);
      await chooseImage(tester);
      await pumpUntil(tester, () => picked.isNotEmpty);

      final stored = picked.single!.stored.image;
      expect(stored, isNotNull);
      expect(
        base64Decode(stored!).length,
        lessThan(bytes.length),
        reason: 'a pass-through would store the source unchanged',
      );
      expect(
        base64Decode(stored).length,
        lessThanOrEqualTo(kMaxServerIconImageBytes),
      );
    });

    testWidgets('a file that is not an image is reported, not stored', (
      tester,
    ) async {
      await open(
        tester,
        readImage: () async => Uint8List.fromList(List.filled(512, 0x41)),
      );
      await chooseImage(tester);
      await pumpUntil(
        tester,
        () => tester.any(find.textContaining('could not be read as an image')),
      );
      expect(picked, isEmpty, reason: 'the dialog stays open to try again');
    });

    testWidgets('a file picker that throws is reported, not swallowed', (
      tester,
    ) async {
      // The platform picker throws for a vanished document provider and a
      // revoked permission, among others. Before this was caught the spinner
      // simply cleared and the dialog sat there.
      await open(
        tester,
        readImage: () async => throw const FileSystemException('gone'),
      );
      await chooseImage(tester);
      await pumpUntil(
        tester,
        () => tester.any(find.textContaining('could not be opened')),
      );
      expect(picked, isEmpty);
      // …and the button is usable again rather than stuck spinning.
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Choose image…'),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('cancelling the file picker leaves the dialog alone', (
      tester,
    ) async {
      await open(tester, readImage: () async => null);
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
      // Deliberately not `chooseImage`: a cancelled picker returns before any
      // codec work starts, so this one path needs no real event loop and can
      // settle normally.
      await tester.tap(find.widgetWithText(FilledButton, 'Choose image…'));
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
      expect(find.text('Server mark'), findsOneWidget);
    });

    testWidgets('removing an image falls back to the glyph beside it', (
      tester,
    ) async {
      final bytes = await samplePngBytes(tester);
      // Opens on the image tab, because that is what is in force.
      await open(
        tester,
        current: ServerImageMark(bytes, fallback: ServerIcon.cluster),
        settle: false,
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Remove image'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(picked, [const ServerGlyphMark(ServerIcon.cluster)]);
    });
  });

  testWidgets('the dialog fits a phone with the keyboard up', (tester) async {
    // Two defects lived here. `Dialog` already pads by
    // MediaQuery.viewInsets, so padding for the keyboard again overflowed
    // the column by 8 pixels; and the emoji tab pinned three lines of prose
    // above its Expanded grid, starving it by another 16. Both were measured
    // before the fix, on the geometry below.
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    final bytes = await samplePngBytes(tester);
    for (final (mark, settles) in <(ServerMark, bool)>[
      (const ServerGlyphMark(null), true),
      (ServerEmojiMark('\u{1F680}'), true),
      // The tallest layout of the three, and the one the two defects lived
      // nearest to. It holds a live Image, so it never settles here.
      (ServerImageMark(bytes, fallback: ServerIcon.web), false),
    ]) {
      await open(tester, current: mark, settle: settles);
      expect(
        tester.takeException(),
        isNull,
        reason: 'no overflow with the keyboard up on $mark',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      if (settles) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump(const Duration(milliseconds: 400));
      }
    }
  });

  testWidgets('the previews carry the colour the server actually uses', (
    tester,
  ) async {
    // Not cosmetic: a mark chosen against the wrong accent was judged on a
    // badge the server will never draw.
    await open(tester, accent: ServerColor.amber);
    final badges = tester.widgetList<ServerBadge>(find.byType(ServerBadge));
    expect(badges, isNotEmpty);
    expect(badges.map((badge) => badge.color).toSet(), {ServerColor.amber});
  });

  testWidgets('cancelling changes nothing', (tester) async {
    await open(tester, current: const ServerGlyphMark(ServerIcon.lab));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(picked, [null]);
  });
}

/// Advances until [done] holds, alternating real time with frames.
///
/// Importing an image needs both: the decode only progresses on the real event
/// loop (reached through [WidgetTester.runAsync]), and what it produces only
/// becomes findable once a frame is built. Polling for the outcome rather than
/// sleeping a fixed budget means a loaded machine makes this slower instead of
/// making it fail for reasons unrelated to the code under test.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    // Surfaced here rather than left to the post-test check: an exception
    // thrown while building would otherwise burn the whole timeout and then
    // fail with "timed out", pointing at the wrong thing.
    expect(tester.takeException(), isNull, reason: 'thrown while importing');
  }
  expect(done(), isTrue, reason: 'timed out waiting for the import to finish');
}
