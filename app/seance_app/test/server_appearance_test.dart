import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
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

void main() {
  group('ServerBadge', () {
    testWidgets('an untagged server gets the default glyph', (tester) async {
      await tester.pumpWidget(
        _wrap(ServerBadge.glyph(color: null, icon: null)),
      );
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    });

    testWidgets('the chosen icon is the one drawn', (tester) async {
      await tester.pumpWidget(
        _wrap(ServerBadge.glyph(color: null, icon: ServerIcon.rocket)),
      );
      expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
      expect(find.byIcon(Icons.dns_outlined), findsNothing);
    });

    testWidgets('a colour changes the fill; none leaves it neutral', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(ServerBadge.glyph(color: null, icon: null)));
      final neutral = _badgeFill(tester);

      await tester.pumpWidget(
        _wrap(ServerBadge.glyph(color: ServerColor.red, icon: null)),
      );
      expect(_badgeFill(tester), isNot(neutral));
    });

    testWidgets('the same accent resolves differently per brightness', (
      tester,
    ) async {
      // The point of storing a name rather than an ARGB value: a colour picked
      // in light mode still has to be legible in dark mode.
      await tester.pumpWidget(
        _wrap(ServerBadge.glyph(color: ServerColor.teal, icon: null)),
      );
      final light = _badgeFill(tester);

      await tester.pumpWidget(
        _wrap(
          ServerBadge.glyph(color: ServerColor.teal, icon: null),
          brightness: Brightness.dark,
        ),
      );
      expect(_badgeFill(tester), isNot(light));
    });

    testWidgets('every colour and every glyph renders', (tester) async {
      // Cheap insurance that the enums and their mappings stay exhaustive: a
      // value added to the protocol without a case fails the switch at compile
      // time, and one added without a seed would throw right here. Each enum
      // is swept once rather than against the other — the two mappings are
      // independent, and the cross product is seventy-odd times the frames for
      // nothing.
      for (final color in ServerColor.values) {
        await tester.pumpWidget(_wrap(ServerBadge.glyph(color: color, icon: null)));
        expect(find.byType(ServerBadge), findsOneWidget);
      }
      for (final icon in ServerIcon.values) {
        await tester.pumpWidget(
          _wrap(ServerBadge.glyph(color: ServerColor.violet, icon: icon)),
        );
        expect(find.byIcon(serverIconData(icon)), findsOneWidget,
            reason: icon.name);
      }
    });
  });

  group('ServerAvatar', () {
    testWidgets('carries the connection status alongside the badge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ServerAvatar(
            server: _server(color: ServerColor.red, icon: ServerIcon.rocket),
            connection: TerminalStatus.connected,
          ),
        ),
      );
      expect(find.byType(ServerBadge), findsOneWidget);
      expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
      expect(
        find.byTooltip('connected'),
        findsOneWidget,
        reason: 'the status dot keeps the tooltip it had as a standalone dot',
      );
    });

    testWidgets('shows a spinner while connecting', (tester) async {
      await tester.pumpWidget(
        _wrap(
          ServerAvatar(
            server: _server(),
            connection: TerminalStatus.connecting,
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byTooltip('connecting'), findsOneWidget);
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
      expect(serverAccent(captured, null), isNull);
      expect(serverAccent(captured, ServerColor.violet), isNotNull);
    });
  });

  group('richer marks', () {
    /// An 8x8 solid PNG, built here rather than encoded through the real
    /// import path: this group is about what the badge *draws*, and asserting
    /// on the encoded bytes is `badge_image_test.dart`'s job.
    Future<Uint8List> pngBytes() async {
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
      return data!.buffer.asUint8List();
    }

    testWidgets('an emoji mark is drawn as text, not as a glyph', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ServerBadge(
            color: ServerColor.violet,
            mark: ServerEmojiMark('\u{1F680}'),
          ),
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
            color: null,
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
        _wrap(ServerBadge.glyph(color: null, icon: ServerIcon.database)),
      );
      expect(
        tester.widget<Icon>(find.byType(Icon)).semanticLabel,
        'Database',
      );
    });

    testWidgets('an image mark is drawn from its bytes', (tester) async {
      final bytes = await tester.runAsync(pngBytes);
      await tester.pumpWidget(
        _wrap(ServerBadge(color: null, mark: ServerImageMark(bytes!))),
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
            color: null,
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
          ),
        ),
      );
      expect(find.text('\u{1F427}'), findsOneWidget);
      expect(find.byIcon(Icons.rocket_launch_outlined), findsNothing);
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
  int attempts = 50,
}) async {
  for (var i = 0; i < attempts && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'timed out waiting for $what');
}
