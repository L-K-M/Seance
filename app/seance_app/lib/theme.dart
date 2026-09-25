import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'family_hues.dart';
import 'theme/app_appearance.dart';
import 'theme/contrast.dart';
import 'theme/theme_palette.dart';
import 'theme/theme_presets.dart';

/// The sibling design tokens Séance shares with Poltergeist (Poltergeist
/// D32 §10): the same slate-dark and Finder-light neutrals, 13 px desktop
/// type and dense rows, with Séance's own violet accent — so the two
/// apps read as one product family. Poltergeist's copy lives in its
/// lib/theme/app_theme.dart (`PoltergeistChrome`); keep the tables in
/// step.
class _Neutrals {
  const _Neutrals({
    required this.surface,
    required this.containerLowest,
    required this.containerLow,
    required this.container,
    required this.containerHigh,
    required this.containerHighest,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.selection,
  });

  final Color surface;
  final Color containerLowest;
  final Color containerLow;
  final Color container;
  final Color containerHigh;
  final Color containerHighest;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;
  final Color inverseSurface;
  final Color onInverseSurface;
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color selection;
}

const _dark = _Neutrals(
  surface: Color(0xFF232932),
  containerLowest: Color(0xFF1C2128),
  containerLow: Color(0xFF2A313B),
  container: Color(0xFF2D3440),
  containerHigh: Color(0xFF353D49),
  containerHighest: Color(0xFF3B4452),
  onSurface: Color(0xFFE7EAEF),
  onSurfaceVariant: Color(0xFFB4BCC8),
  outline: Color(0xFF6B7584),
  outlineVariant: Color(0xFF3A424E),
  inverseSurface: Color(0xFFE7EAEF),
  onInverseSurface: Color(0xFF232932),
  primary: Color(0xFFADA1FF),
  onPrimary: Color(0xFF1D1452),
  primaryContainer: Color(0xFF43388F),
  onPrimaryContainer: Color(0xFFE6E0FF),
  secondaryContainer: Color(0xFF3B4758),
  onSecondaryContainer: Color(0xFFDCE4EF),
  selection: Color(0xFF5A4BC0),
);

const _light = _Neutrals(
  surface: Color(0xFFFFFFFF),
  containerLowest: Color(0xFFFFFFFF),
  containerLow: Color(0xFFF1F2F4),
  container: Color(0xFFF6F6F8),
  containerHigh: Color(0xFFEBECEF),
  containerHighest: Color(0xFFE2E5EA),
  onSurface: Color(0xFF1C1F24),
  onSurfaceVariant: Color(0xFF596170),
  outline: Color(0xFF7D8591),
  outlineVariant: Color(0xFFDADDE3),
  inverseSurface: Color(0xFF2D323A),
  onInverseSurface: Color(0xFFF1F2F4),
  primary: Color(0xFF5847C2),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFE6E0FF),
  onPrimaryContainer: Color(0xFF1D1452),
  secondaryContainer: Color(0xFFDCE3EC),
  onSecondaryContainer: Color(0xFF18222E),
  selection: Color(0xFF5A4BC0),
);

bool _isDesktop(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS || TargetPlatform.linux || TargetPlatform.windows => true,
  _ => false,
};

const Color _white = Color(0xFFFFFFFF);
const Color _black = Color(0xFF000000);

/// How far each Automatic shade is mixed from a palette's own surface
/// toward its text (or, for secondary text, from the text toward the
/// surface). Measured against the dark table: mixed from its own surface
/// and text, these land within 6 units per channel of its container ladder
/// and lines, and within 18 of its secondary text and outline, which the
/// table tints bluer than a straight mix can — so a palette that brings a
/// surface of its own gets a ladder shaped like the one it replaces.
const double _sidebarMix = 0.04;
const double _raisedMix = 0.06;
const double _highMix = 0.05;
const double _highestMix = 0.08;
const double _secondaryTextMix = 0.3;
const double _outlineMix = 0.45;
const double _hairlineMix = 0.14;
const double _secondaryContainerMix = 0.22;
const double _lowestMix = 0.2;

