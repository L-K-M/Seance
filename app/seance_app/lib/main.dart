import 'package:flutter/material.dart';

import 'app_state.dart';
import 'services/app_services.dart';
import 'theme.dart';
import 'ui/adaptive_shell.dart';
import 'ui/host_key_dialog.dart';
import 'ui/keyboard_interactive_dialog.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SeanceApp());
}

/// Exposes [AppState] to the widget tree. The instance itself never changes;
/// widgets listen to it with [ListenableBuilder] for reactive rebuilds.
class AppScope extends InheritedWidget {
  final AppState state;
  const AppScope({super.key, required this.state, required super.child});

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in context');
    return scope!.state;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.state != state;
}

class SeanceApp extends StatelessWidget {
  const SeanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Séance',
      navigatorKey: navigatorKey,
      theme: SeanceTheme.light(),
      darkTheme: SeanceTheme.dark(),
      themeMode: ThemeMode.system,
      home: const _Bootstrap(),
    );
  }
}

/// Initializes services asynchronously, then installs the app shell and wires
/// the host-key / keyboard-interactive dialog hooks.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<AppState> _future = _init();

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
    return state;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppState>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Failed to start Séance:\n${snapshot.error}'),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final state = snapshot.data!;
        return AppScope(
          state: state,
          child: const AdaptiveShell(),
        );
      },
    );
  }
}
