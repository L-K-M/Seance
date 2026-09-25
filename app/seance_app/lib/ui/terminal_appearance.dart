import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart' show TerminalStyle, TerminalTheme;

import '../services/app_settings.dart';
import '../theme.dart';
import '../theme/theme_palette.dart';

/// How the terminal picks its colors.
enum TerminalPalette {
  /// The app theme's terminal colours when it has its own; otherwise dark
  /// when the app is dark, light when it is light.
  followApp,
  alwaysDark,
  alwaysLight,
}

/// Terminal font size limits and steps. 13 matches xterm's own default, so an
/// existing install keeps rendering exactly as before until the user zooms.
const double kMinTerminalFontSize = 8;
const double kMaxTerminalFontSize = 32;
const double kDefaultTerminalFontSize = 13;
const double kTerminalFontSizeStep = 1;

/// Clamp a requested terminal font size into the supported range. Kept as a
/// free function so both the settings UI and the zoom shortcuts agree.
double clampTerminalFontSize(double size) =>
    size.clamp(kMinTerminalFontSize, kMaxTerminalFontSize).toDouble();

/// The terminal palettes Séance ships. Both are tuned against the app's muted
/// violet seed rather than being VS Code's stock theme, so the terminal reads
/// as part of the same product as the chrome around it.
class SeanceTerminalThemes {
  /// Near-black with a faint violet cast, matching the app's dark surfaces.
  static const dark = TerminalTheme(
    cursor: Color(0xFFB9AFEE),
    selection: Color(0x556B5BD2),
    foreground: Color(0xFFD6D3E0),
    background: Color(0xFF15141B),
    black: Color(0xFF15141B),
    red: Color(0xFFF07178),
    green: Color(0xFF7FD88F),
    yellow: Color(0xFFE6C177),
    blue: Color(0xFF7AA2F7),
    magenta: Color(0xFFC49BE8),
    cyan: Color(0xFF6FD2D8),
    white: Color(0xFFD6D3E0),
    brightBlack: Color(0xFF6B6880),
    brightRed: Color(0xFFFF8B92),
    brightGreen: Color(0xFF9BE8A8),
    brightYellow: Color(0xFFF5D89B),
    brightBlue: Color(0xFF9FBDFF),
    brightMagenta: Color(0xFFDCB7FF),
    brightCyan: Color(0xFF95E6EB),
    brightWhite: Color(0xFFF4F2FA),
    searchHitBackground: Color(0xFFE6C177),
    searchHitBackgroundCurrent: Color(0xFFB9AFEE),
    searchHitForeground: Color(0xFF15141B),
  );

  /// A warm parchment light palette. Every foreground here clears 4.5:1
  /// against the background so ANSI-colored output stays readable.
  static const light = TerminalTheme(
    cursor: Color(0xFF5B4CBE),
    selection: Color(0x336B5BD2),
    foreground: Color(0xFF2A2733),
    background: Color(0xFFFAF8F5),
    black: Color(0xFF2A2733),
    red: Color(0xFFB3261E),
    green: Color(0xFF2E6B36),
    yellow: Color(0xFF7A5A00),
    blue: Color(0xFF2B4FBF),
    magenta: Color(0xFF8A3FA8),
    cyan: Color(0xFF16636B),
    white: Color(0xFF5C5866),
    brightBlack: Color(0xFF6B6880),
    brightRed: Color(0xFF8F1D17),
    brightGreen: Color(0xFF23542A),
    brightYellow: Color(0xFF5F4600),
    brightBlue: Color(0xFF1F3C93),
    brightMagenta: Color(0xFF6E3186),
    brightCyan: Color(0xFF104C52),
    brightWhite: Color(0xFF2A2733),
    searchHitBackground: Color(0xFFF5D89B),
    searchHitBackgroundCurrent: Color(0xFFB9AFEE),
    searchHitForeground: Color(0xFF2A2733),
  );

