import 'package:flutter/material.dart';

import 'theme_palette.dart';
import 'theme_presets.dart';

/// Which brightness the palette's Automatic colours follow.
///
/// A device setting beside the palette rather than a field of it, so
/// picking another preset keeps it, as does pasting a theme someone else
/// made on a machine set up the other way round.
enum ThemeModePreference {
  /// The system's light or dark appearance, and its changes while the app
  /// runs.
  system,
  light,
  dark,
}

/// What the app is drawn in: this device's palette and mode, as one value
/// the app's MaterialApp — and the settings window's — rebuilds for, and
/// only for.
@immutable
class AppAppearance {
  const AppAppearance({
    required this.palette,
    this.mode = ThemeModePreference.system,
  });

  /// A device that has never opened Appearance.
  static final AppAppearance initial = AppAppearance(
    palette: ThemePresets.initial,
  );

  final ThemePalette palette;
  final ThemeModePreference mode;

  @override
  bool operator ==(Object other) =>
      other is AppAppearance && other.palette == palette && other.mode == mode;

  @override
  int get hashCode => Object.hash(palette, mode);
}

/// Whether a palette with its own [surface] is light or dark.
///
/// The framework's own estimate: dark below a relative luminance of about
/// 0.34, a cut-off Material biases toward light text rather than WCAG's
/// equal-contrast point (about 0.18). A mid grey at 0.4 is therefore light,
/// and the neutrals this chooses bring the text colour with them.
Brightness surfaceBrightness(Color surface) =>
    ThemeData.estimateBrightnessForColor(surface);

/// The brightness [palette] is drawn at: its own surface's when it sets
/// one — a Solarized pane is dark whatever the system says — otherwise
/// what [mode] asks for, where [ThemeModePreference.system] is [platform].
Brightness resolveBrightness(
  ThemePalette palette,
  Brightness platform,
  ThemeModePreference mode,
) {
  if (palette.surface case final surface?) return surfaceBrightness(surface);
  return automaticBrightness(platform, mode);
}

/// The brightness Automatic colours follow under [mode], whatever the
/// palette: [platform] for [ThemeModePreference.system].
Brightness automaticBrightness(Brightness platform, ThemeModePreference mode) =>
    switch (mode) {
      ThemeModePreference.system => platform,
      ThemeModePreference.light => Brightness.light,
      ThemeModePreference.dark => Brightness.dark,
    };
