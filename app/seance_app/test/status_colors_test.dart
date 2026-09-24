import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/theme.dart';

const _minimumIndicatorContrast = 3.0; // WCAG non-text contrast
const _luminanceOffset = 0.05; // WCAG relative-luminance formula

double _contrast(Color a, Color b) {
  final first = a.computeLuminance() + _luminanceOffset;
  final second = b.computeLuminance() + _luminanceOffset;
  return first > second ? first / second : second / first;
}

void main() {
  for (final theme in [SeanceTheme.light(), SeanceTheme.dark()]) {
    testWidgets('status indicators contrast on ${theme.brightness.name} surfaces',
        (tester) async {
      late List<Color> indicators;
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Builder(builder: (context) {
          indicators = [
            StatusColors.online(context),
            StatusColors.offline(context),
            StatusColors.connecting(context),
            StatusColors.unknown(context),
          ];
          return const SizedBox();
        }),
      ));

      // Selected ListTiles keep the surface background; selection tints text.
      // Hover/focus overlays come from ThemeData rather than a guessed opacity.
      final scheme = theme.colorScheme;
      final backgrounds = [
        scheme.surface,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
        Color.alphaBlend(theme.hoverColor, scheme.surface),
        Color.alphaBlend(theme.focusColor, scheme.surface),
      ];
      for (final indicator in indicators) {
        for (final background in backgrounds) {
          expect(_contrast(indicator, background),
              greaterThanOrEqualTo(_minimumIndicatorContrast),
              reason: '$indicator on $background');
        }
      }
    });
  }

  // The server rows' one dot (server_status_dot.dart) sits on the sibling
  // rail's surfaces: the rail itself, its hover fill, and the selection pill
  // of the focused session's server — and on the phone home's page surface.
  // The dot is ringed in whatever is behind it, so the dot's colour meets
  // exactly these.
  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      final theme = brightness == Brightness.dark
          ? SeanceTheme.dark(platform: platform)
          : SeanceTheme.light(platform: platform);
      testWidgets('row dots contrast on the ${brightness.name} rail, hover and '
          'selection pill (${platform.name})', (tester) async {
        late List<Color> dots;
        late SeanceChrome chrome;
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Builder(builder: (context) {
            chrome = SeanceChrome.of(context);
            dots = [
              StatusColors.online(context),
              StatusColors.connecting(context),
              StatusColors.offline(context),
            ];
            return const SizedBox();
          }),
        ));
        final page = theme.colorScheme.surface;
        final surfaces = {
          'rail': chrome.sidebarBackground,
          'rail hover': Color.alphaBlend(
            chrome.hoverFill,
            chrome.sidebarBackground,
          ),
          'selection pill': Color.alphaBlend(
            chrome.inactiveSelectionFill,
            chrome.sidebarBackground,
          ),
          'home page': page,
          'home hover': Color.alphaBlend(chrome.hoverFill, page),
          'home selection pill': Color.alphaBlend(
            chrome.inactiveSelectionFill,
            page,
          ),
        };
        for (final dot in dots) {
          for (final MapEntry(key: name, value: surface) in surfaces.entries) {
            expect(_contrast(dot, surface),
                greaterThanOrEqualTo(_minimumIndicatorContrast),
                reason: '$dot on the $name ($surface)');
          }
        }
      });
    }
  }
}
