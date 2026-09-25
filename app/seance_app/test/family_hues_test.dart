import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/family_hues.dart';
import 'package:seance_app/theme.dart';

const _minimumNonTextContrast = 3.0; // WCAG non-text contrast
const _luminanceOffset = 0.05; // WCAG relative-luminance formula

double _contrast(Color a, Color b) {
  final first = a.computeLuminance() + _luminanceOffset;
  final second = b.computeLuminance() + _luminanceOffset;
  return first > second ? first / second : second / first;
}

/// The sibling apps' colour vocabulary (Poltergeist's D34) on Séance's
/// surfaces: every hue's bare glyph on every chrome surface a glyph sits
/// on (the panels, the terminal's tab strip, menus), at rest and
/// hovered, and every tile glyph on both ends of its lit fill.
void main() {
  for (final theme in [SeanceTheme.light(), SeanceTheme.dark()]) {
    final brightness = theme.brightness;
    final chrome = theme.extension<SeanceChrome>()!;
    final scheme = theme.colorScheme;
    final palette = theme.extension<FamilyPalette>();

    group('${brightness.name} theme', () {
      test('carries the family palette for its brightness', () {
        expect(palette, same(FamilyPalette.forBrightness(brightness)));
      });

      test('every glyph hue stays ≥ 3:1 on every chrome surface', () {
        final surfaces = <(String, Color)>[
          ('pane', chrome.paneBackground),
          ('sidebar', chrome.sidebarBackground),
          ('header', chrome.headerBackground),
          ('capsule', chrome.capsuleFill),
          ('tab strip', scheme.surfaceContainerHighest),
          ('menu', scheme.surfaceContainer),
        ];
        for (final hue in FamilyHue.values) {
          for (final (name, surface) in surfaces) {
            for (final (state, background) in [
              (name, surface),
              ('$name hovered', Color.alphaBlend(chrome.hoverFill, surface)),
            ]) {
              expect(
                _contrast(palette!.glyph(hue), background),
                greaterThanOrEqualTo(_minimumNonTextContrast),
                reason: '${hue.name} glyph on $state (${brightness.name})',
              );
            }
          }
        }
      });

      test('graphite is the neutrals\' secondary text', () {
        expect(palette!.glyph(FamilyHue.graphite), chrome.secondaryText);
      });
    });
  }

  test('every tile glyph stays ≥ 3:1 on both ends of its fill', () {
    for (final hue in FamilyHue.values) {
      for (final (end, fill) in [
        ('sheen', hue.tileSheen),
        ('fill', hue.tileFill),
      ]) {
        expect(
          _contrast(hue.onTile, fill),
          greaterThanOrEqualTo(_minimumNonTextContrast),
          reason: '${hue.name} tile glyph on its $end',
        );
      }
    }
  });
}
