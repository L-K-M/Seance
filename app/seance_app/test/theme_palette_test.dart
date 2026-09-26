import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/theme/theme_palette.dart';
import 'package:seance_app/theme/theme_presets.dart';

/// The theme as a stored value: the hex forms people paste, the lenient
/// decode a hand-edited settings file gets, and the preset identity that
/// names a palette.
void main() {
  ThemePalette roundTrip(ThemePalette palette) => ThemePalette.fromJson(
    (jsonDecode(jsonEncode(palette.toJson())) as Map).cast<String, Object?>(),
  );

  group('colour text', () {
    test('reads every CSS hex form, with or without a prefix', () {
      const orange = Color(0xFFFF8A4C);
      expect(parseThemeColor('#FF8A4C'), orange);
      expect(parseThemeColor('ff8a4c'), orange);
      expect(parseThemeColor('0xFF8A4C'), orange);
      expect(parseThemeColor('  #ff8a4c \n'), orange);
      // The short forms double each digit.
      expect(parseThemeColor('#F84'), const Color(0xFFFF8844));
      expect(parseThemeColor('#F848'), const Color(0x88FF8844));
      // The alpha comes last, as CSS writes it.
      expect(parseThemeColor('#FF8A4C80'), const Color(0x80FF8A4C));
    });

    test('refuses what is not a colour', () {
      for (final value in [
        null,
        42,
        '',
        '#',
        '#12',
        '#12345',
        '#1234567',
        '#123456789',
        'crimson',
        '#GG0000',
        '# FF8A4C',
      ]) {
        expect(parseThemeColor(value), isNull, reason: '$value');
      }
    });

    test('writes six digits, or eight when translucent', () {
      expect(formatThemeColor(const Color(0xFF0E131F)), '#0E131F');
      expect(formatThemeColor(const Color(0x4066ADFF)), '#66ADFF40');
      for (final color in [
        const Color(0xFF000000),
        const Color(0x00FFFFFF),
        const Color(0x80123456),
      ]) {
        expect(parseThemeColor(formatThemeColor(color)), color);
      }
    });
  });

  group('lenient decode', () {
    test('an empty object is Séance, the all-Automatic preset', () {
      final palette = ThemePalette.fromJson(const {});
      expect(palette.name, ThemePresets.seance.name);
      expect(palette.accent, ThemePresets.seance.accent);
      for (final slot in ThemeSlot.values) {
        expect(palette.slot(slot), isNull, reason: slot.name);
      }
      expect(palette.terminal, isNull);
      expect(palette.fontFamily, isNull);
      expect(palette.cornerScale, 1);
      // Its values are Séance's, so it is that preset again.
      expect(palette.matchingPreset, same(ThemePresets.seance));
    });

    test('a bad value costs only itself', () {
      final palette = ThemePalette.fromJson(const {
        'name': 'Mine',
        'accent': 'crimson',
        'surface': '#102030',
        'text': 17,
        'sidebar': ['#FFFFFF'],
        'online': '#00FF00',
        'cornerScale': 'round',
        'fontFamily': 12,
      });
      expect(palette.name, 'Mine');
      expect(palette.accent, ThemePresets.seance.accent);
      expect(palette.surface, const Color(0xFF102030));
      expect(palette.text, isNull);
      expect(palette.sidebar, isNull);
      expect(palette.online, const Color(0xFF00FF00));
      expect(palette.cornerScale, ThemePresets.seance.cornerScale);
      expect(palette.fontFamily, isNull);
    });

    test('a terminal block is taken whole or not at all', () {
      final good = ThemePresets.solarized.terminal!.toJson();
      expect(
        ThemeTerminalColors.fromJson(good),
        ThemePresets.solarized.terminal,
      );

      final shortAnsi = {...good, 'ansi': (good['ansi']! as List).sublist(1)};
      final badAnsi = {
        ...good,
        'ansi': [...(good['ansi']! as List).sublist(1), 'nope'],
      };
      final noCursor = {...good}..remove('cursor');
      for (final block in [shortAnsi, badAnsi, noCursor, 'terminal', null]) {
        expect(ThemeTerminalColors.fromJson(block), isNull, reason: '$block');
        final palette = ThemePalette.fromJson({
          'accent': '#123456',
          'terminal': block,
        });
        expect(palette.terminal, isNull);
        expect(palette.accent, const Color(0xFF123456));
      }
    });

    test('names are trimmed and a blank one names what it matches', () {
      expect(ThemePalette.fromJson(const {'name': '  Ocean  '}).name, 'Ocean');
      expect(
        ThemePalette.fromJson(const {'name': '   ', 'accent': '#123456'}).name,
        ThemePalette.customName,
      );
      expect(
        ThemePalette.fromJson({
          ...ThemePresets.paper.toJson(),
          'name': '',
        }).name,
        ThemePresets.paper.name,
      );
      expect(
        ThemePalette(name: '', accent: SeanceTheme.seed).name,
        ThemePalette.customName,
      );
    });

    test('the corner scale is clamped, and NaN is the designed corner', () {
      double corners(Object value) =>
          ThemePalette.fromJson({'cornerScale': value}).cornerScale;
      expect(corners(-3), ThemePalette.minCornerScale);
      expect(corners(9), ThemePalette.maxCornerScale);
      expect(corners(double.infinity), ThemePalette.maxCornerScale);
      expect(corners(double.nan), 1);
      expect(corners(1.25), 1.25);
      // And through copyWith, which is what the slider writes.
      expect(
        ThemePresets.initial.copyWith(cornerScale: double.nan).cornerScale,
        1,
      );
    });

    test('decodeStored never throws and falls back to the default', () {
      for (final stored in [
        null,
        'a string',
        42,
        const ['#FFFFFF'],
        {1: 'non-string key'},
        // A map, but one that says nothing about how anything looks.
        const <String, Object?>{},
        const {'name': 'Mine'},
      ]) {
        expect(
          ThemePalette.decodeStored(stored),
          ThemePresets.initial,
          reason: '$stored',
        );
      }
    });

    test('only colours drawn over something keep their alpha', () {
      final palette = ThemePalette.fromJson(const {
        'accent': '#FF000080',
        'surface': '#10203080',
        'hairline': '#FFFFFF33',
        'selection': '#6B5BD240',
      });
      expect(palette.accent, const Color(0xFFFF0000));
      expect(palette.surface, const Color(0xFF102030));
      expect(palette.hairline, const Color(0x33FFFFFF));
      expect(palette.selection, const Color(0x406B5BD2));
      expect(ThemeSlot.values.where((s) => s.allowsAlpha), [
        ThemeSlot.hairline,
        ThemeSlot.selection,
      ]);
    });
  });

  group('identity', () {
    test('every preset round-trips through JSON and is recognised', () {
      for (final preset in ThemePresets.all) {
        final restored = roundTrip(preset);
        expect(restored, preset, reason: preset.name);
        expect(restored.matchingPreset, same(preset), reason: preset.name);
      }
    });

    test('a colour off a slider round-trips exactly', () {
      // A colour as an HSV slider produces it, whose channels come out of a
      // conversion rather than typed digits; the trip must be byte-exact.
      final picked = HSVColor.fromAHSV(1, 123.456, 0.37, 0.81).toColor();
      final palette = ThemePresets.initial
          .copyWith(accent: picked)
          .relabelled();
      expect(roundTrip(palette), palette);
    });

    test('a preset is matched by its values, not its name', () {
      final borrowed = ThemePresets.initial.copyWith(
        name: ThemePresets.midnight.name,
      );
      expect(borrowed.matchingPreset, same(ThemePresets.initial));

      final edited = ThemePresets.midnight.withSlot(
        ThemeSlot.surface,
        const Color(0xFF000000),
      );
      expect(edited.matchingPreset, isNull);
      expect(edited.relabelled().name, ThemePalette.customName);

      // Edited back to exactly the preset, it is the preset again.
      final restored = edited
          .withSlot(ThemeSlot.surface, ThemePresets.midnight.surface)
          .relabelled();
      expect(restored.name, ThemePresets.midnight.name);
      expect(restored, ThemePresets.midnight);
    });

    test('withSlot sets one slot and can hand it back to Automatic', () {
      final paper = ThemePresets.paper;
      final automatic = paper.withSlot(ThemeSlot.sidebar, null);
      expect(automatic.sidebar, isNull);
      for (final slot in ThemeSlot.values) {
        if (slot == ThemeSlot.sidebar) continue;
        expect(automatic.slot(slot), paper.slot(slot), reason: slot.name);
      }
      expect(automatic.terminal, paper.terminal);
      expect(automatic.cornerScale, paper.cornerScale);
      expect(automatic.withTerminal(null).terminal, isNull);
      expect(automatic.withFontFamily('  Inter ').fontFamily, 'Inter');
      expect(automatic.withFontFamily('  ').fontFamily, isNull);
    });

    test('Automatic values are left out of the stored form', () {
      final json = ThemePresets.seance.toJson();
      expect(json.keys, unorderedEquals(['name', 'accent', 'cornerScale']));
    });
  });

  group('pasting', () {
    test('a copied theme pastes back as itself', () {
      final text = const JsonEncoder.withIndent(
        '  ',
      ).convert(ThemePresets.vapor.toJson());
      expect(ThemePalette.tryParse(text), ThemePresets.vapor);
    });

    test('text that is not a theme is refused', () {
      for (final text in [
        '',
        'hello',
        '#FF8A4C',
        '[1, 2]',
        '{"name": "only a name"}',
        '{"foo": 1}',
        '{unquoted: 1}',
      ]) {
        expect(ThemePalette.tryParse(text), isNull, reason: text);
      }
    });

    test('a partial theme pastes leniently', () {
      final pasted = ThemePalette.tryParse('{"accent": "#0af"}');
      expect(pasted?.accent, const Color(0xFF00AAFF));
      expect(pasted?.surface, isNull);
    });
  });
}
