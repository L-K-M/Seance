import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/server_appearance.dart';
import 'package:seance_core/seance_core.dart';

ServerConfig _server({ServerColor? color, ServerIcon? icon}) => ServerConfig(
  id: 's1',
  label: 'prod web',
  host: 'web.example.com',
  username: 'deploy',
  authMethod: AuthMethod.password,
  color: color,
  icon: icon,
  createdAt: 0,
  updatedAt: 0,
);

/// The brightness is applied with an explicit [Theme] rather than
/// `MaterialApp.theme`, which is only *a candidate* — MaterialApp still picks
/// between it and `darkTheme` using the platform brightness, and would have
/// handed both halves of the brightness test the same light scheme.
Widget _wrap(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      home: Theme(
        data: ThemeData(brightness: brightness),
        child: Scaffold(body: Center(child: child)),
      ),
    );

/// The badge's fill, read back off the widget tree. `.first` because the
/// badge clips its content, and a child mark may bring Containers of its own.
Color? _badgeFill(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.byType(ServerBadge),
          matching: find.byType(Container),
        )
        .first,
  );
  return (container.decoration as BoxDecoration?)?.color;
}

/// An 8x8 solid PNG, built here rather than encoded through the real import
/// path: these tests are about what the badge *draws*, and asserting on the
/// encoded bytes is `badge_image_test.dart`'s job.
Future<Uint8List> _pngBytes() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 8, 8),
    ui.Paint()..color = const ui.Color(0xFF00FF00),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// The line a [ServerAccentBar] paints, or null when it paints none.
Color? _barColor(WidgetTester tester) {
  final painted = find.descendant(
    of: find.byType(ServerAccentBar),
    matching: find.byType(DecoratedBox),
  );
  if (painted.evaluate().isEmpty) return null;
  return (tester.widget<DecoratedBox>(painted).decoration as BoxDecoration)
      .color;
}

ServerAvatar _idleAvatar(ServerConfig server) => ServerAvatar(
  server: server,
  connection: TerminalStatus.disconnected,
  hasSession: false,
);