/// The WCAG AA ratio for body text, which a derived selection pill keeps
/// under white text.
const double _textContrast = 4.5;

Color _mix(Color from, Color to, double t) => Color.lerp(from, to, t)!;

/// The brightness [palette] is drawn at when Automatic colours follow
/// [brightness]: see [resolveBrightness].
Brightness _drawnAt(ThemePalette palette, Brightness brightness) {
  final surface = palette.surface;
  return surface == null ? brightness : surfaceBrightness(surface);
}

/// The neutrals [palette] draws with at [brightness] (already resolved by
/// [_drawnAt]): the table for that brightness, with every slot the palette
/// sets laid over it.
///
/// An Automatic slot is the table's while the surface is the table's too.
/// Once the palette brings a surface of its own, the Automatic slots are
/// mixed from that surface and the palette's text instead: the table's
/// slate rail beside a Solarized pane would be neither theme. The default
/// palette sets nothing, so it gets the tables unchanged.
_Neutrals _neutralsFor(ThemePalette palette, Brightness brightness) {
  final table = brightness == Brightness.dark ? _dark : _light;
  final ownSurface = palette.surface != null;
  final surface = palette.surface ?? table.surface;
  final text = palette.text ?? table.onSurface;
  Color auto(Color fromTable, Color mixed) => ownSurface ? mixed : fromTable;

  // The rest of the container ladder hangs off the raised colour, so a
  // palette that sets only that still gets high and highest ordered above
  // it rather than the table's, which may sit below it.
  final container =
      palette.raised ?? auto(table.container, _mix(surface, text, _raisedMix));
  final ownContainer = ownSurface || palette.raised != null;

  // The table's primary family is the hand-tuned rendering of the violet
  // seed (a lighter violet on dark, a deeper one on light, each clearing
  // its surface), so the seed keeps it. Any other accent is drawn as
  // picked, which is what the colour well promises; its containers come
  // from Material's scheme for it.
  final tuned = palette.accent == SeanceTheme.seed;
  final seeded = tuned
      ? null
      : ColorScheme.fromSeed(seedColor: palette.accent, brightness: brightness);
  final primary = tuned ? table.primary : palette.accent;

  return _Neutrals(
    surface: surface,
    containerLowest: auto(
      table.containerLowest,
      _mix(
        surface,
        brightness == Brightness.dark ? _black : _white,
        _lowestMix,
      ),
    ),
    containerLow:
        palette.sidebar ??
        auto(table.containerLow, _mix(surface, text, _sidebarMix)),
    container: container,
    containerHigh: ownContainer
        ? _mix(container, text, _highMix)
        : table.containerHigh,
    containerHighest: ownContainer
        ? _mix(container, text, _highestMix)
        : table.containerHighest,
    onSurface: text,
    onSurfaceVariant:
        palette.secondaryText ??
        auto(table.onSurfaceVariant, _mix(text, surface, _secondaryTextMix)),
    outline: auto(table.outline, _mix(surface, text, _outlineMix)),
    outlineVariant:
        palette.hairline ??
        auto(table.outlineVariant, _mix(surface, text, _hairlineMix)),
    inverseSurface: auto(table.inverseSurface, text),
    onInverseSurface: auto(table.onInverseSurface, surface),
    primary: primary,
    onPrimary: seeded == null ? table.onPrimary : legibleOn(primary),
    primaryContainer: seeded?.primaryContainer ?? table.primaryContainer,
    onPrimaryContainer: seeded?.onPrimaryContainer ?? table.onPrimaryContainer,
    secondaryContainer: auto(
      table.secondaryContainer,
      _mix(surface, primary, _secondaryContainerMix),
    ),
    onSecondaryContainer: auto(table.onSecondaryContainer, text),
    selection:
        palette.selection ??
        (tuned ? table.selection : _selectionFor(palette.accent)),
  );
}

