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

/// Copy the active terminal's selection to the clipboard. Returns false when
/// nothing is selected (so a keypress can fall through). Shared by the terminal
/// right-click menu, the keyboard shortcut, and the native macOS Edit ▸ Copy.
bool terminalCopy(TerminalSession tab) {
  final controller = tab.controller;
  if (controller == null) return false;
  final selection = controller.selection;
  if (selection == null) return false;
  final text = tab.engine.terminal.buffer.getText(selection);
  if (text.isEmpty) return false;
  Clipboard.setData(ClipboardData(text: text));
  return true;
}

/// Paste clipboard text into the active terminal (honours bracketed-paste mode).
Future<void> terminalPaste(TerminalSession tab) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text;
  if (text != null && text.isNotEmpty) {
    tab.engine.terminal.paste(text);
  }
}

/// Select the active terminal's whole buffer (scrollback included).
void terminalSelectAll(TerminalSession tab) {
  final controller = tab.controller;
  if (controller == null) return;
  final terminal = tab.engine.terminal;
  final buffer = terminal.buffer;
  controller.setSelection(
    buffer.createAnchor(0, buffer.height - terminal.viewHeight),
    buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
  );
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
