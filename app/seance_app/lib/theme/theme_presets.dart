import 'dart:ui' show Color;

import '../theme.dart' show SeanceTheme;
import 'theme_palette.dart';

/// The themes Séance ships with, after Vervellum's `ThemePresets.swift`.
///
/// A preset is a starting point, not a mode: picking one copies its values
/// into the device's palette, which the user is then free to change. Every
/// one with its own surface is complete — its own surface, rail, lines,
/// selection, status colours and terminal — because a preset that left
/// the rail Automatic would frame a Solarized pane in slate. The first,
/// Séance, leaves everything Automatic, which is what reproduces the app
/// as it looked before themes existed, and Graphite changes only the
/// accent and the corners over the same Automatic neutrals. A new device
/// starts in Terminal instead ([initial]).
///
/// Each has to pass `theme_presets_test.dart`: text and secondary text on
/// its surface and rail, the accent and every status colour on its
/// surface, the selection pill's label, and the terminal's text and ANSI
/// colours on its background — the thresholds the default neutrals already
/// meet. The accents are Vervellum's, except Bubblegum's, which is a shade
/// deeper than Vervellum's #FF59AD: that pink is 2.7:1 on its own surface.
abstract final class ThemePresets {
  /// Séance's own look: its violet over the sibling neutrals, which follow
  /// the system's light or dark appearance. Not what a new device starts
  /// in ([initial]), but the palette every Automatic colour belongs to, so
  /// it is what a partial theme is completed from and what a host theme
  /// with no Séance extensions is drawn in.
  static final ThemePalette seance = ThemePalette(
    name: 'Séance',
    accent: SeanceTheme.seed,
  );

  /// Quiet: a muted blue-grey accent for anyone who finds colour
  /// distracting behind a terminal, over the same neutrals.
  static final ThemePalette graphite = ThemePalette(
    name: 'Graphite',
    accent: const Color(0xFF6B859E),
    cornerScale: 0.8,
  );

  /// Warm, light and a little square.
  static final ThemePalette paper = ThemePalette(
    name: 'Paper',
    accent: const Color(0xFF8C5729),
    surface: const Color(0xFFFAF5E8),
    sidebar: const Color(0xFFF2EBDA),
    raised: const Color(0xFFF6F0E1),
    text: const Color(0xFF29241C),
    secondaryText: const Color(0xFF61594C),
    hairline: const Color(0xFFDDD2BC),
    selection: const Color(0xFF80502A),
    online: const Color(0xFF2F7A3A),
    offline: const Color(0xFFB3261E),
    connecting: const Color(0xFF915C00),
    unknown: const Color(0xFF6E665A),
    cornerScale: 0.5,
    // Every colour here, bright ones included, clears 4.5:1 on the
    // background, like the built-in light terminal's.
    terminal: ThemeTerminalColors(
      background: const Color(0xFFFBF7EC),
      foreground: const Color(0xFF29241C),
      cursor: const Color(0xFF8C5729),
      selection: const Color(0x338C5729),
      ansi: const [
        Color(0xFF29241C),
        Color(0xFFA12F1D),
        Color(0xFF3D6822),
        Color(0xFF775800),
        Color(0xFF2C5890),
        Color(0xFF873D78),
        Color(0xFF1D6969),
        Color(0xFF5E574B),
        Color(0xFF6B6356),
        Color(0xFF852516),
        Color(0xFF30551A),
        Color(0xFF5E4600),
        Color(0xFF22497A),
        Color(0xFF6E3162),
        Color(0xFF165656),
        Color(0xFF29241C),
      ],
    ),
  );

