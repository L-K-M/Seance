import 'package:flutter/material.dart';

/// The sibling apps' shared colour vocabulary (D34, 10 §10): a dozen
/// named hues, each with one meaning in both Poltergeist and Séance, so
/// a glance finds a thing by its colour before its shape or its words,
/// the way iTunes' source list and the old Finder sidebar let you.
///
/// The chrome stays quiet (D11): the slate and Finder-light surfaces,
/// the accent selection, the status dots. Colour lives on the glyphs
/// that name a KIND of thing (a file's kind, a place, a verb), never on
/// text, large fills, or state. Status keeps its own dots and rings, so
/// a green glyph never reads as "connected".
///
/// | Hue      | Means                  | Poltergeist                       | Séance                   |
/// |----------|------------------------|-----------------------------------|--------------------------|
/// | blue     | places and folders     | folders, Home, New Folder, Info   | Files, folders           |
/// | cyan     | motion                 | transfers, copy/move, links       | upload, download, links  |
/// | teal     | saved recipes          | workspaces                        | Snippets                 |
/// | green    | go, live               | Connect, live sessions            | Stage, done              |
/// | yellow   | attention              | Alerts, warnings, favorites       | suggestions              |
/// | orange   | code                   | source and config files           | Git, source files        |
/// | red      | destructive; PDF       | Move to Trash, Delete, PDF        | Discard, PDF             |
/// | pink     | images                 | images                            | images                   |
/// | purple   | audio and video; AI    | audio, video                      | Assistant, audio, video  |
/// | indigo   | sync                   | Sync, saved syncs                 | Sync settings            |
/// | brown    | cargo                  | archives, removable drives        | archives                 |
/// | graphite | neutral                | documents, disks, navigation      | documents, navigation    |
///
/// Every hue has two forms. A bare [FamilyPalette.glyph] tint, per
/// theme, held to 3:1 on every chrome surface a glyph sits on (the
/// family hues test pins it). And a [FamilyHueTile], the rounded,
/// gently lit square an iOS Settings row or a System Settings sidebar
/// wears, whose fill is the same in both themes, like an app icon's,
/// with its glyph held to 3:1 on the lighter end of the fill.
///
/// Poltergeist's copy lives in lib/theme/family_hues.dart and Séance's
/// in lib/family_hues.dart; the two files are identical, so keep them so.
enum FamilyHue {
  blue,
  cyan,
  teal,
  green,
  yellow,
  orange,
  red,
  pink,
  purple,
  indigo,
  brown,
  graphite,
}

/// The per-theme glyph tints, a [ThemeExtension] so a light/dark switch
/// fades them with the rest of the theme.
@immutable
class FamilyPalette extends ThemeExtension<FamilyPalette> {
  const FamilyPalette._(this._glyphs);

  /// Keyed by hue, so reordering or adding a [FamilyHue] cannot shift a
  /// tint onto another hue; a hue missing here fails the first lookup
  /// (every hue is looked up on every surface in the family hues test).
  final Map<FamilyHue, Color> _glyphs;

  /// Bright enough to sing on the slate surfaces without glowing.
  static const dark = FamilyPalette._({
    FamilyHue.blue: Color(0xFF5BA8F5),
    FamilyHue.cyan: Color(0xFF45C8DC),
    FamilyHue.teal: Color(0xFF4FD1B5),
    FamilyHue.green: Color(0xFF5BD17A),
    FamilyHue.yellow: Color(0xFFF2C14E),
    FamilyHue.orange: Color(0xFFFF9A52),
    FamilyHue.red: Color(0xFFFF7A70),
    FamilyHue.pink: Color(0xFFF57FC0),
    FamilyHue.purple: Color(0xFFB79CFF),
    FamilyHue.indigo: Color(0xFF8FA2FF),
    FamilyHue.brown: Color(0xFFD2A679),
    // Graphite is the neutrals' secondary text.
    FamilyHue.graphite: Color(0xFFB4BCC8),
  });