/// An Automatic selection pill for an accent other than the seed: the
/// accent's own hue, darkened until white text on it clears 4.5:1 — the
/// convention the table's violet pill keeps. The accent itself when it
/// already does.
Color _selectionFor(Color accent) {
  const steps = 20;
  for (var step = 0; step < steps; step++) {
    final candidate = _mix(accent, _black, step / steps);
    if (contrastRatio(_white, candidate) >= _textContrast) return candidate;
  }
  return _black;
}

/// The status dots' colours for [palette] at [brightness]. The Automatic
/// ones are the colours the dots always had: darkened on light surfaces to
/// stay legible on tinted containers too.
SeanceStatusColors _statusFor(ThemePalette palette, Brightness brightness) {
  final light = brightness == Brightness.light;
  return SeanceStatusColors(
    online:
        palette.online ??
        (light ? const Color(0xFF1A7F37) : const Color(0xFF3FB950)),
    offline:
        palette.offline ??
        (light ? const Color(0xFFCF222E) : const Color(0xFFFF7B72)),
    // A session still negotiating: amber, the sibling apps' "in progress"
    // dot (Poltergeist's plan, 10 §5).
    connecting:
        palette.connecting ??
        (light ? const Color(0xFFB06E00) : const Color(0xFFD29922)),
    unknown:
        palette.unknown ??
        (light ? const Color(0xFF57606A) : const Color(0xFF8B949E)),
  );
}

/// The chrome tokens the shell regions paint — the same fields as
/// Poltergeist's `PoltergeistChrome`, so shared widgets (the sibling
/// sidebar kit) port with a rename only.
@immutable
class SeanceChrome extends ThemeExtension<SeanceChrome> {
  const SeanceChrome({
    required this.sidebarBackground,
    required this.headerBackground,
    required this.paneBackground,
    required this.inspectorBackground,
    required this.separator,
    required this.hoverFill,
    required this.capsuleFill,
    required this.selectionFill,
    required this.onSelection,
    required this.inactiveSelectionFill,
    required this.activePaneIndicator,
    required this.secondaryText,
    required this.headerHeight,
    required this.rowExtent,
    required this.sidebarRowExtent,
    this.cornerScale = 1,
  });

  final Color sidebarBackground;
  final Color headerBackground;
  final Color paneBackground;
  final Color inspectorBackground;
  final Color separator;
  final Color hoverFill;
  final Color capsuleFill;
  final Color selectionFill;
  final Color onSelection;
  final Color inactiveSelectionFill;
  final Color activePaneIndicator;
  final Color secondaryText;
  final double headerHeight;
  final double rowExtent;
  final double sidebarRowExtent;

  /// The theme's corner multiplier ([ThemePalette.cornerScale]), for what
  /// the app draws by hand: Material's components take it through their
  /// own themes, and a hand-drawn pill opts in with [corner].
  final double cornerScale;

  /// A [base] corner radius as the theme scales it.
  double corner(double base) => base * cornerScale;

