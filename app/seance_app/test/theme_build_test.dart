import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/theme/app_appearance.dart';
import 'package:seance_app/theme/contrast.dart';
import 'package:seance_app/theme/theme_palette.dart';
import 'package:seance_app/theme/theme_presets.dart';

/// The theme as it was built before palettes existed, from the tables as
/// they were then, written out here so the comparison below cannot drift
/// with the code it checks. An install that has never opened Appearance
/// must see exactly this.
ColorScheme _legacyScheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  Color pick(int onDark, int onLight) => Color(dark ? onDark : onLight);
  return ColorScheme.fromSeed(
    seedColor: const Color(0xFF6B5BD2),
    brightness: brightness,
  ).copyWith(
    surface: pick(0xFF232932, 0xFFFFFFFF),
    surfaceContainerLowest: pick(0xFF1C2128, 0xFFFFFFFF),
    surfaceContainerLow: pick(0xFF2A313B, 0xFFF1F2F4),
    surfaceContainer: pick(0xFF2D3440, 0xFFF6F6F8),
    surfaceContainerHigh: pick(0xFF353D49, 0xFFEBECEF),
    surfaceContainerHighest: pick(0xFF3B4452, 0xFFE2E5EA),
    onSurface: pick(0xFFE7EAEF, 0xFF1C1F24),
    onSurfaceVariant: pick(0xFFB4BCC8, 0xFF596170),
    outline: pick(0xFF6B7584, 0xFF7D8591),
    outlineVariant: pick(0xFF3A424E, 0xFFDADDE3),
    inverseSurface: pick(0xFFE7EAEF, 0xFF2D323A),
    onInverseSurface: pick(0xFF232932, 0xFFF1F2F4),
    primary: pick(0xFFADA1FF, 0xFF5847C2),
    onPrimary: pick(0xFF1D1452, 0xFFFFFFFF),
    primaryContainer: pick(0xFF43388F, 0xFFE6E0FF),
    onPrimaryContainer: pick(0xFFE6E0FF, 0xFF1D1452),
    secondaryContainer: pick(0xFF3B4758, 0xFFDCE3EC),
    onSecondaryContainer: pick(0xFFDCE4EF, 0xFF18222E),
  );
}