  /// The built-in palette for [brightness]: what a theme with no terminal
  /// colours of its own draws.
  static TerminalTheme builtIn(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// A theme's terminal colours as xterm's palette.
  ///
  /// A theme names no search-highlight colours, so they are derived the way
  /// the built-in dark palette picks its own: matches in the ANSI yellow,
  /// the current one in the cursor's colour, both under text in the
  /// background's.
  static TerminalTheme fromColors(ThemeTerminalColors colors) {
    final ansi = colors.ansi;
    return TerminalTheme(
      cursor: colors.cursor,
      selection: colors.selection,
      foreground: colors.foreground,
      background: colors.background,
      black: ansi[0],
      red: ansi[1],
      green: ansi[2],
      yellow: ansi[3],
      blue: ansi[4],
      magenta: ansi[5],
      cyan: ansi[6],
      white: ansi[7],
      brightBlack: ansi[8],
      brightRed: ansi[9],
      brightGreen: ansi[10],
      brightYellow: ansi[11],
      brightBlue: ansi[12],
      brightMagenta: ansi[13],
      brightCyan: ansi[14],
      brightWhite: ansi[15],
      searchHitBackground: ansi[ThemeTerminalColors.yellowIndex],
      searchHitBackgroundCurrent: colors.cursor,
      searchHitForeground: colors.background,
    );
  }

  /// xterm's palette as a theme's terminal colours: where the Appearance
  /// tab starts when a theme first takes terminal colours of its own.
  static ThemeTerminalColors toColors(TerminalTheme theme) =>
      ThemeTerminalColors(
        background: theme.background,
        foreground: theme.foreground,
        cursor: theme.cursor,
        selection: theme.selection,
        ansi: [
          theme.black,
          theme.red,
          theme.green,
          theme.yellow,
          theme.blue,
          theme.magenta,
          theme.cyan,
          theme.white,
          theme.brightBlack,
          theme.brightRed,
          theme.brightGreen,
          theme.brightYellow,
          theme.brightBlue,
          theme.brightMagenta,
          theme.brightCyan,
          theme.brightWhite,
        ],
      );
}

/// The resolved terminal look for one build: the text style and the palette.
@immutable
class TerminalAppearance {
  final TerminalStyle style;
  final TerminalTheme theme;

  const TerminalAppearance({required this.style, required this.theme});

  /// Resolve [settings] against the ambient [brightness].
  ///
  /// An empty [AppSettings.terminalFontFamily] means "use the app's own
  /// monospace stack" ([SeanceTheme.monoFallback]) rather than xterm's, so the
  /// terminal matches the code shown elsewhere in the app. Following the app,
  /// the colours are the theme's own terminal colours when its palette
  /// ([AppSettings.themePalette]) has them; the two pinned choices keep the
  /// built-in palettes whatever the theme says.
  factory TerminalAppearance.resolve(
    AppSettings settings,
    Brightness brightness,
  ) {
    final family = settings.terminalFontFamily.trim();
    final fallback = family.isEmpty
        ? SeanceTheme.monoFallback
        : <String>[family, ...SeanceTheme.monoFallback];
    return TerminalAppearance(
      style: TerminalStyle(
        fontSize: clampTerminalFontSize(settings.terminalFontSize),
        fontFamily: fallback.first,
        fontFamilyFallback: fallback,
      ),
      theme: switch (settings.terminalPalette) {
        TerminalPalette.alwaysDark => SeanceTerminalThemes.dark,
        TerminalPalette.alwaysLight => SeanceTerminalThemes.light,
        TerminalPalette.followApp => switch (settings.themePalette.terminal) {
          final colors? => SeanceTerminalThemes.fromColors(colors),
          null => SeanceTerminalThemes.builtIn(brightness),
        },
      },
    );
  }

  /// Brightness of the resolved palette — used for the iOS keyboard appearance
  /// and for the padding that surrounds the terminal grid.
  Brightness get brightness =>
      ThemeData.estimateBrightnessForColor(theme.background);
}
