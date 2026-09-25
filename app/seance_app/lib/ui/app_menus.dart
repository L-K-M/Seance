import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../main.dart';
import '../services/local_settings_backend.dart';
import 'command_generator.dart';
import 'server_list_density.dart';
import 'server_list_pane.dart';
import 'settings_screen.dart';
import 'top_toast.dart';

bool _settingsRouteOpen = false;

/// Open Settings on [initialTab]: in its own window on desktop, as a route on
/// the root navigator elsewhere — and on desktop too when the runner cannot
/// open the window. Safe to call from menu callbacks and shortcuts (needs no
/// [BuildContext]); choosing Settings again brings the open window forward on
/// the new tab rather than opening a second one.
void openSettings([SettingsTab initialTab = SettingsTab.general]) {
  final host = settingsWindowHost;
  if (host == null) {
    _openSettingsRoute(initialTab);
    return;
  }
  unawaited(
    host
        .open(initialTab)
        .then(
          (opened) {
            if (!opened) _openSettingsRoute(initialTab);
          },
          onError: (Object error) {
            // The runner refused to open it; Settings must still be reachable.
            debugPrint('Settings window failed to open: $error');
            _openSettingsRoute(initialTab);
          },
        ),
  );
}

/// Settings as a route; guards against stacking duplicate Settings routes
/// when triggered repeatedly.
void _openSettingsRoute(SettingsTab initialTab) {
  if (_settingsRouteOpen) return;
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  _settingsRouteOpen = true;
  nav
      .push(
        MaterialPageRoute(
          builder: (context) => SettingsScreen(
            backend: LocalSettingsBackend(AppScope.of(context)),
            initialTab: initialTab,
          ),
        ),
      )
      .whenComplete(() => _settingsRouteOpen = false);
}

/// Open the command generator for the active session. Used by the macOS menu
/// item and ⌘K; nudges the user to Settings if the assistant isn't set up.
void openCommandGenerator(AppState state) {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  if (!state.llmConfigured) {
    showTopToastIn(ctx, message: 'Configure the assistant in Settings first.');
    return;
  }
  showCommandGenerator(ctx, state);
}

/// Open another terminal session for the currently selected server.
void openNewTab(AppState state) {
  final active = state.activeSession;
  if (active != null) state.newTab(active.config);
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
  // Start at row 0 so scrollback is included. (The old start of
  // `buffer.height - viewHeight` is the top of the *visible* page, which
  // silently dropped everything scrolled off — contradicting this function's
  // own "scrollback included" contract.)
  controller.setSelection(
    buffer.createAnchor(0, 0),
    buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
  );
}

/// The channel the native macOS menu (MainFlutterWindow.swift) and Dart
/// talk over, both ways.
const MethodChannel macMenuChannel = MethodChannel('seance/menu');

/// Wire the native macOS menu items to app actions, and keep the one item
/// whose title Dart owns in step: View's density item, which names the
/// density it switches to ("Use Compact Sidebar Rows"). One item with a
/// flipping title rather than a checked pair, the pattern Poltergeist's
/// View menu uses for the same command (sibling contract §10.5).
void installMacMenu(AppState state, {MethodChannel channel = macMenuChannel}) {
  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'newTab':
        openNewTab(state);
      case 'openSettings':
        openSettings();
      case 'generateCommand':
        openCommandGenerator(state);
      case 'toggleServerListDensity':
        await state.setServerListDensity(switch (state.serverListDensity) {
          ServerListDensity.comfortable => ServerListDensity.compact,
          ServerListDensity.compact => ServerListDensity.comfortable,
        });
      // Native Edit menu, forwarded only when a terminal is focused.
      case 'editCopy':
        if (state.activeSession != null) terminalCopy(state.activeSession!);
      case 'editPaste':
        if (state.activeSession != null) {
          await terminalPaste(state.activeSession!);
        }
      case 'editSelectAll':
        if (state.activeSession != null) {
          terminalSelectAll(state.activeSession!);
        }
    }
    return null;
  });

  // Retitled on every density change, from the menu or either switch, and
  // on nothing else: the state notifies for far more than this.
  ServerListDensity? titled;
  void retitle() {
    final density = state.serverListDensity;
    if (density == titled) return;
    titled = density;
    unawaited(
      channel.invokeMethod<void>(
        'setServerListDensityTitle',
        _densityMenuTitle(density),
      ),
    );
  }

  retitle();
  state.addListener(retitle);
}

/// The View menu's density item at [current]: the choice it switches to.
String _densityMenuTitle(ServerListDensity current) => switch (current) {
  ServerListDensity.comfortable => 'Use Compact Sidebar Rows',
  ServerListDensity.compact => 'Use Comfortable Sidebar Rows',
};

/// The server filter's chord (Poltergeist's plan, 10 §5): ⌥⌘F on Apple
/// platforms, Ctrl+Alt+F elsewhere.
SingleActivator serverFilterActivator(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.macOS || TargetPlatform.iOS => const SingleActivator(
        LogicalKeyboardKey.keyF,
        meta: true,
        alt: true,
      ),
      _ => const SingleActivator(
        LogicalKeyboardKey.keyF,
        control: true,
        alt: true,
      ),
    };

/// [serverFilterActivator] as the app-wide binding takes it. On Windows it
/// stands down while the right Alt is held: Windows reports AltGr as Ctrl +
/// right Alt, AltGr+F types "[" on Czech, Slovak, Hungarian and other
/// layouts, and a handled key would swallow that character in every field
/// and terminal under [AppMenus]. The chord itself uses the left Alt.
final class _ServerFilterChord extends ShortcutActivator {
  const _ServerFilterChord(this._platform);

  final TargetPlatform _platform;

  SingleActivator get _chord => serverFilterActivator(_platform);

  @override
  Iterable<LogicalKeyboardKey>? get triggers => _chord.triggers;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      _chord.accepts(event, state) &&
      !(_platform == TargetPlatform.windows &&
          state.logicalKeysPressed.contains(LogicalKeyboardKey.altRight));

  @override
  String debugDescribeKeys() => _chord.debugDescribeKeys();
}

/// Cross-platform keyboard shortcuts for the menu commands. On macOS the native
/// menu (wired in MainFlutterWindow.swift) owns ⌘T, ⌘, and ⌘K; this also covers
/// Linux/Windows, where there is no system menu bar. The native menu and these
/// shortcuts share the same Dart actions.
class AppMenus extends StatelessWidget {
  final Widget child;
  const AppMenus({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return CallbackShortcuts(
      bindings: {
        _ServerFilterChord(Theme.of(context).platform): () =>
            ServerListPane.revealFilter(),
        const SingleActivator(LogicalKeyboardKey.keyT, meta: true): () =>
            openNewTab(state),
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): () =>
            openNewTab(state),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            openSettings,
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            openSettings,
      },
      child: child,
    );
  }
}
