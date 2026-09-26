import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/family_hues.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/theme/contrast.dart';
import 'package:seance_app/theme/theme_palette.dart';
import 'package:seance_app/theme/theme_presets.dart';

/// WCAG AA for body text, and for non-text marks (the dots, the accent).
const _text = 4.5;
const _mark = 3.0;

/// The shipped themes, held to the thresholds the default neutrals meet.
/// Each preset is checked as it is drawn — through the built theme — at
/// every brightness it can be drawn at: its own surface's, or both for the
/// two that leave the surface Automatic.
void main() {
  test('Séance comes first and changes nothing', () {
    final first = ThemePresets.all.first;
    expect(first, same(ThemePresets.seance));
    expect(first.accent, SeanceTheme.seed);
    for (final slot in ThemeSlot.values) {
      expect(first.slot(slot), isNull, reason: slot.name);
    }
    expect(first.terminal, isNull);
    expect(first.fontFamily, isNull);
    expect(first.cornerScale, 1);
  });

  test('a new device starts in Terminal', () {
    expect(ThemePresets.initial, same(ThemePresets.terminal));
    expect(ThemePresets.all, contains(ThemePresets.initial));
  });

  test('ten presets with unique names, each its own match', () {
    expect(ThemePresets.all, hasLength(10));
    final names = ThemePresets.all.map((p) => p.name).toList();
    expect(names.toSet(), hasLength(names.length));
    expect(names, isNot(contains(ThemePalette.customName)));
    for (final preset in ThemePresets.all) {
      expect(preset.matchingPreset, same(preset), reason: preset.name);
      expect(preset.relabelled(), preset, reason: preset.name);
    }
  });

  test('every preset with its own surface brings a complete look', () {
    // The default and Graphite leave the surface, and with it every
    // neutral, Automatic; any preset that sets a surface sets them all.
    for (final preset in ThemePresets.all.where((p) => p.surface != null)) {
      for (final slot in ThemeSlot.values) {
        expect(preset.slot(slot), isNotNull, reason: '${preset.name} $slot');
      }
      expect(preset.terminal, isNotNull, reason: preset.name);
    }
  });

  for (final preset in ThemePresets.all) {
    final brightnesses = preset.surface == null
        ? Brightness.values
        : [Brightness.light];
    for (final brightness in brightnesses) {
      final label = preset.surface == null
          ? '${preset.name} (${brightness.name})'
          : preset.name;

      test('$label: text, accent and selection contrast', () {
        final theme = SeanceTheme.build(preset, brightness);
        final colours = SeanceTheme.resolvedSlots(preset, brightness);
        final chrome = theme.extension<SeanceChrome>()!;
        final surface = colours[ThemeSlot.surface]!;
        final sidebar = colours[ThemeSlot.sidebar]!;

        expect(theme.colorScheme.surface, surface);
        expect(
          contrastRatio(colours[ThemeSlot.text]!, surface),
          greaterThanOrEqualTo(_text),
          reason: 'text on the surface',
        );
        expect(
          contrastRatio(colours[ThemeSlot.text]!, sidebar),
          greaterThanOrEqualTo(_text),
          reason: 'text on the rail',
        );
        // Solarized's hierarchy puts secondary text below base0, which is
        // itself only 4.7:1 on base03; the preset documents the exception.
        expect(
          contrastRatio(colours[ThemeSlot.secondaryText]!, surface),
          greaterThanOrEqualTo(
            preset == ThemePresets.solarized ? _mark : _text,
          ),
          reason: 'secondary text on the surface',
        );
        expect(
          contrastRatio(theme.colorScheme.primary, surface),
          greaterThanOrEqualTo(_mark),
          reason: 'the accent as drawn, on the surface',
        );
        final pill = compositeOver(
          chrome.selectionFill,
          chrome.sidebarBackground,
        );
        expect(
          contrastRatio(chrome.onSelection, pill),
          greaterThanOrEqualTo(_text),
          reason: 'the selected row label on its pill',
        );
      });

      test('$label: four distinct status colours that read', () {
        final colours = SeanceTheme.resolvedSlots(preset, brightness);
        final statuses = [
          colours[ThemeSlot.online]!,
          colours[ThemeSlot.offline]!,
          colours[ThemeSlot.connecting]!,
          colours[ThemeSlot.unknown]!,
        ];
        expect(statuses.toSet(), hasLength(4));
        for (final status in statuses) {
          for (final background in [
            colours[ThemeSlot.surface]!,
            colours[ThemeSlot.sidebar]!,
          ]) {
            expect(
              contrastRatio(status, background),
              greaterThanOrEqualTo(_mark),
              reason: '$status on $background',
            );
          }
        }
      });
    }

    final terminal = preset.terminal;
    if (terminal == null) continue;
    test('${preset.name}: terminal colours read on their background', () {
      final background = terminal.background;
      expect(
        contrastRatio(terminal.foreground, background),
        greaterThanOrEqualTo(_text),
      );
      final darkBackground =
          ThemeData.estimateBrightnessForColor(background) == Brightness.dark;
      for (var i = 0; i < ThemeTerminalColors.ansiCount; i++) {
        final ratio = contrastRatio(terminal.ansi[i], background);
        // Paper promises what the built-in light terminal does: every
        // colour, bright ones too, at 4.5:1.
        if (preset == ThemePresets.paper) {
          expect(ratio, greaterThanOrEqualTo(_text), reason: 'ANSI $i');
          continue;
        }
        // Black is the background's own neighbour by design, and so is
        // white on a light one; the bright row is emphasis, not text.
        final normal = i >= 1 && i <= 6 || (i == 7 && darkBackground);
        if (!normal) continue;
        expect(ratio, greaterThanOrEqualTo(_mark), reason: 'ANSI $i');
      }
    });
  }

  // The family hues (lib/family_hues.dart) are tuned against the default
  // neutrals; a preset moves the surfaces they sit on, so every preset is
  // held to the same 3:1 non-text floor for every hue.
  test('the family glyph hues keep 3:1 on every preset', () {
    for (final preset in ThemePresets.all) {
      for (final brightness in Brightness.values) {
        final theme = SeanceTheme.build(preset, brightness);
        final hues = theme.extension<FamilyPalette>()!;
        final chrome = theme.extension<SeanceChrome>()!;
        for (final hue in FamilyHue.values) {
          for (final surface in [
            theme.colorScheme.surface,
            chrome.sidebarBackground,
          ]) {
            expect(
              contrastRatio(hues.glyph(hue), surface),
              greaterThanOrEqualTo(_mark),
              reason: '${preset.name} ${brightness.name} ${hue.name}',
            );
          }
        }
      }
    }
  });
}
