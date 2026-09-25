import 'dart:ui' show Color;

/// WCAG 2's contrast ratio between two opaque colours, 1 to 21.
///
/// The theme uses it to pick legible text for colours a palette leaves it
/// to choose (the selection pill's label, the accent's), and the preset
/// tests use it to hold every shipped theme to the thresholds the rest of
/// the app already meets. A translucent colour has no contrast of its own:
/// composite it over what it is drawn on first, with [compositeOver].
double contrastRatio(Color a, Color b) {
  final first = a.computeLuminance() + _luminanceOffset;
  final second = b.computeLuminance() + _luminanceOffset;
  return first > second ? first / second : second / first;
}

/// [color] as it shows over the opaque [background].
Color compositeOver(Color color, Color background) =>
    Color.alphaBlend(color, background);

/// White or black, whichever reads better on [background].
Color legibleOn(Color background) =>
    contrastRatio(_white, background) >= contrastRatio(_black, background)
    ? _white
    : _black;

/// The offset in WCAG's relative-luminance ratio (L1 + 0.05) / (L2 + 0.05).
const double _luminanceOffset = 0.05;

const Color _white = Color(0xFFFFFFFF);
const Color _black = Color(0xFF000000);
