import 'package:flutter/material.dart';

/// Séance's theme. A calm, slightly spectral palette that reads well behind a
/// terminal in both light and dark.
class SeanceTheme {
  static const _seed = Color(0xFF6B5BD2); // muted violet

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.comfortable,
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

/// Colors for the online/offline/unknown indicator dots.
class StatusColors {
  static Color online(BuildContext _) => const Color(0xFF3FB950); // green
  static Color offline(BuildContext _) => const Color(0xFFF85149); // red
  static Color unknown(BuildContext _) => const Color(0xFF8B949E); // grey
}
