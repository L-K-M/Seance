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
    final effectiveStyle =
        style ?? DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final dir = Directionality.of(context);

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
          return Text(text,
              style: effectiveStyle, maxLines: 1, softWrap: false);
        }
        // Binary-search the largest number of characters (split head+tail
        // around a middle ellipsis) that still fits.
        var lo = 0;
        var hi = text.length;
        var best = _ellipsis;
        while (lo <= hi) {
          final keep = (lo + hi) ~/ 2;
          final head = keep - keep ~/ 2;
          final tail = keep ~/ 2;
          final candidate = head + tail >= text.length
              ? text
              : '${text.substring(0, head)}$_ellipsis'
                  '${text.substring(text.length - tail)}';
          if (widthOf(candidate) <= maxWidth) {
            best = candidate;
            lo = keep + 1;
          } else {
            hi = keep - 1;
          }
        }
        return Text(best, style: effectiveStyle, maxLines: 1, softWrap: false);
      },
    );
  }
}
