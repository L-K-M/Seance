import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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

  static SeanceChrome of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<SeanceChrome>() ??
        _chromeFor(theme.brightness, theme.platform);
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
    );
  }

  /// Colors blend so chrome regions fade with the rest of a theme change.
  /// The metrics step instead: they differ by platform, not brightness, so
  /// a light/dark switch never moves them, and a half-way row height would
  /// only reflow the lists mid-animation.
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
    );
  }
}

SeanceChrome _chromeFor(Brightness brightness, TargetPlatform platform) {
  final n = brightness == Brightness.dark ? _dark : _light;
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
    onSelection: const Color(0xFFFFFFFF),
    inactiveSelectionFill: n.containerHighest,
    activePaneIndicator: n.primary,
    secondaryText: n.onSurfaceVariant,
    headerHeight: platform == TargetPlatform.macOS ? 52 : (desktop ? 44 : 56),
    rowExtent: desktop ? 22 : 48,
    sidebarRowExtent: desktop ? 26 : 48,
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

/// Séance's theme: the sibling neutrals (above) with a muted violet
/// accent — a calm, slightly spectral palette that reads well behind a
/// terminal in both light and dark.
class SeanceTheme {
  /// The muted violet the accent family derives from. Public because the
  /// server colour picker starts from it when no accent is chosen yet.
  static const Color seed = Color(0xFF6B5BD2);

  /// [platform] overrides the host platform the type ramp and row extents
  /// are chosen for — tests and captures render the desktop rail and the
  /// phone home from one host.
  static ThemeData light({TargetPlatform? platform}) =>
      _base(Brightness.light, platform);
  static ThemeData dark({TargetPlatform? platform}) =>
      _base(Brightness.dark, platform);

  static ThemeData _base(Brightness brightness, TargetPlatform? override) {
    final n = brightness == Brightness.dark ? _dark : _light;
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness)
        .copyWith(
          surface: n.surface,
          surfaceContainerLowest: n.containerLowest,
          surfaceContainerLow: n.containerLow,
          surfaceContainer: n.container,
          surfaceContainerHigh: n.containerHigh,
          surfaceContainerHighest: n.containerHighest,
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
    final platform = override ?? defaultTargetPlatform;
    final desktop = _isDesktop(platform);
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      platform: override,
    );
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
        style: MenuStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
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
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      extensions: [_chromeFor(brightness, platform)],
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

/// Colors for the online/offline/connecting/unknown indicator dots.
class StatusColors {
  // Darken light-theme indicators to stay legible on tinted containers too.
  static Color online(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
          ? const Color(0xFF1A7F37)
          : const Color(0xFF3FB950);

  static Color offline(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
          ? const Color(0xFFCF222E)
          : const Color(0xFFFF7B72);

  /// A session still negotiating: amber, the sibling apps' "in progress"
  /// dot (Poltergeist's plan, 10 §5).
  static Color connecting(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
          ? const Color(0xFFB06E00)
          : const Color(0xFFD29922);

  static Color unknown(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
          ? const Color(0xFF57606A)
          : const Color(0xFF8B949E);
}
