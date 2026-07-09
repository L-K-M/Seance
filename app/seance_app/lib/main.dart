import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'services/app_services.dart';
import 'theme.dart';
import 'ui/adaptive_shell.dart';
import 'ui/app_menus.dart';
import 'ui/host_key_dialog.dart';
import 'ui/keyboard_interactive_dialog.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SeanceApp());
}

/// Exposes [AppState] to the widget tree. The instance itself never changes
/// once initialized; widgets listen to it with [ListenableBuilder] for
/// reactive rebuilds. [state] is null only during bootstrap, before any
/// widget that calls [of] exists.
class AppScope extends InheritedWidget {
  final AppState? state;
  const AppScope({super.key, required this.state, required super.child});

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope?.state != null, 'AppScope not found (or not initialized yet)');
    return scope!.state!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.state != state;
}

class SeanceApp extends StatelessWidget {
  const SeanceApp({super.key, @visibleForTesting this.initOverride});

  /// Test seam: replaces [_BootstrapState._init], whose platform-channel
  /// calls never complete in the widget-test environment.
  final Future<AppState> Function()? initOverride;

  @override
  Widget build(BuildContext context) => _Bootstrap(initOverride: initOverride);
}

/// Initializes services asynchronously, then installs the app shell and wires
/// the host-key / keyboard-interactive dialog hooks.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap({this.initOverride});
  final Future<AppState> Function()? initOverride;
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  AppState? _state;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final state = await (widget.initOverride ?? _init)();
      if (mounted) setState(() => _state = state);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<AppState> _init() async {
    final services = await AppServices.initialize();
    final state = AppState(services);

    // Wire interactive prompts to real dialogs via the root navigator.
    state.hostKeyPrompter = (decision) async {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return false;
      return showHostKeyDialog(ctx, decision);
    };
    state.keyboardInteractiveResponder = (prompts, name, instruction) async {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return const <String>[];
      return showKeyboardInteractiveDialog(ctx, prompts, name, instruction);
    };

    await state.load();
    _installMacMenu(state);
    return state;
  }

  /// Wire the native macOS menu items (MainFlutterWindow.swift) to app actions.
  void _installMacMenu(AppState state) {
    if (!Platform.isMacOS) return;
    const channel = MethodChannel('seance/menu');
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'openSettings':
          openSettings();
        case 'generateCommand':
          openCommandGenerator(state);
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
  }

  @override
  Widget build(BuildContext context) {
    // ONE MaterialApp for every bootstrap phase — only `home:` changes as
    // init progresses. Replacing the whole MaterialApp per phase would move
    // the global navigatorKey between Navigators mid-frame, which corrupts
    // the tree in release builds (the app freezes on the last-drawn frame).
    //
    // AppScope is injected via `builder`, which wraps the NAVIGATOR — so
    // pushed routes (Settings) resolve AppScope.of too, which an AppScope
    // inside `home:` would not provide.
    final Widget home;
    if (_error != null) {
      home = Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Failed to start Séance:\n$_error'),
          ),
        ),
      );
    } else if (_state == null) {
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else {
      home = const AppMenus(child: AdaptiveShell());
    }
    return MaterialApp(
      title: 'Séance',
      navigatorKey: navigatorKey,
      theme: SeanceTheme.light(),
      darkTheme: SeanceTheme.dark(),
      themeMode: ThemeMode.system,
      builder: (context, child) => AppScope(state: _state, child: child!),
      home: home,
    );
  }
}