  static SeanceChrome of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<SeanceChrome>() ??
        _chromeFor(
          _neutralsFor(ThemePresets.initial, theme.brightness),
          theme.platform,
        );
  }

  @override
  SeanceChrome copyWith({
    Color? sidebarBackground,
    Color? headerBackground,
    Color? paneBackground,
    Color? inspectorBackground,
    Color? separator,
    Color? hoverFill,
    Color? capsuleFill,
    Color? selectionFill,
    Color? onSelection,
    Color? inactiveSelectionFill,
    Color? activePaneIndicator,
    Color? secondaryText,
    double? headerHeight,
    double? rowExtent,
    double? sidebarRowExtent,
    double? cornerScale,
  }) {
    return SeanceChrome(
      sidebarBackground: sidebarBackground ?? this.sidebarBackground,
      headerBackground: headerBackground ?? this.headerBackground,
      paneBackground: paneBackground ?? this.paneBackground,
      inspectorBackground: inspectorBackground ?? this.inspectorBackground,
      separator: separator ?? this.separator,
      hoverFill: hoverFill ?? this.hoverFill,
      capsuleFill: capsuleFill ?? this.capsuleFill,
      selectionFill: selectionFill ?? this.selectionFill,
      onSelection: onSelection ?? this.onSelection,
      inactiveSelectionFill:
          inactiveSelectionFill ?? this.inactiveSelectionFill,
      activePaneIndicator: activePaneIndicator ?? this.activePaneIndicator,
      secondaryText: secondaryText ?? this.secondaryText,
      headerHeight: headerHeight ?? this.headerHeight,
      rowExtent: rowExtent ?? this.rowExtent,
      sidebarRowExtent: sidebarRowExtent ?? this.sidebarRowExtent,
      cornerScale: cornerScale ?? this.cornerScale,
    );
  }

  /// Colors blend so chrome regions fade with the rest of a theme change.
  /// The metrics step instead: they differ by platform, not brightness, so
  /// a light/dark switch never moves them, and a half-way row height would
  /// only reflow the lists mid-animation. Corners blend like Material's own
  /// shapes do, which are lerped through the same animation.
  @override
  SeanceChrome lerp(SeanceChrome? other, double t) {
    if (other == null) return this;
    return SeanceChrome(
      sidebarBackground:
          Color.lerp(sidebarBackground, other.sidebarBackground, t)!,
      headerBackground: Color.lerp(headerBackground, other.headerBackground, t)!,
      paneBackground: Color.lerp(paneBackground, other.paneBackground, t)!,
      inspectorBackground:
          Color.lerp(inspectorBackground, other.inspectorBackground, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      hoverFill: Color.lerp(hoverFill, other.hoverFill, t)!,
      capsuleFill: Color.lerp(capsuleFill, other.capsuleFill, t)!,
      selectionFill: Color.lerp(selectionFill, other.selectionFill, t)!,
      onSelection: Color.lerp(onSelection, other.onSelection, t)!,
      inactiveSelectionFill:
          Color.lerp(inactiveSelectionFill, other.inactiveSelectionFill, t)!,
      activePaneIndicator:
          Color.lerp(activePaneIndicator, other.activePaneIndicator, t)!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      headerHeight: t < 0.5 ? headerHeight : other.headerHeight,
      rowExtent: t < 0.5 ? rowExtent : other.rowExtent,
      sidebarRowExtent: t < 0.5 ? sidebarRowExtent : other.sidebarRowExtent,
      cornerScale: lerpDouble(cornerScale, other.cornerScale, t)!,
    );
  }
}

/// The chrome [n] paints, on [platform]. [cornerScale] rides along for
/// the hand-drawn corners (see [SeanceChrome.corner]).
SeanceChrome _chromeFor(
  _Neutrals n,
  TargetPlatform platform, {
  double cornerScale = 1,
}) {
  final desktop = _isDesktop(platform);
  return SeanceChrome(
    sidebarBackground: n.containerLow,
    headerBackground: n.container,
    paneBackground: n.surface,
    inspectorBackground: n.containerLow,
    separator: n.outlineVariant,
    hoverFill: n.onSurface.withValues(alpha: 0.06),
    capsuleFill: n.containerHigh,
    selectionFill: n.selection,
    // Chosen against the pill as it shows on the rail, since a palette may
    // make the pill a tint: white for every pill the table has, black for a
    // palette that picks a light one (High contrast's yellow).
    onSelection: legibleOn(compositeOver(n.selection, n.containerLow)),
    inactiveSelectionFill: n.containerHighest,
    activePaneIndicator: n.primary,
    secondaryText: n.onSurfaceVariant,
    headerHeight: platform == TargetPlatform.macOS ? 52 : (desktop ? 44 : 56),
    rowExtent: desktop ? 22 : 48,
    sidebarRowExtent: desktop ? 26 : 48,
    cornerScale: cornerScale,
  );
}

