import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_state.dart';
import 'services/app_services.dart';
import 'services/macos_titlebar.dart';
import 'services/secure_master_key.dart';
import 'services/settings_window.dart';
import 'services/window_state.dart';
import 'settings_window_app.dart';
import 'theme.dart';
import 'theme/app_appearance.dart';
import 'ui/adaptive_shell.dart';
import 'ui/app_menus.dart';
import 'ui/host_key_dialog.dart';
import 'ui/keyboard_interactive_dialog.dart';
import 'ui/macos_toolbar_band.dart';
import 'ui/top_toast.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Opens Settings in its own window, on desktop once the app has started.
/// Null on mobile, where Settings is a route, and before bootstrap finishes.
SettingsWindowHost? settingsWindowHost;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // The settings window's engine runs this same entrypoint, and gets the
  // Settings screen rather than a second copy of the app.
  if (args.contains(settingsWindowArgument)) {
    await runSettingsWindow();
    return;
  }
  // macOS: the integrated titlebar goes in while the window is still
  // hidden, so it never shows the standard one first.
  final toolbarBand = !kIsWeb && Platform.isMacOS
      ? await MacosTitlebar.install()
      : null;
  // Put the desktop window back where it was closed (size, monitor,
  // maximized/full-screen) before the first frame, and keep tracking it.
  // On macOS this is also what makes the hidden-at-launch window visible.
  await WindowStateService.restoreAndTrack();
  runApp(SeanceApp(toolbarBand: toolbarBand));
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
  const SeanceApp({
    super.key,
    @visibleForTesting this.initOverride,
    this.toolbarBand,
  });

  /// Test seam: replaces [_BootstrapState._init], whose platform-channel
  /// calls never complete in the widget-test environment.
  final Future<AppState> Function()? initOverride;

  /// Whether the macOS unified toolbar band shows, when the window has the
  /// integrated titlebar ([MacosTitlebar.install]); null everywhere else,
  /// and then no surface reserves a band.
  final ValueListenable<bool>? toolbarBand;

  @override
  Widget build(BuildContext context) =>
      _Bootstrap(initOverride: initOverride, toolbarBand: toolbarBand);
}

/// Initializes services asynchronously, then installs the app shell and wires
/// the host-key / keyboard-interactive dialog hooks.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap({this.initOverride, this.toolbarBand});
  final Future<AppState> Function()? initOverride;
  final ValueListenable<bool>? toolbarBand;
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> with WidgetsBindingObserver {
  AppState? _state;
  Object? _error;

  /// The theme until the state exists to say otherwise: the settings are
  /// read during bootstrap, so the spinner is drawn in the default theme.
  final ValueNotifier<AppAppearance> _bootAppearance = ValueNotifier(
    AppAppearance.initial,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bootAppearance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // Pause the reachability probe while the app isn't in the foreground.
    _state?.setForeground(lifecycle == AppLifecycleState.resumed);
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
    state.keyboardInteractiveResponder = (challenge) async {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return const <String>[];
      return showKeyboardInteractiveDialog(ctx, challenge);
    };

    await state.load();
    if (Platform.isMacOS) installMacMenu(state);
    if (!kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
      settingsWindowHost = SettingsWindowHost(state);
    }
    _warnIfSettingsWereRecovered(state);
    _warnIfKeystoreUnavailable(state);
    // Fire-and-forget: don't let a slow/offline update check hold up startup.
    unawaited(_checkForUpdate(state));
    return state;
  }

  /// The OS keystore was down at bootstrap (locked login keyring, no Secret
  /// Service daemon — the app still started, but saved passwords/keys/tokens
  /// are unreachable). Tell the user, once, with a retry: a locked keyring on
  /// an auto-login machine unlocks without any Séance change, and
  /// gnome-keyring appears on minimal desktops after one install + relaunch.
  void _warnIfKeystoreUnavailable(AppState state) {
    final masterKeys = state.services.masterKeys;
    if (masterKeys.keystoreStatus != KeystoreStatus.unavailable) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = navigatorKey.currentContext;
      if (context == null) return;
      showTopToast(
        Overlay.of(context, rootOverlay: true),
        message: 'The OS keyring is locked or unavailable '
            '(${masterKeys.lastKeystoreError ?? 'no details'}) — saved '
            'passwords, keys, and tokens are unreachable. Unlock the login '
            'keyring (or install gnome-keyring), then retry.',
        duration: const Duration(seconds: 12),
        actionLabel: 'Retry',
        onAction: () => unawaited(_retryKeystoreUnlock(state)),
      );
    });
  }

  Future<void> _retryKeystoreUnlock(AppState state) async {
    if (await state.services.unlockVaultFromKeystore()) {
      await state.onVaultUnlocked();
      final context = navigatorKey.currentContext;
      if (context == null) return;
      showTopToast(
        // navigatorKey's context is the root Navigator's — it outlives the
        // awaits above; the lint can't see that this isn't widget-local.
        // ignore: use_build_context_synchronously
        Overlay.of(context, rootOverlay: true),
        message: 'Keyring unlocked — saved secrets are available again.',
      );
    } else {
      // Still locked: re-show the warning with the (possibly newer) reason.
      _warnIfKeystoreUnavailable(state);
    }
  }

  /// Tell the user their settings file could not be read, once, after the shell
  /// is up. The bad file is kept next to the new one as `settings.json.corrupt`
  /// so nothing is lost silently.
  void _warnIfSettingsWereRecovered(AppState state) {
    if (!state.services.settingsWereRecovered) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = navigatorKey.currentContext;
      if (context == null) return;
      showTopToast(
        Overlay.of(context, rootOverlay: true),
        message:
            'Your settings file could not be read and was reset. The previous '
            'one is kept as settings.json.corrupt — check Settings before '
            'syncing.',
        duration: const Duration(seconds: 10),
      );
    });
  }

  /// Look up the running version and ask AppState to check GitHub for a newer
  /// release. Best-effort; a failure here must never affect startup.
  Future<void> _checkForUpdate(AppState state) async {
    try {
      final info = await PackageInfo.fromPlatform();
      await state.checkForUpdate(info.version);
    } catch (_) {
      // No version info / platform channel unavailable — skip silently.
    }
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
    // Rebuilt for a theme change and nothing else: AppState notifies for
    // every connection, probe and tab change, and this widget never listens
    // to it, only to the appearance notifier, which moves when the
    // Appearance tab writes.
    return ValueListenableBuilder<AppAppearance>(
      valueListenable: _state?.appearance ?? _bootAppearance,
      builder: (context, appearance, _) {
        final themes = SeanceTheme.forAppearance(appearance);
        return MaterialApp(
          title: 'Séance',
          navigatorKey: navigatorKey,
          theme: themes.theme,
          darkTheme: themes.darkTheme,
          themeMode: themes.themeMode,
          // The band is reserved above every route; the wide layout's
          // header takes it back (ClaimMacosToolbarBand).
          builder: (context, child) => AppScope(
            state: _state,
            child: withMacosToolbarBand(widget.toolbarBand, child: child!),
          ),
          home: home,
        );
      },
    );
  }
}
