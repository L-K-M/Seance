import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../main.dart';
import 'command_generator.dart';
import 'settings_screen.dart';

bool _settingsRouteOpen = false;

/// Open Settings as a route on the root navigator. Safe to call from menu
/// callbacks and shortcuts (needs no [BuildContext]); guards against stacking
/// duplicate Settings routes when triggered repeatedly.
void openSettings() {
  if (_settingsRouteOpen) return;
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  _settingsRouteOpen = true;
  nav
      .push(MaterialPageRoute(builder: (_) => const SettingsScreen()))
      .whenComplete(() => _settingsRouteOpen = false);
}

/// Open the command generator for the active session. Used by the macOS menu
/// item and ⌘K; nudges the user to Settings if the assistant isn't set up.
void openCommandGenerator(AppState state) {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  if (!state.llmConfigured) {
    ScaffoldMessenger.of(ctx).showSnackBar(
      const SnackBar(content: Text('Configure the assistant in Settings first.')),
    );
    return;
  }
  showCommandGenerator(ctx, state);
}

/// Cross-platform keyboard shortcuts for the menu commands. On macOS the native
/// menu (wired in MainFlutterWindow.swift) owns ⌘, and ⌘K; this covers
/// Linux/Windows, where there is no system menu bar. The native menu and these
/// shortcuts share [openSettings]'s dedupe guard.
class AppMenus extends StatelessWidget {
  final Widget child;
  const AppMenus({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            openSettings,
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            openSettings,
      },
      child: child,
    );
  }
}