TextTheme _desktopText(TextTheme base) => base.copyWith(
  titleLarge: base.titleLarge?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
  titleMedium: base.titleMedium?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
  titleSmall: base.titleSmall?.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
  bodyLarge: base.bodyLarge?.copyWith(fontSize: 14),
  bodyMedium: base.bodyMedium?.copyWith(fontSize: 13),
  bodySmall: base.bodySmall?.copyWith(fontSize: 12),
  labelLarge: base.labelLarge?.copyWith(fontSize: 13),
  labelMedium: base.labelMedium?.copyWith(fontSize: 12),
  labelSmall: base.labelSmall?.copyWith(fontSize: 11, letterSpacing: 0.2),
);

/// Material's own corner radii, which [ThemePalette.cornerScale] scales:
/// the M3 defaults, except the menu's and the tooltip's, which the sibling
/// apps set themselves. A button's is half its standard 40 px height,
/// where Material draws a stadium.
const double _dialogRadius = 28;
const double _cardRadius = 12;
const double _menuRadius = 8;
const double _popupMenuRadius = 4;
const double _tooltipRadius = 6;
const double _inputRadius = 4;
const double _buttonRadius = 20;
const double _chipRadius = 8;
const double _bottomSheetRadius = 28;
const double _snackBarRadius = 4;

/// Séance's theme: a [ThemePalette] over the sibling neutrals (above). The
/// default palette is the muted violet accent over the tables unchanged — a
/// calm, slightly spectral look that reads well behind a terminal in both
/// light and dark.
class SeanceTheme {
  /// The muted violet the accent family derives from, and the default
  /// preset's accent. Public because the server colour picker starts from
  /// it when no accent is chosen yet.
  static const Color seed = Color(0xFF6B5BD2);

  /// The default palette's themes. [platform] overrides the host platform
  /// the type ramp and row extents are chosen for — tests and captures
  /// render the desktop rail and the phone home from one host.
  static ThemeData light({TargetPlatform? platform}) =>
      build(ThemePresets.initial, Brightness.light, platform: platform);
  static ThemeData dark({TargetPlatform? platform}) =>
      build(ThemePresets.initial, Brightness.dark, platform: platform);

  /// The three theme arguments of a MaterialApp drawn in [appearance].
  ///
  /// A palette with its own surface is one theme, at that surface's
  /// brightness, whatever the system or the mode says; otherwise a light
  /// and a dark one, picked between by the mode.
  static ({ThemeData theme, ThemeData darkTheme, ThemeMode themeMode})
  forAppearance(AppAppearance appearance, {TargetPlatform? platform}) {
    final palette = appearance.palette;
    if (palette.surface != null) {
      final theme = build(palette, Brightness.light, platform: platform);
      return (theme: theme, darkTheme: theme, themeMode: ThemeMode.light);
    }
    return (
      theme: build(palette, Brightness.light, platform: platform),
      darkTheme: build(palette, Brightness.dark, platform: platform),
      themeMode: switch (appearance.mode) {
        ThemeModePreference.system => ThemeMode.system,
        ThemeModePreference.light => ThemeMode.light,
        ThemeModePreference.dark => ThemeMode.dark,
      },
    );
  }

  /// What every slot of [palette] draws as when its Automatic colours
  /// follow [brightness] — the colour an Automatic slot stands for right
  /// now, which is where the Appearance tab starts a slot that stops being
  /// Automatic, and what a preset's swatch shows.
  static Map<ThemeSlot, Color> resolvedSlots(
    ThemePalette palette,
    Brightness brightness,
  ) {
    final drawnAt = _drawnAt(palette, brightness);
    final n = _neutralsFor(palette, drawnAt);
    final status = _statusFor(palette, drawnAt);
    return {
      ThemeSlot.surface: n.surface,
      ThemeSlot.sidebar: n.containerLow,
      ThemeSlot.raised: n.container,
      ThemeSlot.text: n.onSurface,
      ThemeSlot.secondaryText: n.onSurfaceVariant,
      ThemeSlot.hairline: n.outlineVariant,
      ThemeSlot.selection: n.selection,
      ThemeSlot.online: status.online,
      ThemeSlot.offline: status.offline,
      ThemeSlot.connecting: status.connecting,
      ThemeSlot.unknown: status.unknown,
    };
  }

