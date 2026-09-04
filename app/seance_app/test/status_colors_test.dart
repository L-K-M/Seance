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
}
