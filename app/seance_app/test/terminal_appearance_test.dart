import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/theme/contrast.dart';
import 'package:seance_app/theme/theme_palette.dart';
import 'package:seance_app/theme/theme_presets.dart';
import 'package:seance_app/ui/terminal_appearance.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;

void main() {
  group('terminal appearance', () {
    test('defaults keep xterm\'s size but adopt the app font stack', () {
      final appearance = TerminalAppearance.resolve(
        AppSettings(),
        Brightness.dark,
      );
      expect(appearance.style.fontSize, kDefaultTerminalFontSize);
      expect(appearance.style.fontFamilyFallback, SeanceTheme.monoFallback);
      expect(appearance.style.fontFamily, SeanceTheme.monoFallback.first);
    });

    test('a chosen family leads, with the app stack behind it', () {
      final appearance = TerminalAppearance.resolve(
        AppSettings(terminalFontFamily: '  Iosevka  '),
        Brightness.dark,
      );
      expect(appearance.style.fontFamily, 'Iosevka');
      expect(appearance.style.fontFamilyFallback.first, 'Iosevka');
      // The bundled stack still backs it up for glyphs Iosevka lacks.
      expect(
        appearance.style.fontFamilyFallback.sublist(1),
        SeanceTheme.monoFallback,
      );
    });

    test('followApp tracks the ambient brightness', () {
      final settings = AppSettings(terminalPalette: TerminalPalette.followApp);
      expect(
        TerminalAppearance.resolve(settings, Brightness.dark).theme.background,
        SeanceTerminalThemes.dark.background,
      );
      expect(
        TerminalAppearance.resolve(settings, Brightness.light).theme.background,
        SeanceTerminalThemes.light.background,
      );
    });

    test('a pinned palette ignores the ambient brightness', () {
      final dark = AppSettings(terminalPalette: TerminalPalette.alwaysDark);
      final light = AppSettings(terminalPalette: TerminalPalette.alwaysLight);
      expect(
        TerminalAppearance.resolve(dark, Brightness.light).theme.background,
        SeanceTerminalThemes.dark.background,
      );
      expect(
        TerminalAppearance.resolve(light, Brightness.dark).theme.background,
        SeanceTerminalThemes.light.background,
      );
    });

    test('brightness is derived from the resolved background', () {
      final dark = TerminalAppearance.resolve(
        AppSettings(terminalPalette: TerminalPalette.alwaysDark),
        Brightness.light,
      );
      final light = TerminalAppearance.resolve(
        AppSettings(terminalPalette: TerminalPalette.alwaysLight),
        Brightness.dark,
      );
      expect(dark.brightness, Brightness.dark);
      expect(light.brightness, Brightness.light);
    });

    test('following the app, a theme with terminal colours uses them', () {
      final colors = ThemePresets.solarized.terminal!;
      final settings = AppSettings(themePalette: ThemePresets.solarized);
      for (final brightness in Brightness.values) {
        final theme = TerminalAppearance.resolve(settings, brightness).theme;
        expect(theme.background, colors.background);
        expect(theme.foreground, colors.foreground);
        expect(theme.cursor, colors.cursor);
        expect(theme.selection, colors.selection);
        expect(theme.red, colors.ansi[1]);
        expect(theme.brightWhite, colors.ansi[15]);
        // Search highlights, which a theme does not name, are derived.
        expect(theme.searchHitBackground, colors.ansi[3]);
        expect(theme.searchHitBackgroundCurrent, colors.cursor);
        expect([
          colors.background,
          colors.foreground,
        ], contains(theme.searchHitForeground));
      }
    });

    test('search hits keep their text readable on every preset', () {
      for (final preset in ThemePresets.all) {
        final colors = preset.terminal;
        if (colors == null) continue;
        final theme = SeanceTerminalThemes.fromColors(colors);
        for (final hit in [
          theme.searchHitBackground,
          theme.searchHitBackgroundCurrent,
        ]) {
          expect(
            contrastRatio(theme.searchHitForeground, hit),
            greaterThanOrEqualTo(3),
            reason: preset.name,
          );
        }
      }
    });

    test('the lighter of the two base colours is not forced onto a hit', () {
      // A light theme whose yellow and cursor are pale: its near-white
      // background would vanish on them, its dark text does not.
      final colors = ThemePresets.paper.terminal!;
      final pale = ThemeTerminalColors(
        background: const Color(0xFFFFFFFF),
        foreground: const Color(0xFF1A1A1A),
        cursor: const Color(0xFFE0E0E0),
        selection: colors.selection,
        ansi: [
          for (var i = 0; i < ThemeTerminalColors.ansiCount; i++)
            i == ThemeTerminalColors.yellowIndex
                ? const Color(0xFFFFF59D)
                : colors.ansi[i],
        ],
      );
      expect(
        SeanceTerminalThemes.fromColors(pale).searchHitForeground,
        const Color(0xFF1A1A1A),
      );
    });

    test('a pinned palette ignores the theme\'s terminal colours', () {
      final dark = AppSettings(
        themePalette: ThemePresets.paper,
        terminalPalette: TerminalPalette.alwaysDark,
      );
      expect(
        TerminalAppearance.resolve(dark, Brightness.light).theme.background,
        SeanceTerminalThemes.dark.background,
      );
    });

    test('a theme without terminal colours keeps the built-in ones', () {
      final settings = AppSettings(themePalette: ThemePresets.graphite);
      expect(
        TerminalAppearance.resolve(settings, Brightness.dark).theme,
        same(SeanceTerminalThemes.dark),
      );
    });

    test('the built-in palettes convert to theme colours and back', () {
      for (final builtIn in [
        SeanceTerminalThemes.dark,
        SeanceTerminalThemes.light,
      ]) {
        final colors = SeanceTerminalThemes.toColors(builtIn);
        expect(colors.ansi, hasLength(ThemeTerminalColors.ansiCount));
        final back = SeanceTerminalThemes.fromColors(colors);
        List<Color> named(TerminalTheme t) => [
          t.background,
          t.foreground,
          t.cursor,
          t.selection,
          t.black,
          t.red,
          t.green,
          t.yellow,
          t.blue,
          t.magenta,
          t.cyan,
          t.white,
          t.brightBlack,
          t.brightRed,
          t.brightGreen,
          t.brightYellow,
          t.brightBlue,
          t.brightMagenta,
          t.brightCyan,
          t.brightWhite,
        ];
        expect(named(back), named(builtIn));
      }
    });

    test('font size is clamped when resolving', () {
      expect(
        TerminalAppearance.resolve(
          AppSettings(terminalFontSize: 900),
          Brightness.dark,
        ).style.fontSize,
        kMaxTerminalFontSize,
      );
      expect(
        TerminalAppearance.resolve(
          AppSettings(terminalFontSize: 1),
          Brightness.dark,
        ).style.fontSize,
        kMinTerminalFontSize,
      );
    });
  });

  group('appearance persistence', () {
    test('round-trips through JSON', () {
      final settings = AppSettings(
        terminalFontSize: 17,
        terminalFontFamily: 'Fira Code',
        terminalPalette: TerminalPalette.alwaysLight,
      );
      final restored = AppSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
      );
      expect(restored.terminalFontSize, 17);
      expect(restored.terminalFontFamily, 'Fira Code');
      expect(restored.terminalPalette, TerminalPalette.alwaysLight);
    });

    test('an out-of-range or unknown stored value falls back safely', () {
      final restored = AppSettings.fromJson({
        'terminalFontSize': 400,
        'terminalPalette': 'nonsense',
      });
      expect(restored.terminalFontSize, kMaxTerminalFontSize);
      expect(restored.terminalPalette, TerminalPalette.followApp);
    });

    test('a settings file written before this feature keeps the default', () {
      final restored = AppSettings.fromJson({'deviceId': 'abc'});
      expect(restored.terminalFontSize, kDefaultTerminalFontSize);
      expect(restored.terminalFontFamily, isEmpty);
      expect(restored.terminalPalette, TerminalPalette.followApp);
    });
  });
}