  /// [palette] as a theme. [brightness] is what its Automatic colours
  /// follow — the system's, or the mode's; a palette that sets its own
  /// surface is drawn at that surface's brightness instead (see
  /// [resolveBrightness]).
  static ThemeData build(
    ThemePalette palette,
    Brightness brightness, {
    TargetPlatform? platform,
  }) {
    final drawnAt = _drawnAt(palette, brightness);
    final n = _neutralsFor(palette, drawnAt);
    final ownSurface = palette.surface != null;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: drawnAt,
        ).copyWith(
          surface: n.surface,
          surfaceContainerLowest: n.containerLowest,
          surfaceContainerLow: n.containerLow,
          surfaceContainer: n.container,
          surfaceContainerHigh: n.containerHigh,
          surfaceContainerHighest: n.containerHighest,
          // The seed's own dim and bright stay with the tables, as they
          // always have; a surface of its own takes its ladder's ends.
          surfaceDim: ownSurface
              ? (drawnAt == Brightness.dark ? n.surface : n.containerHighest)
              : null,
          surfaceBright: ownSurface
              ? (drawnAt == Brightness.dark ? n.containerHighest : n.surface)
              : null,
          onSurface: n.onSurface,
          onSurfaceVariant: n.onSurfaceVariant,
          outline: n.outline,
          outlineVariant: n.outlineVariant,
          inverseSurface: n.inverseSurface,
          onInverseSurface: n.onInverseSurface,
          primary: n.primary,
          onPrimary: n.onPrimary,
          primaryContainer: n.primaryContainer,
          onPrimaryContainer: n.onPrimaryContainer,
          secondaryContainer: n.secondaryContainer,
          onSecondaryContainer: n.onSecondaryContainer,
        );
    final resolvedPlatform = platform ?? defaultTargetPlatform;
    final desktop = _isDesktop(resolvedPlatform);
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      platform: platform,
      // Null leaves the platform's own face, as before themes existed.
      fontFamily: palette.fontFamily,
    );
    final scale = palette.cornerScale;
    RoundedRectangleBorder rounded(double radius) => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius * scale),
    );
    // At the designed scale every component keeps Material's own shape
    // (its stadium buttons included), so the default theme is exactly what
    // it was before corners could change. Any other scale replaces each
    // with a rounded rectangle of its scaled radius.
    final scaled = scale != 1;
    final buttonShape = rounded(_buttonRadius);
    return base.copyWith(
      visualDensity: VisualDensity.comfortable,
      scaffoldBackgroundColor: scheme.surface,
      dividerColor: scheme.outlineVariant,
      hoverColor: n.onSurface.withValues(alpha: 0.06),
      textTheme: desktop ? _desktopText(base.textTheme) : base.textTheme,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      // The sibling apps' menus (the sidebar kit's context menus): 8 px
      // corners like every other surface, and on desktop the compact rows
      // Poltergeist's theme gives them, rather than touch-height items in
      // a pointer menu.
      menuTheme: MenuThemeData(
        style: MenuStyle(shape: WidgetStatePropertyAll(rounded(_menuRadius))),
      ),
      menuButtonTheme: desktop
          ? MenuButtonThemeData(
              style: MenuItemButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            )
          : null,
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(_tooltipRadius * scale),
        ),
      ),
      dialogTheme: scaled
          ? DialogThemeData(shape: rounded(_dialogRadius))
          : null,
      cardTheme: scaled ? CardThemeData(shape: rounded(_cardRadius)) : null,
      popupMenuTheme: scaled
          ? PopupMenuThemeData(shape: rounded(_popupMenuRadius))
          : null,
      // The underline Material draws by default, with its filled corners
      // scaled: an outline here would restyle every field in the app.
      inputDecorationTheme: scaled
          ? InputDecorationThemeData(
              border: UnderlineInputBorder(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(_inputRadius * scale),
                ),
              ),
            )
          : null,
      filledButtonTheme: scaled
          ? FilledButtonThemeData(
              style: FilledButton.styleFrom(shape: buttonShape),
            )
          : null,
      outlinedButtonTheme: scaled
          ? OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(shape: buttonShape),
            )
          : null,
      textButtonTheme: scaled
          ? TextButtonThemeData(style: TextButton.styleFrom(shape: buttonShape))
          : null,
      segmentedButtonTheme: scaled
          ? SegmentedButtonThemeData(
              style: ButtonStyle(shape: WidgetStatePropertyAll(buttonShape)),
            )
          : null,
      chipTheme: scaled ? ChipThemeData(shape: rounded(_chipRadius)) : null,
      bottomSheetTheme: scaled
          ? BottomSheetThemeData(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(_bottomSheetRadius * scale),
                ),
              ),
            )
          : null,
      snackBarTheme: scaled
          ? SnackBarThemeData(shape: rounded(_snackBarRadius))
          : null,
      extensions: [
        _chromeFor(n, resolvedPlatform, cornerScale: scale),
        _statusFor(palette, drawnAt),
        FamilyPalette.forBrightness(drawnAt),
      ],
    );
  }

  /// Monospace font stack for the terminal and code.
  static const List<String> monoFallback = [
    'JetBrains Mono',
    'SF Mono',
    'Menlo',
    'Consolas',
    'DejaVu Sans Mono',
    'monospace',
  ];
}