  /// Black, white and a red pencil; sharp corners.
  static final ThemePalette newsprint = ThemePalette(
    name: 'Newsprint',
    // The same red as `offline`, deliberately, as in Vervellum: one ink.
    accent: const Color(0xFFB81C1C),
    surface: const Color(0xFFF7F7F2),
    sidebar: const Color(0xFFEDEDE6),
    raised: const Color(0xFFF2F2EC),
    text: const Color(0xFF121212),
    secondaryText: const Color(0xFF595959),
    hairline: const Color(0xFFC9C9C2),
    selection: const Color(0xFF262626),
    online: const Color(0xFF1A6B33),
    offline: const Color(0xFFB81C1C),
    connecting: const Color(0xFF8F610A),
    unknown: const Color(0xFF4D5766),
    cornerScale: 0.2,
    terminal: ThemeTerminalColors(
      background: const Color(0xFFFAFAF7),
      foreground: const Color(0xFF121212),
      cursor: const Color(0xFFB81C1C),
      selection: const Color(0x26121212),
      ansi: const [
        Color(0xFF121212),
        Color(0xFFB01B1B),
        Color(0xFF1A6630),
        Color(0xFF7A5500),
        Color(0xFF1F4E99),
        Color(0xFF80307A),
        Color(0xFF146262),
        Color(0xFF555555),
        Color(0xFF666666),
        Color(0xFF8C1515),
        Color(0xFF145226),
        Color(0xFF5E4100),
        Color(0xFF173D78),
        Color(0xFF66265F),
        Color(0xFF0F4D4D),
        Color(0xFF121212),
      ],
    ),
  );

  /// Solarized dark, with the official terminal palette.
  ///
  /// The one preset whose secondary text is under 4.5:1 (3.3): Solarized's
  /// hierarchy puts it below base0, which is itself only 4.7:1 on base03,
  /// and a Solarized that brightened it would no longer be Solarized. The
  /// rail and headers sit a shade *darker* than base03 rather than on
  /// base02, where base0 text drops to 4.1:1.
  static final ThemePalette solarized = ThemePalette(
    name: 'Solarized',
    accent: const Color(0xFFB58900),
    surface: const Color(0xFF002B36),
    sidebar: const Color(0xFF00252F),
    raised: const Color(0xFF012E39),
    text: const Color(0xFF839496),
    secondaryText: const Color(0xFF667A82),
    hairline: const Color(0xFF174552),
    selection: const Color(0xFF1C6A9E),
    online: const Color(0xFF859900),
    offline: const Color(0xFFDC322F),
    connecting: const Color(0xFFB58900),
    unknown: const Color(0xFF839496),
    terminal: ThemeTerminalColors(
      background: const Color(0xFF002B36),
      foreground: const Color(0xFF839496),
      cursor: const Color(0xFF93A1A1),
      selection: const Color(0xFF073642),
      ansi: const [
        Color(0xFF073642),
        Color(0xFFDC322F),
        Color(0xFF859900),
        Color(0xFFB58900),
        Color(0xFF268BD2),
        Color(0xFFD33682),
        Color(0xFF2AA198),
        Color(0xFFEEE8D5),
        Color(0xFF002B36),
        Color(0xFFCB4B16),
        Color(0xFF586E75),
        Color(0xFF657B83),
        Color(0xFF839496),
        Color(0xFF6C71C4),
        Color(0xFF93A1A1),
        Color(0xFFFDF6E3),
      ],
    ),
  );

  /// Deep blue, for a dark desk at night.
  static final ThemePalette midnight = ThemePalette(
    name: 'Midnight',
    accent: const Color(0xFF66ADFF),
    surface: const Color(0xFF0E131F),
    sidebar: const Color(0xFF0A0E18),
    raised: const Color(0xFF151C2B),
    text: const Color(0xFFE6EDFA),
    secondaryText: const Color(0xFF9EADC7),
    hairline: const Color(0xFF26314A),
    selection: const Color(0xFF2A5DA8),
    online: const Color(0xFF4DD18C),
    offline: const Color(0xFFFF6B73),
    connecting: const Color(0xFFFFC252),
    unknown: const Color(0xFF8CA3CC),
    terminal: ThemeTerminalColors(
      background: const Color(0xFF0B0F1A),
      foreground: const Color(0xFFD6DEEE),
      cursor: const Color(0xFF66ADFF),
      selection: const Color(0x4066ADFF),
      ansi: const [
        Color(0xFF1A2233),
        Color(0xFFFF6B73),
        Color(0xFF4DD18C),
        Color(0xFFFFC252),
        Color(0xFF66ADFF),
        Color(0xFFC29BFF),
        Color(0xFF4DD4E0),
        Color(0xFFC8D2E6),
        Color(0xFF5A6A8A),
        Color(0xFFFF8F95),
        Color(0xFF7BE0A9),
        Color(0xFFFFD480),
        Color(0xFF99C8FF),
        Color(0xFFD9BFFF),
        Color(0xFF80E3EB),
        Color(0xFFF2F6FC),
      ],
    ),
  );

