import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import 'color_picker.dart';
import 'server_appearance.dart';

/// Picks a colour of the user's own for a server's accent.
///
/// Returns the chosen colour, or null if the dialog was dismissed. [mark] is
/// what the server is currently marked with, so the preview shows the badge
/// the colour will actually be drawn under rather than an empty swatch.
Future<Color?> showServerColorPicker(
  BuildContext context, {
  required Color initial,
  required ServerMark mark,
}) {
  return showColorPicker(
    context,
    initial: initial,
    preview: (context, color) {
      // One tint for both halves of the preview: the bar and the badge show
      // the same colour two ways, and building it twice is how they drift
      // apart.
      final tint = ServerTint(custom: color);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Previewed as the list will draw it, in this theme: the line and
          // the fill are derived from the picked colour rather than painted
          // raw, and this is where that shows.
          ServerAccentBar(tint: tint, height: 48),
          const SizedBox(width: 12),
          ServerBadge(tint: tint, mark: mark, size: 48),
        ],
      );
    },
    note:
        'Drawn as picked, with the mark kept legible on it in both '
        'themes. Devices running an older version show the nearest of '
        'the named colours instead.',
  );
}
