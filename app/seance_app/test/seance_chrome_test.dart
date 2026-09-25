import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/theme.dart';

/// Every color token, named so a failure says which one stopped following.
final _colors = <String, Color Function(SeanceChrome)>{
  'sidebarBackground': (c) => c.sidebarBackground,
  'headerBackground': (c) => c.headerBackground,
  'paneBackground': (c) => c.paneBackground,
  'inspectorBackground': (c) => c.inspectorBackground,
  'separator': (c) => c.separator,
  'hoverFill': (c) => c.hoverFill,
  'capsuleFill': (c) => c.capsuleFill,
  'selectionFill': (c) => c.selectionFill,
  'onSelection': (c) => c.onSelection,
  'inactiveSelectionFill': (c) => c.inactiveSelectionFill,
  'activePaneIndicator': (c) => c.activePaneIndicator,
  'secondaryText': (c) => c.secondaryText,
};

void main() {
  final lightTheme = SeanceTheme.light();
  final darkTheme = SeanceTheme.dark();
  final light = lightTheme.extension<SeanceChrome>()!;
  final dark = darkTheme.extension<SeanceChrome>()!;

  // MaterialApp animates a light/dark switch through ThemeData.lerp, which
  // lerps extensions too: a stepped lerp would hold the chrome-painted
  // regions and then snap them halfway while Material surfaces fade.
  test('chrome colors follow a light/dark theme animation', () {
    const t = 0.25;
    final animated = ThemeData.lerp(
      lightTheme,
      darkTheme,
      t,
    ).extension<SeanceChrome>()!;

    for (final MapEntry(key: name, value: color) in _colors.entries) {
      expect(
        color(animated),
        Color.lerp(color(light), color(dark), t),
        reason: name,
      );
    }
  });

  test('copyWith replaces only the fields it is given', () {
    const separator = Color(0xFF123456);
    final copy = light.copyWith(separator: separator, rowExtent: 30);

    expect(copy.separator, separator);
    expect(copy.rowExtent, 30);
    for (final MapEntry(key: name, value: color) in _colors.entries) {
      if (name == 'separator') continue;
      expect(color(copy), color(light), reason: name);
    }
    expect(copy.headerHeight, light.headerHeight);
    expect(copy.sidebarRowExtent, light.sidebarRowExtent);
    expect(copy.cornerScale, light.cornerScale);
  });

  // Material's own shapes lerp through a theme change, so the hand-drawn
  // corners that follow the same scale blend with them.
  test('the corner scale blends like the shapes it follows', () {
    final square = light.copyWith(cornerScale: 0);
    final round = light.copyWith(cornerScale: 2);
    expect(square.lerp(round, 0.25).cornerScale, 0.5);
    expect(round.corner(6), 12);
  });
}