  /// Green on black, and square.
  static final ThemePalette terminal = ThemePalette(
    name: 'Terminal',
    // The same green as `online`, deliberately: a terminal has one colour,
    // and that is the preset. The statuses stay apart from each other.
    accent: const Color(0xFF33FF73),
    surface: const Color(0xFF050D08),
    sidebar: const Color(0xFF030805),
    raised: const Color(0xFF0A1A10),
    text: const Color(0xFFC7FFD1),
    secondaryText: const Color(0xFF6BBD80),
    hairline: const Color(0xFF1A4D2B),
    selection: const Color(0xFF1F7A3D),
    online: const Color(0xFF33FF73),
    offline: const Color(0xFFFF4747),
    connecting: const Color(0xFFFFDB33),
    unknown: const Color(0xFF73B8D9),
    cornerScale: 0,
    // Green phosphor, but with the ANSI hues kept apart: a monochrome
    // terminal would draw a failing build's red in the same green as its
    // passing tests.
    terminal: ThemeTerminalColors(
      background: const Color(0xFF050D08),
      foreground: const Color(0xFF4DFF88),
      cursor: const Color(0xFF33FF73),
      selection: const Color(0x4033FF73),
      ansi: const [
        Color(0xFF0A1A10),
        Color(0xFFFF6E5E),
        Color(0xFF33FF73),
        Color(0xFFD7FF5C),
        Color(0xFF4DC3FF),
        Color(0xFFE07CFF),
        Color(0xFF3DFFD8),
        Color(0xFFC7FFD1),
        Color(0xFF2E6B40),
        Color(0xFFFF9488),
        Color(0xFF80FFA8),
        Color(0xFFE6FF99),
        Color(0xFF8AD8FF),
        Color(0xFFEBA8FF),
        Color(0xFF8AFFE6),
        Color(0xFFEFFFF2),
      ],
    ),
  );

  /// Magenta and cyan over violet-black, and rounder.
  static final ThemePalette vapor = ThemePalette(
    name: 'Vapor',
    accent: const Color(0xFFFF4CD9),
    surface: const Color(0xFF170A29),
    sidebar: const Color(0xFF12071F),
    raised: const Color(0xFF200F38),
    text: const Color(0xFFEDE6FF),
    secondaryText: const Color(0xFF99D9F2),
    hairline: const Color(0xFF3A2466),
    selection: const Color(0xFF8C1FA3),
    online: const Color(0xFF4DFFCC),
    offline: const Color(0xFFFF4073),
    connecting: const Color(0xFFFFCC4D),
    unknown: const Color(0xFF8CB3FF),
    cornerScale: 1.4,
    terminal: ThemeTerminalColors(
      background: const Color(0xFF13081F),
      foreground: const Color(0xFFEDE6FF),
      cursor: const Color(0xFFFF4CD9),
      selection: const Color(0x40FF4CD9),
      ansi: const [
        Color(0xFF2A1745),
        Color(0xFFFF4073),
        Color(0xFF4DFFCC),
        Color(0xFFFFCC4D),
        Color(0xFF66B3FF),
        Color(0xFFFF4CD9),
        Color(0xFF4DE6FF),
        Color(0xFFD9CCF2),
        Color(0xFF6B5299),
        Color(0xFFFF7399),
        Color(0xFF80FFDD),
        Color(0xFFFFDD80),
        Color(0xFF99CCFF),
        Color(0xFFFF80E6),
        Color(0xFF80EEFF),
        Color(0xFFFFFFFF),
      ],
    ),
  );