void main() {
  group('ServerAccentBar', () {
    testWidgets('a colour draws a line; none draws nothing', (tester) async {
      await tester.pumpWidget(
        _wrap(const ServerAccentBar(tint: ServerTint.none)),
      );
      expect(_barColor(tester), isNull);
      // The slot stays either way, so the marks of coloured and uncoloured
      // servers line up in one column.
      expect(
        tester.getSize(find.byType(ServerAccentBar)).width,
        ServerAccentBar.width,
      );

      await tester.pumpWidget(
        _wrap(const ServerAccentBar(tint: ServerTint(named: ServerColor.red))),
      );
      expect(_barColor(tester), isNotNull);
      expect(
        tester.getSize(find.byType(ServerAccentBar)).width,
        ServerAccentBar.width,
      );
    });

    testWidgets('the same accent resolves differently per brightness', (
      tester,
    ) async {
      // The point of storing a name rather than an ARGB value: a colour picked
      // in light mode still has to be legible in dark mode.
      await tester.pumpWidget(
        _wrap(const ServerAccentBar(tint: ServerTint(named: ServerColor.teal))),
      );
      final light = _barColor(tester);

      await tester.pumpWidget(
        _wrap(
          const ServerAccentBar(tint: ServerTint(named: ServerColor.teal)),
          brightness: Brightness.dark,
        ),
      );
      expect(_barColor(tester), isNot(light));
    });

    testWidgets('every colour resolves to a line', (tester) async {
      // Cheap insurance that the enum and its seeds stay in step: a value
      // added to the protocol without a seed would throw right here.
      for (final color in ServerColor.values) {
        await tester.pumpWidget(
          _wrap(ServerAccentBar(tint: ServerTint(named: color))),
        );
        expect(_barColor(tester), isNotNull, reason: color.name);
      }
    });
  });

  group('ServerBadge', () {
    testWidgets('an untagged server gets the default glyph', (tester) async {
      await tester.pumpWidget(
        _wrap(ServerBadge.glyph(icon: null)),
      );
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    });

    testWidgets('the chosen icon is the one drawn', (tester) async {
      await tester.pumpWidget(
        _wrap(ServerBadge.glyph(icon: ServerIcon.rocket)),
      );
      expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
      expect(find.byIcon(Icons.dns_outlined), findsNothing);
    });

    testWidgets('every glyph renders', (tester) async {
      // Cheap insurance that the enum and its mapping stay exhaustive: a value
      // added to the protocol without a case fails the switch at compile time.
      for (final icon in ServerIcon.values) {
        await tester.pumpWidget(_wrap(ServerBadge.glyph(icon: icon)));
        expect(
          find.byIcon(serverIconData(icon)),
          findsOneWidget,
          reason: icon.name,
        );
      }
    });
  });

  group('ServerAvatar', () {
    /// The session ring: the one box under the avatar that is a border and
    /// nothing else. The badge's own fill is a DecoratedBox too.
    final ring = find.descendant(
      of: find.byType(ServerAvatar),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).border != null &&
            (widget.decoration as BoxDecoration).color == null,
      ),
    );

    testWidgets('rings the badge in the session\'s status colour', (
      tester,
    ) async {
      late BuildContext captured;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              captured = context;
              return ServerAvatar(
                server: _server(
                  color: ServerColor.red,
                  icon: ServerIcon.rocket,
                ),
                connection: TerminalStatus.connected,
                hasSession: true,
              );
            },
          ),
        ),
      );
      expect(find.byType(ServerBadge), findsOneWidget);
      expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
      expect(
        find.byTooltip('connected'),
        findsOneWidget,
        reason: 'the ring keeps the tooltip the status dot used to carry',
      );
      expect(ring, findsOneWidget);
      final border =
          (tester.widget<DecoratedBox>(ring).decoration as BoxDecoration)
              .border!;
      expect(border.top.color, StatusColors.online(captured));
    });

    testWidgets('animates the ring while connecting', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ServerAvatar(
            server: _server(),
            connection: TerminalStatus.connecting,
            hasSession: true,
          ),
        ),
      );
      expect(find.byTooltip('connecting'), findsOneWidget);
      // The sweep is a custom painter rather than the static border the
      // other states draw, and it repaints as the highlight travels.
      final sweep = find.descendant(
        of: find.byType(ServerAvatar),
        matching: find.byType(CustomPaint),
      );
      expect(sweep, findsOneWidget);
      final before = tester.widget<CustomPaint>(sweep).painter;
      await tester.pump(const Duration(milliseconds: 300));
      final after = tester.widget<CustomPaint>(sweep).painter;
      expect(after!.shouldRepaint(before!), isTrue);
    });

    testWidgets('holds the connecting ring still under reduced motion', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: ServerAvatar(
              server: _server(),
              connection: TerminalStatus.connecting,
              hasSession: true,
            ),
          ),
        ),
      );
      // The plain frame the other states draw, still labelled: the state
      // is not lost, only the motion.
      expect(find.byTooltip('connecting'), findsOneWidget);
      expect(ring, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ServerAvatar),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
      // Nothing is left ticking either; settling would otherwise never end.
      await tester.pumpAndSettle();
    });

    testWidgets('a first connection with no session yet has no ring', (
      tester,
    ) async {
      // `hasSession` is what the tile says; it is true whenever a tab exists,
      // so this combination is the tile's to avoid, and the avatar's answer
      // to it is pinned so a refactor cannot change it silently.
      await tester.pumpWidget(
        _wrap(
          ServerAvatar(
            server: _server(),
            connection: TerminalStatus.connecting,
            hasSession: false,
          ),
        ),
      );
      expect(find.byTooltip('connecting'), findsNothing);
      expect(ring, findsNothing);
    });

    testWidgets('a server with no session wears no ring', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ServerAvatar(
            server: _server(),
            connection: TerminalStatus.disconnected,
            hasSession: false,
          ),
        ),
      );
      // Nothing to say, so no tooltip either: the old grey dot on every idle
      // row was the state the eye had to tell green apart from.
      expect(find.byTooltip('disconnected'), findsNothing);
      expect(ring, findsNothing);

      // A session that dropped is a session: it keeps its (grey) ring.
      await tester.pumpWidget(
        _wrap(
          ServerAvatar(
            server: _server(),
            connection: TerminalStatus.disconnected,
            hasSession: true,
          ),
        ),
      );
      expect(find.byTooltip('disconnected'), findsOneWidget);
      expect(ring, findsOneWidget);
    });

    testWidgets('the ring is reserved space whether or not it is drawn', (
      tester,
    ) async {
      // Otherwise a session opening would shift every row below it.
      Future<Size> sizeWith({required bool hasSession}) async {
        await tester.pumpWidget(
          _wrap(
            ServerAvatar(
              server: _server(),
              connection: hasSession
                  ? TerminalStatus.connected
                  : TerminalStatus.disconnected,
              hasSession: hasSession,
            ),
          ),
        );
        return tester.getSize(find.byType(ServerAvatar));
      }

      expect(
        await sizeWith(hasSession: true),
        await sizeWith(hasSession: false),
      );
    });
  });

  group('serverAccent', () {
    testWidgets('resolves to null for an uncoloured server', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(serverAccent(captured, ServerTint.none), isNull);
      expect(
        serverAccent(captured, const ServerTint(named: ServerColor.violet)),
        isNotNull,
      );
    });
  });

  group('richer marks', () {
    testWidgets('an emoji mark is drawn as text, not as a glyph', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ServerBadge(mark: ServerEmojiMark('\u{1F680}')),
        ),
      );
      expect(find.text('\u{1F680}'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
      // No colour applied: an emoji carries its own, and tinting it would
      // either do nothing or ruin it.
      expect(tester.widget<Text>(find.text('\u{1F680}')).style?.color, isNull);
    });

    testWidgets('a wide emoji cluster is scaled down, not sliced', (
      tester,
    ) async {
      // A family emoji is wider than the badge, and the badge clips its
      // content — without scaling it would be cut through the middle.
      await tester.pumpWidget(
        _wrap(
          const ServerBadge(
            mark: ServerEmojiMark(
              '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}',
            ),
          ),
        ),
      );
      expect(find.byType(FittedBox), findsOneWidget);
      expect(
        tester.widget<FittedBox>(find.byType(FittedBox)).fit,
        BoxFit.scaleDown,
      );
    });

    testWidgets('a glyph badge tells a screen reader what it is', (
      tester,
    ) async {
      // The badge's whole job is telling servers apart; unlabelled it says
      // nothing at all to assistive technology.
      await tester.pumpWidget(
        _wrap(
          ServerBadge.glyph(icon: ServerIcon.database),
        ),
      );
      expect(
        tester.widget<Icon>(find.byType(Icon)).semanticLabel,
        'Database',
      );
    });

    testWidgets('an image mark is drawn from its bytes', (tester) async {
      final bytes = await tester.runAsync(_pngBytes);
      await tester.pumpWidget(
        _wrap(ServerBadge(mark: ServerImageMark(bytes!))),
      );
      // Not pumpAndSettle: an image codec resolves on the real event loop,
      // which a widget test's fake-async zone never reaches, so settling here
      // would spin forever.
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      // Then let the codec actually finish. Asserting on the first frame only
      // would pass even if the bytes never decoded and the fallback glyph took
      // over a frame later, which is the regression worth catching.
      await _untilDecoded(tester);
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image,
        isNotNull,
        reason: 'the 8x8 fixture should have decoded',
      );
      expect(find.byType(Icon), findsNothing);
      // Cropped to the badge rather than letterboxed: bars down the sides read
      // as a broken image.
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
    });

    testWidgets('bytes that will not decode fall back to the glyph', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ServerBadge(
            mark: ServerImageMark(
              // A PNG signature and nothing behind it: the protocol accepts
              // this shape, so a record really can carry it, and the badge is
              // the last thing standing between that and an exception.
              Uint8List.fromList(const [
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
              ]),
              fallback: ServerIcon.cluster,
            ),
          ),
        ),
      );
      // The decode has to actually run and fail, which needs the real event
      // loop (see above). Polled rather than slept for: the codec's failure
      // path is a platform round trip with no bound a fixed delay could rely
      // on, and this is the kind of flake that looks unrelated to whatever
      // change triggered the rerun.
      // From the mapping rather than a literal: a remapped cluster glyph
      // should fail as a wrong-icon mismatch, not as a poll timeout.
      final fallback = serverIconData(ServerIcon.cluster);
      await _untilFallback(tester, fallback);
      expect(find.byIcon(fallback), findsOneWidget);
      // Absorbed by the errorBuilder, not escaped: asserting null rather than
      // discarding means an unrelated exception during these pumps still
      // fails the test.
      expect(
        tester.takeException(),
        isNull,
        reason: 'the fallback should absorb the decode failure',
      );
    });

    testWidgets('a config draws the mark its fields resolve to', (
      tester,
    ) async {
      // The precedence lives in the protocol; this pins that the list actually
      // asks for it rather than reading `icon` directly.
      await tester.pumpWidget(
        _wrap(
          ServerAvatar(
            server: _server(icon: ServerIcon.rocket).copyWith(
              iconEmoji: '\u{1F427}',
            ),
            connection: TerminalStatus.disconnected,
            hasSession: false,
          ),
        ),
      );
      expect(find.text('\u{1F427}'), findsOneWidget);
      expect(find.byIcon(Icons.rocket_launch_outlined), findsNothing);
    });
  });

  group('custom colours', () {
    Future<BuildContext> context(
      WidgetTester tester, {
      Brightness brightness = Brightness.light,
    }) async {
      late BuildContext captured;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
          brightness: brightness,
        ),
      );
      return captured;
    }

    /// WCAG contrast between two colours, which is what the scheme promises
    /// for a container and its foreground.
    double contrast(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      final (light, dark) = la > lb ? (la, lb) : (lb, la);
      return (light + 0.05) / (dark + 0.05);
    }

    testWidgets('a custom colour is drawn as picked, with a legible mark', (
      tester,
    ) async {
      // The point of a picker over a named list: what was chosen is what is
      // painted, in both themes. The named accents are folded into a pastel
      // by design; a custom one must not be, or the saturation and
      // brightness sliders would do nothing.
      const picks = [
        Color(0xFFE03131),
        Color(0xFF123456),
        Color(0xFFF5F5DC),
        Color(0xFF2B8A3E),
      ];
      for (final brightness in Brightness.values) {
        final ctx = await context(tester, brightness: brightness);
        for (final pick in picks) {
          final accent = serverAccent(ctx, ServerTint(custom: pick))!;
          final want = HSVColor.fromColor(pick);
          final got = HSVColor.fromColor(accent.container);
          var hueDelta = (want.hue - got.hue).abs() % 360;
          if (hueDelta > 180) hueDelta = 360 - hueDelta;
          expect(hueDelta, lessThan(12), reason: '$pick $brightness hue');
          expect(
            (want.saturation - got.saturation).abs(),
            lessThan(0.2),
            reason: '$pick $brightness saturation',
          );
          expect(
            (want.value - got.value).abs(),
            lessThan(0.2),
            reason: '$pick $brightness brightness',
          );
          expect(
            contrast(accent.container, accent.onContainer),
            greaterThanOrEqualTo(4.5),
            reason: '$pick $brightness contrast',
          );
        }
      }
    });

    testWidgets('a custom colour outranks the named accent beside it', (
      tester,
    ) async {
      final ctx = await context(tester);
      final custom = serverAccent(
        ctx,
        const ServerTint(named: ServerColor.red, custom: Color(0xFF123456)),
      )!;
      final named = serverAccent(
        ctx,
        const ServerTint(named: ServerColor.red),
      )!;
      expect(custom.container, isNot(named.container));
      // Outranks, not blends: the named accent contributes nothing.
      expect(
        custom.container,
        serverAccent(ctx, const ServerTint(custom: Color(0xFF123456)))!
            .container,
      );
    });

    test('the stored form round-trips and refuses what the protocol does', () {
      expect(formatServerCustomColor(const Color(0xFF0A0B0C)), '#0A0B0C');
      // Alpha is dropped: the fill is opaque by design.
      expect(formatServerCustomColor(const Color(0x800A0B0C)), '#0A0B0C');
      expect(parseServerCustomColor('#0A0B0C'), const Color(0xFF0A0B0C));
      expect(parseServerCustomColor('0a0b0c'), const Color(0xFF0A0B0C));
      expect(parseServerCustomColor('#0A0B'), isNull);
      expect(parseServerCustomColor(null), isNull);

      final tint = ServerTint.custom(const Color(0xFFE03131));
      expect(tint.stored.customColor, '#E03131');
      expect(tint.stored.color, ServerColor.red);
      expect(
        ServerTint.of(
          _server().copyWith(color: ServerColor.red, customColor: '#e03131'),
        ),
        tint,
      );
      expect(ServerTint.of(_server()), ServerTint.none);
    });

    test('the nearest named accent is judged by hue, greys go to slate', () {
      expect(nearestServerColor(const Color(0xFFE03131)), ServerColor.red);
      expect(nearestServerColor(const Color(0xFF2F6FED)), ServerColor.blue);
      expect(nearestServerColor(const Color(0xFFFFFF00)), ServerColor.amber);
      expect(nearestServerColor(const Color(0xFF7B5CE0)), ServerColor.violet);
      expect(nearestServerColor(const Color(0xFFC2185B)), ServerColor.pink);
      expect(nearestServerColor(const Color(0xFF808080)), ServerColor.slate);
      expect(nearestServerColor(const Color(0xFF64748B)), ServerColor.slate);
      expect(nearestServerColor(const Color(0xFF000000)), ServerColor.slate);
      // Every seed maps to itself, or the fallback would misname the very
      // colour it stands in for.
      for (final color in ServerColor.values) {
        expect(nearestServerColor(serverColorSeed(color)), color);
      }
    });
  });

  group('the mark sits on one neutral tile', () {
    /// The foreground decoration an image mark used to wear as an accent
    /// frame, back when the colour was the badge's fill and an image covered
    /// it. Read back so the colour cannot creep onto the mark again.
    BoxDecoration? frameOf(WidgetTester tester) {
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(ServerBadge),
              matching: find.byType(Container),
            )
            .first,
      );
      return container.foregroundDecoration as BoxDecoration?;
    }

    testWidgets('a server\'s colour leaves its badge alone', (tester) async {
      // The colour is the row's bar; a tinted badge as well would say it
      // twice, and would say it differently on the mark that covers a fill.
      await tester.pumpWidget(_wrap(_idleAvatar(_server())));
      final neutral = _badgeFill(tester);
      expect(neutral, isNotNull);

      for (final color in ServerColor.values) {
        await tester.pumpWidget(_wrap(_idleAvatar(_server(color: color))));
        expect(_badgeFill(tester), neutral, reason: color.name);
        expect(frameOf(tester), isNull, reason: color.name);
      }
    });

    testWidgets('an image mark is drawn on the same tile, unframed', (
      tester,
    ) async {
      final bytes = await tester.runAsync(_pngBytes);
      await tester.pumpWidget(_wrap(ServerBadge.glyph(icon: null)));
      final neutral = _badgeFill(tester);

      await tester.pumpWidget(
        _wrap(ServerBadge(mark: ServerImageMark(bytes!))),
      );
      await tester.pump();
      expect(_badgeFill(tester), neutral);
      expect(frameOf(tester), isNull);

      // The third kind of mark, on the same tile: a per-mark decoration
      // branch coming back is exactly what this group exists to catch.
      await tester.pumpWidget(
        _wrap(const ServerBadge(mark: ServerEmojiMark('\u{1F680}'))),
      );
      expect(_badgeFill(tester), neutral);
      expect(frameOf(tester), isNull);
    });
  });

  group('the glyph table', () {
    test('every glyph is reachable from exactly one heading', () {
      // A glyph missing from the picker's groups is unreachable in the UI
      // while remaining perfectly valid in a record, which is the kind of gap
      // nothing else would notice.
      final grouped = [for (final (_, icons) in serverIconGroups) ...icons];
      expect(grouped.toSet(), ServerIcon.values.toSet());
      expect(
        grouped.length,
        ServerIcon.values.length,
        reason: 'a glyph filed under two headings would appear twice',
      );
    });

    test('every glyph has a label and a distinct name', () {
      for (final icon in ServerIcon.values) {
        expect(serverIconLabel(icon), isNotEmpty, reason: icon.name);
      }
      expect(serverIconLabel(null), 'Default');
      // Two glyphs sharing a label would make the picker ambiguous.
      final labels = ServerIcon.values.map(serverIconLabel).toList();
      expect(labels.toSet().length, labels.length);
    });

    test('search matches labels and the extra terms', () {
      expect(serverIconMatches(ServerIcon.cluster, 'k8s'), isTrue);
      // Both of the examples the doc comments give have to actually work.
      expect(serverIconMatches(ServerIcon.database, 'psql'), isTrue);
      expect(serverIconMatches(ServerIcon.database, 'postgres'), isTrue);
      expect(serverIconMatches(ServerIcon.database, 'DATA'), isTrue);
      expect(serverIconMatches(ServerIcon.rocket, 'prod'), isTrue);
      expect(serverIconMatches(ServerIcon.rocket, 'router'), isFalse);
      expect(serverIconMatches(null, 'def'), isTrue);
      // An empty query matches everything, so the unfiltered list is the whole
      // set rather than nothing.
      expect(serverIconMatches(ServerIcon.pets, '  '), isTrue);
    });

    test('search matches every term, in any order and any case', () {
      // Two words is how people search an icon grid; as one contiguous
      // substring neither label nor keywords ever contains the phrase.
      expect(serverIconMatches(ServerIcon.container, 'docker container'), isTrue);
      expect(serverIconMatches(ServerIcon.container, 'container docker'), isTrue);
      expect(serverIconMatches(ServerIcon.device, 'pi raspberry'), isTrue);
      expect(serverIconMatches(ServerIcon.cluster, 'K8S'), isTrue);
      // Every term still has to land somewhere.
      expect(serverIconMatches(ServerIcon.container, 'docker mail'), isFalse);
    });
  });
}

/// Advances real time and frames until the badge's image has decoded.
Future<void> _untilDecoded(WidgetTester tester) =>
    _until(tester, 'the image to decode', () {
      final images = find.byType(RawImage).evaluate();
      return images.isNotEmpty &&
          (images.first.widget as RawImage).image != null;
    });

/// Advances real time and frames until [icon] appears — the fallback glyph a
/// failed decode swaps in.
Future<void> _untilFallback(WidgetTester tester, IconData icon) => _until(
      tester,
      'the fallback glyph to replace the image',
      () => find.byIcon(icon).evaluate().isNotEmpty,
    );

/// Alternates [WidgetTester.runAsync] with a pump until [done] holds.
///
/// An image codec only progresses on the real event loop, and what it produces
/// is only findable once a frame is built, so neither alone is enough.
/// [what] names the wait, because a timeout here reports the wrong cause
/// otherwise: the fallback waiter is not waiting on a codec.
Future<void> _until(
  WidgetTester tester,
  String what,
  bool Function() done, {
  int attempts = 150,
}) async {
  for (var i = 0; i < attempts && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'timed out waiting for $what');
}
