import 'package:characters/characters.dart' as characters;
import 'package:flutter/material.dart';

/// A single-line text that truncates in the MIDDLE with an ellipsis when it
/// doesn't fit, e.g. `prod-web-01…-eu-west` — Flutter's built-in
/// [TextOverflow.ellipsis] only trims the end, which hides the distinguishing
/// tail of long server names.
class MiddleEllipsisText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  const MiddleEllipsisText(this.text, {super.key, this.style});

  static const _ellipsis = '…';

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final dir = Directionality.of(context);
    final graphemes = characters.Characters(text).toList(growable: false);

    Text renderedText(String visibleText) => Text(
      visibleText,
      style: effectiveStyle,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      semanticsLabel: text,
    );

    double widthOf(String s) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: effectiveStyle),
        maxLines: 1,
        textScaler: scaler,
        textDirection: dir,
      )..layout();
      final width = tp.width;
      tp.dispose(); // TextPainter holds a native paragraph; don't leak it
      return width;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (maxWidth.isInfinite || widthOf(text) <= maxWidth) {
          return renderedText(text);
        }
        // Search extended grapheme clusters so truncation never splits a
        // surrogate pair, combining sequence, flag, or ZWJ emoji.
        var lo = 0;
        var hi = graphemes.length - 1;
        var best = _ellipsis;
        while (lo <= hi) {
          final keep = (lo + hi) ~/ 2;
          final head = keep - keep ~/ 2;
          final tail = keep ~/ 2;
          final candidate =
              '${graphemes.take(head).join()}$_ellipsis'
              '${graphemes.skip(graphemes.length - tail).join()}';
          if (widthOf(candidate) <= maxWidth) {
            best = candidate;
            lo = keep + 1;
          } else {
            hi = keep - 1;
          }
        }
        return renderedText(best);
      },
    );
  }
}
