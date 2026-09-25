import 'package:flutter/material.dart';

import 'services/settings_window.dart';
import 'theme.dart';
import 'ui/settings_screen.dart';

/// The settings window's whole app. Its engine starts the same `main` as the
/// app's with [settingsWindowArgument], and `main` hands over to this instead
/// of starting a second Séance: no services, no window-state tracking, no
/// menus — only the Settings screen over the app's state, reached through
/// the link.
Future<void> runSettingsWindow() async {
  RemoteSettingsBackend? backend;
  Object? error;
  try {
    backend = await RemoteSettingsBackend.connect();
  } catch (e) {
    error = e;
  }
  runApp(SettingsWindowApp(backend: backend, error: error));
}

class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({super.key, required this.backend, this.error});

  /// Null when the app did not answer, in which case [error] says why.
  final RemoteSettingsBackend? backend;
  final Object? error;

  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

class _SettingsWindowAppState extends State<SettingsWindowApp> {
  /// Hands a request to quit the application to the app's isolate, which
  /// decides it: see [RemoteSettingsBackend.requestAppExit].
  AppLifecycleListener? _exitRequests;

  @override
  void initState() {
    super.initState();
    final backend = widget.backend;
    if (backend != null) {
      _exitRequests = AppLifecycleListener(
        onExitRequested: backend.requestAppExit,
      );
    }
  }

  @override
  void dispose() {
    _exitRequests?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backend = widget.backend;
    final error = widget.error;
    return MaterialApp(
      title: 'Séance Settings',
      theme: SeanceTheme.light(),
      darkTheme: SeanceTheme.dark(),
      themeMode: ThemeMode.system,
      home: backend == null
          ? Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Settings could not reach Séance:\n$error'),
                ),
              ),
            )
          : ValueListenableBuilder<SettingsWindowPage?>(
              valueListenable: backend.page,
              builder: (context, page, _) => page == null
                  // Hidden: no screen, so nothing typed into it outlives the
                  // window being closed.
                  ? const Scaffold()
                  : SettingsScreen(
                      key: ValueKey(page.generation),
                      backend: backend,
                      initialTab: page.tab,
                      tabRequests: backend.tabRequests,
                      presentation: SettingsPresentation.window,
                    ),
            ),
    );
  }
}