  /// Deep enough to hold 3:1 on the Finder-light greys.
  static const light = FamilyPalette._({
    FamilyHue.blue: Color(0xFF1F6FD1),
    FamilyHue.cyan: Color(0xFF00838F),
    FamilyHue.teal: Color(0xFF00796B),
    FamilyHue.green: Color(0xFF1B873A),
    FamilyHue.yellow: Color(0xFF9A6700),
    FamilyHue.orange: Color(0xFFC2410C),
    FamilyHue.red: Color(0xFFC62828),
    FamilyHue.pink: Color(0xFFC2185B),
    FamilyHue.purple: Color(0xFF7B3FD1),
    FamilyHue.indigo: Color(0xFF3F51B5),
    FamilyHue.brown: Color(0xFF8D5A2B),
    // Graphite is the neutrals' secondary text.
    FamilyHue.graphite: Color(0xFF596170),
  });

  /// A disc's wash (a phone listing's kind badge, a Home row's mark): the
  /// glyph's own tint at this opacity behind it, light enough to keep
  /// the glyph at 3:1 (the family hues test pins it).
  static const double discWashAlpha = 0.14;

  static FamilyPalette forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// The palette for [context]'s theme, falling back to its brightness's
  /// defaults when a host theme (a test harness, a dialog subtree)
  /// carries none.
  static FamilyPalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<FamilyPalette>() ??
        forBrightness(theme.brightness);
  }

  /// [hue]'s tint for a bare glyph on a chrome surface.
  Color glyph(FamilyHue hue) => _glyphs[hue]!;

  @override
  FamilyPalette copyWith() => this;

  @override
  FamilyPalette lerp(FamilyPalette? other, double t) {
    if (other == null) return this;
    return FamilyPalette._({
      for (final hue in FamilyHue.values)
        hue: Color.lerp(glyph(hue), other.glyph(hue), t)!,
    });
  }
}

/// A hue's tile colours, the same in both themes.
extension FamilyHueTileColors on FamilyHue {
  /// The fill's base, at the tile's foot.
  Color get tileFill => switch (this) {
    FamilyHue.blue => const Color(0xFF2F7FE0),
    FamilyHue.cyan => const Color(0xFF0E8AA3),
    FamilyHue.teal => const Color(0xFF12897A),
    FamilyHue.green => const Color(0xFF238C43),
    FamilyHue.yellow => const Color(0xFFE8A800),
    FamilyHue.orange => const Color(0xFFD65F0A),
    FamilyHue.red => const Color(0xFFDB3B36),
    FamilyHue.pink => const Color(0xFFD23F86),
    FamilyHue.purple => const Color(0xFF8A55D6),
    FamilyHue.indigo => const Color(0xFF4F5BD0),
    FamilyHue.brown => const Color(0xFF9C6A3C),
    FamilyHue.graphite => const Color(0xFF6B7582),
  };

  /// The fill's lit top: the base lifted a little toward white, the
  /// soft top-lit sheen the old source lists' icons had.
  Color get tileSheen => Color.lerp(tileFill, const Color(0xFFFFFFFF), 0.12)!;

  /// The glyph on the tile: white, except on yellow, which no white
  /// glyph can hold 3:1 on (a caution sign's dark glyph instead).
  Color get onTile => this == FamilyHue.yellow
      ? const Color(0xFF3D2E00)
      : const Color(0xFFFFFFFF);
}

/// [glyph] on a rounded [hue] tile, lit from the top: the sidebar's
/// place marks and the settings sections. Decorative: the row it leads
/// names what it is.
class FamilyHueTile extends StatelessWidget {
  const FamilyHueTile({
    super.key,
    required this.hue,
    required this.glyph,
    required this.extent,
    this.glyphSize,
  });

  /// A server badge's corner, so a place's tile and a server's badge
  /// share one silhouette in the rail.
  static const double cornerRatio = 0.28;

  /// A glyph's share of the tile when [glyphSize] is not given.
  static const double _glyphRatio = 0.62;

  final FamilyHue hue;
  final IconData glyph;
  final double extent;
  final double? glyphSize;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: extent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(extent * cornerRatio),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [hue.tileSheen, hue.tileFill],
          ),
        ),
        child: Icon(
          glyph,
          size: glyphSize ?? (extent * _glyphRatio).roundToDouble(),
          color: hue.onTile,
        ),
      ),
    ),
  );
}