void main() {
  group('the Séance palette draws what the app always drew', () {
    for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
      for (final brightness in Brightness.values) {
        test('${brightness.name} on ${platform.name}', () {
          final theme = brightness == Brightness.dark
              ? SeanceTheme.dark(platform: platform)
              : SeanceTheme.light(platform: platform);
          final scheme = _legacyScheme(brightness);
          final desktop = platform == TargetPlatform.macOS;
          final plain = ThemeData(
            colorScheme: scheme,
            useMaterial3: true,
            platform: platform,
          );

          expect(theme.brightness, brightness);
          expect(theme.colorScheme, scheme);
          expect(theme.scaffoldBackgroundColor, scheme.surface);
          expect(theme.dividerColor, scheme.outlineVariant);
          expect(theme.hoverColor, scheme.onSurface.withValues(alpha: 0.06));
          expect(theme.visualDensity, VisualDensity.comfortable);
          if (desktop) {
            // The sibling apps' 13 px desktop ramp over Material's styles.
            final t = theme.textTheme;
            expect(
              [
                t.titleLarge,
                t.titleMedium,
                t.titleSmall,
                t.bodyLarge,
                t.bodyMedium,
                t.bodySmall,
                t.labelLarge,
                t.labelMedium,
                t.labelSmall,
              ].map((style) => style?.fontSize),
              [17, 14, 13, 14, 13, 12, 13, 12, 11],
            );
            expect(t.displayLarge, plain.textTheme.displayLarge);
            expect(
              t.bodyMedium?.fontFamily,
              plain.textTheme.bodyMedium?.fontFamily,
            );
          } else {
            expect(theme.textTheme, plain.textTheme);
          }
          expect(
            theme.menuTheme.style?.shape?.resolve({}),
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          );
          expect(
            (theme.tooltipTheme.decoration! as BoxDecoration).borderRadius,
            BorderRadius.circular(6),
          );
          // Every component the corner scale can reach keeps Material's own
          // shape at the designed scale.
          expect(theme.dialogTheme, plain.dialogTheme);
          expect(theme.cardTheme, plain.cardTheme);
          expect(theme.popupMenuTheme, plain.popupMenuTheme);
          expect(theme.inputDecorationTheme, plain.inputDecorationTheme);
          expect(theme.filledButtonTheme, plain.filledButtonTheme);
          expect(theme.outlinedButtonTheme, plain.outlinedButtonTheme);
          expect(theme.textButtonTheme, plain.textButtonTheme);
          expect(theme.segmentedButtonTheme, plain.segmentedButtonTheme);
          expect(theme.chipTheme, plain.chipTheme);
          expect(theme.bottomSheetTheme, plain.bottomSheetTheme);
          expect(theme.snackBarTheme, plain.snackBarTheme);

          final chrome = theme.extension<SeanceChrome>()!;
          expect(chrome.sidebarBackground, scheme.surfaceContainerLow);
          expect(chrome.headerBackground, scheme.surfaceContainer);
          expect(chrome.paneBackground, scheme.surface);
          expect(chrome.inspectorBackground, scheme.surfaceContainerLow);
          expect(chrome.separator, scheme.outlineVariant);
          expect(chrome.hoverFill, scheme.onSurface.withValues(alpha: 0.06));
          expect(chrome.capsuleFill, scheme.surfaceContainerHigh);
          expect(chrome.selectionFill, const Color(0xFF5A4BC0));
          expect(chrome.onSelection, const Color(0xFFFFFFFF));
          expect(chrome.inactiveSelectionFill, scheme.surfaceContainerHighest);
          expect(chrome.activePaneIndicator, scheme.primary);
          expect(chrome.secondaryText, scheme.onSurfaceVariant);
          expect(chrome.headerHeight, desktop ? 52 : 56);
          expect(chrome.rowExtent, desktop ? 22 : 48);
          expect(chrome.sidebarRowExtent, desktop ? 26 : 40);
          expect(chrome.cornerScale, 1);

          final light = brightness == Brightness.light;
          final status = theme.extension<SeanceStatusColors>()!;
          expect(status.online, Color(light ? 0xFF1A7F37 : 0xFF3FB950));
          expect(status.offline, Color(light ? 0xFFCF222E : 0xFFFF7B72));
          expect(status.connecting, Color(light ? 0xFFB06E00 : 0xFFD29922));
          expect(status.unknown, Color(light ? 0xFF57606A : 0xFF8B949E));
        });
      }
    }

    test('the MaterialApp gets both, following the system', () {
      final themes = SeanceTheme.forAppearance(
        AppAppearance(palette: ThemePresets.seance),
      );
      expect(themes.themeMode, ThemeMode.system);
      expect(themes.theme.colorScheme, _legacyScheme(Brightness.light));
      expect(themes.darkTheme.colorScheme, _legacyScheme(Brightness.dark));
    });
  });

  test('a new device is drawn in Terminal, whatever the system says', () {
    final themes = SeanceTheme.forAppearance(AppAppearance.initial);
    expect(themes.theme, same(themes.darkTheme));
    expect(themes.theme.brightness, Brightness.dark);
    expect(themes.theme.colorScheme.surface, ThemePresets.terminal.surface);
    expect(themes.theme.colorScheme.primary, ThemePresets.terminal.accent);
  });

  group('a palette lands where it says', () {
    test('every slot reaches the scheme and the chrome', () {
      final palette = ThemePalette(
        accent: const Color(0xFF2266CC),
        surface: const Color(0xFF101418),
        sidebar: const Color(0xFF0C1014),
        raised: const Color(0xFF182028),
        text: const Color(0xFFEEF2F6),
        secondaryText: const Color(0xFFA0A8B0),
        hairline: const Color(0x40FFFFFF),
        selection: const Color(0xFF1B4F8F),
        online: const Color(0xFF00E676),
        offline: const Color(0xFFFF5252),
        connecting: const Color(0xFFFFD740),
        unknown: const Color(0xFF90A4AE),
      );
      final theme = SeanceTheme.build(palette, Brightness.light);
      final scheme = theme.colorScheme;
      final chrome = theme.extension<SeanceChrome>()!;
      final status = theme.extension<SeanceStatusColors>()!;

      // A dark surface of its own makes the theme dark, whatever was asked.
      expect(theme.brightness, Brightness.dark);
      expect(scheme.primary, palette.accent);
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.surface, palette.surface);
      expect(theme.scaffoldBackgroundColor, palette.surface);
      expect(chrome.paneBackground, palette.surface);
      expect(scheme.surfaceContainerLow, palette.sidebar);
      expect(chrome.sidebarBackground, palette.sidebar);
      expect(chrome.inspectorBackground, palette.sidebar);
      expect(scheme.surfaceContainer, palette.raised);
      expect(chrome.headerBackground, palette.raised);
      expect(scheme.onSurface, palette.text);
      expect(scheme.onSurfaceVariant, palette.secondaryText);
      expect(chrome.secondaryText, palette.secondaryText);
      expect(scheme.outlineVariant, palette.hairline);
      expect(chrome.separator, palette.hairline);
      expect(theme.dividerColor, palette.hairline);
      expect(chrome.selectionFill, palette.selection);
      expect(chrome.activePaneIndicator, palette.accent);
      expect(status.online, palette.online);
      expect(status.offline, palette.offline);
      expect(status.connecting, palette.connecting);
      expect(status.unknown, palette.unknown);
      expect(theme.textTheme.bodyMedium?.color, palette.text);
    });

    test('Automatic shades follow a surface of its own, in order', () {
      final palette = ThemePalette(
        accent: const Color(0xFF8C5729),
        surface: const Color(0xFFFAF5E8),
        text: const Color(0xFF29241C),
      );
      final scheme = SeanceTheme.build(palette, Brightness.dark).colorScheme;
      expect(scheme.brightness, Brightness.light);
      // Each step further from the surface toward the text: the fraction
      // of the way from one to the other, which is negative for a shade
      // that stepped away from the text instead.
      final surface = scheme.surface.computeLuminance();
      final text = palette.text!.computeLuminance();
      double towardText(Color c) =>
          (c.computeLuminance() - surface) / (text - surface);
      final ladder = [
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
      ].map(towardText).toList();
      expect(ladder.first, greaterThan(0));
      for (var i = 1; i < ladder.length; i++) {
        expect(ladder[i], greaterThan(ladder[i - 1]), reason: 'step $i');
      }
      // Mixed from the palette's own colours, not the slate tables.
      expect(scheme.surfaceContainerLow, isNot(const Color(0xFFF1F2F4)));
      expect(scheme.inverseSurface, palette.text);
    });

    test('a light selection gets a dark label', () {
      final theme = SeanceTheme.build(
        ThemePresets.highContrast,
        Brightness.light,
      );
      expect(
        theme.extension<SeanceChrome>()!.onSelection,
        const Color(0xFF000000),
      );
    });

    test('another accent gets a selection white text reads on', () {
      final chrome = SeanceTheme.build(
        ThemePresets.seance.copyWith(accent: const Color(0xFF7FD1FF)),
        Brightness.dark,
      ).extension<SeanceChrome>()!;
      expect(chrome.onSelection, const Color(0xFFFFFFFF));
      expect(chrome.selectionFill, isNot(const Color(0xFF5A4BC0)));
      expect(
        contrastRatio(chrome.onSelection, chrome.selectionFill),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('brightness', () {
    test('a surface decides it; otherwise the mode, then the system', () {
      final automatic = ThemePresets.seance;
      expect(
        resolveBrightness(
          automatic,
          Brightness.dark,
          ThemeModePreference.system,
        ),
        Brightness.dark,
      );
      expect(
        resolveBrightness(
          automatic,
          Brightness.dark,
          ThemeModePreference.light,
        ),
        Brightness.light,
      );
      expect(
        resolveBrightness(
          automatic,
          Brightness.light,
          ThemeModePreference.dark,
        ),
        Brightness.dark,
      );
      expect(
        resolveBrightness(
          ThemePresets.paper,
          Brightness.dark,
          ThemeModePreference.dark,
        ),
        Brightness.light,
      );
      expect(
        resolveBrightness(
          ThemePresets.midnight,
          Brightness.light,
          ThemeModePreference.system,
        ),
        Brightness.dark,
      );
      expect(
        resolveBrightness(
          ThemePresets.midnight,
          Brightness.light,
          ThemeModePreference.light,
        ),
        Brightness.dark,
      );
    });

    test('a surface of its own is one theme for the MaterialApp', () {
      final themes = SeanceTheme.forAppearance(
        AppAppearance(
          palette: ThemePresets.midnight,
          mode: ThemeModePreference.light,
        ),
      );
      expect(themes.theme.brightness, Brightness.dark);
      expect(themes.darkTheme.brightness, Brightness.dark);
      expect(themes.theme.colorScheme.surface, ThemePresets.midnight.surface);
    });

    test('the mode picks between the two otherwise', () {
      ThemeMode modeFor(ThemeModePreference mode) => SeanceTheme.forAppearance(
        AppAppearance(palette: ThemePresets.graphite, mode: mode),
      ).themeMode;
      expect(modeFor(ThemeModePreference.system), ThemeMode.system);
      expect(modeFor(ThemeModePreference.light), ThemeMode.light);
      expect(modeFor(ThemeModePreference.dark), ThemeMode.dark);
    });
  });

  group('shape and type', () {
    test('the corner scale reaches the components and the chrome', () {
      final theme = SeanceTheme.build(
        ThemePresets.seance.copyWith(cornerScale: 0.5),
        Brightness.light,
      );
      expect(
        theme.dialogTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      );
      expect(
        theme.menuTheme.style?.shape?.resolve({}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      );
      expect(
        (theme.tooltipTheme.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(3),
      );
      expect(
        theme.filledButtonTheme.style?.shape?.resolve({}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );
      expect(
        theme.chipTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      );
      final chrome = theme.extension<SeanceChrome>()!;
      expect(chrome.cornerScale, 0.5);
      expect(chrome.corner(6), 3);
    });

    test('square is square', () {
      final theme = SeanceTheme.build(ThemePresets.terminal, Brightness.dark);
      expect(
        theme.dialogTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
      );
    });

    test('the interface font reaches the text theme', () {
      final theme = SeanceTheme.build(
        ThemePresets.seance.withFontFamily('Inter'),
        Brightness.light,
        platform: TargetPlatform.linux,
      );
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Inter');
      expect(theme.textTheme.titleLarge?.fontFamily, 'Inter');
      // The desktop ramp survives it.
      expect(theme.textTheme.bodyMedium?.fontSize, 13);
    });
  });

  testWidgets('status colours come from the theme', (tester) async {
    late Color online;
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.build(ThemePresets.midnight, Brightness.light),
        home: Builder(
          builder: (context) {
            online = StatusColors.online(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(online, ThemePresets.midnight.online);
  });
}