/// The four status dots' colours, as a theme carries them: the palette's,
/// or the brightness-aware defaults where it leaves them Automatic.
///
/// An extension of its own rather than fields on [SeanceChrome], whose
/// fields mirror Poltergeist's `PoltergeistChrome` one for one so the
/// shared sidebar kit ports with a rename.
@immutable
class SeanceStatusColors extends ThemeExtension<SeanceStatusColors> {
  const SeanceStatusColors({
    required this.online,
    required this.offline,
    required this.connecting,
    required this.unknown,
  });

  final Color online;
  final Color offline;
  final Color connecting;
  final Color unknown;

  static SeanceStatusColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<SeanceStatusColors>() ??
        _statusFor(ThemePresets.initial, theme.brightness);
  }

  @override
  SeanceStatusColors copyWith({
    Color? online,
    Color? offline,
    Color? connecting,
    Color? unknown,
  }) => SeanceStatusColors(
    online: online ?? this.online,
    offline: offline ?? this.offline,
    connecting: connecting ?? this.connecting,
    unknown: unknown ?? this.unknown,
  );

  /// Blended like the chrome's colours, so a dot fades with its row.
  @override
  SeanceStatusColors lerp(SeanceStatusColors? other, double t) {
    if (other == null) return this;
    return SeanceStatusColors(
      online: Color.lerp(online, other.online, t)!,
      offline: Color.lerp(offline, other.offline, t)!,
      connecting: Color.lerp(connecting, other.connecting, t)!,
      unknown: Color.lerp(unknown, other.unknown, t)!,
    );
  }
}

/// Colors for the online/offline/connecting/unknown indicator dots, from
/// the theme's [SeanceStatusColors].
class StatusColors {
  static Color online(BuildContext context) =>
      SeanceStatusColors.of(context).online;

  static Color offline(BuildContext context) =>
      SeanceStatusColors.of(context).offline;

  /// A session still negotiating: amber, unless the palette says otherwise.
  static Color connecting(BuildContext context) =>
      SeanceStatusColors.of(context).connecting;

  static Color unknown(BuildContext context) =>
      SeanceStatusColors.of(context).unknown;
}