  /// Pink, purple and very round.
  static final ThemePalette bubblegum = ThemePalette(
    name: 'Bubblegum',
    accent: const Color(0xFFE63A91),
    surface: const Color(0xFFFFF2FA),
    sidebar: const Color(0xFFFAE4F1),
    raised: const Color(0xFFFDEBF6),
    text: const Color(0xFF3D1A3D),
    secondaryText: const Color(0xFF7A4D7A),
    hairline: const Color(0xFFEBC4DD),
    selection: const Color(0xFFB8337A),
    online: const Color(0xFF0F7A55),
    offline: const Color(0xFFC21E4A),
    connecting: const Color(0xFFA35C00),
    unknown: const Color(0xFF666699),
    cornerScale: 1.8,
    terminal: ThemeTerminalColors(
      background: const Color(0xFFFFF7FC),
      foreground: const Color(0xFF3D1A3D),
      cursor: const Color(0xFFE63A91),
      selection: const Color(0x33E63A91),
      ansi: const [
        Color(0xFF3D1A3D),
        Color(0xFFC21E4A),
        Color(0xFF16704F),
        Color(0xFF8A5A00),
        Color(0xFF3355B3),
        Color(0xFFA62E8C),
        Color(0xFF127078),
        Color(0xFF6B4D6B),
        Color(0xFF80667F),
        Color(0xFF9E1239),
        Color(0xFF0F5C40),
        Color(0xFF6E4800),
        Color(0xFF26448F),
        Color(0xFF852470),
        Color(0xFF0D5A61),
        Color(0xFF3D1A3D),
      ],
    ),
  );

  /// The most separation between text and surface, and between statuses.
  static final ThemePalette highContrast = ThemePalette(
    name: 'High contrast',
    accent: const Color(0xFFFFD900),
    surface: const Color(0xFF000000),
    sidebar: const Color(0xFF000000),
    raised: const Color(0xFF141414),
    text: const Color(0xFFFFFFFF),
    secondaryText: const Color(0xFFD9D9D9),
    hairline: const Color(0xFF8C8C8C),
    // Yellow under black text, the usual high-contrast highlight.
    selection: const Color(0xFFFFD900),
    online: const Color(0xFF33FF66),
    offline: const Color(0xFFFF5959),
    // Orange rather than the accent's yellow, so a connecting dot and the
    // accent are never the same colour in the preset about separation.
    connecting: const Color(0xFFFF9E00),
    unknown: const Color(0xFF80CCFF),
    cornerScale: 0.4,
    terminal: ThemeTerminalColors(
      background: const Color(0xFF000000),
      foreground: const Color(0xFFFFFFFF),
      cursor: const Color(0xFFFFD900),
      selection: const Color(0x4DFFFFFF),
      ansi: const [
        Color(0xFF000000),
        Color(0xFFFF5959),
        Color(0xFF33FF66),
        Color(0xFFFFD900),
        Color(0xFF66B3FF),
        Color(0xFFFF80FF),
        Color(0xFF33FFFF),
        Color(0xFFE6E6E6),
        Color(0xFF808080),
        Color(0xFFFF8C8C),
        Color(0xFF80FF99),
        Color(0xFFFFE866),
        Color(0xFF99CCFF),
        Color(0xFFFFB3FF),
        Color(0xFF99FFFF),
        Color(0xFFFFFFFF),
      ],
    ),
  );

  /// Every preset, in the order the Appearance tab shows them: the two
  /// that follow the system's light or dark (Séance first), then the
  /// light ones with surfaces of their own, then the dark ones, then the
  /// loud ones.
  static final List<ThemePalette> all = List.unmodifiable([
    seance,
    graphite,
    paper,
    newsprint,
    solarized,
    midnight,
    terminal,
    vapor,
    bubblegum,
    highContrast,
  ]);

  /// What a device starts with, and what Reset puts back: green on black,
  /// for a terminal app.
  static ThemePalette get initial => terminal;
}
