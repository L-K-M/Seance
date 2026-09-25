import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/adaptive_shell.dart';
import 'package:seance_app/ui/app_menus.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Off Apple platforms the server filter's chord is Ctrl+Alt+F, which a
/// shell or an editor in it may bind, so the terminal keeps it: the chord
/// must never bubble past the terminal to the app-wide AppMenus binding,
/// which would pull focus out of the shell into the rail's filter.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    state = null;
    await services?.probe.dispose();
    services = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    directory = null;
  });

  ServerConfig server(String id) => ServerConfig(
    id: id,
    label: id,
    host: '$id.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  Future<void> settle(WidgetTester tester) async {
    // A connecting terminal animates indefinitely: pump fixed frames.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('Ctrl+Alt+F typed in the terminal stays in the terminal', (
    tester,
  ) async {
    // The terminal's own guard keys off the host (Platform.isMacOS), so
    // this runs off Apple only.
    if (Platform.isMacOS) return;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-chord-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _pathChannel,
            (call) async => directory!.path,
          );
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      await state!.saveServer(server('box'));
    });
    final engine = XtermTerminalEngine();
    state!
      ..tabs.add(
        TerminalSession(
            id: 'tab',
            serverId: 'box',
            config: server('box'),
            engine: engine,
          )
          ..session = _OpenSshSession(engine)
          ..connecting = false,
      )
      ..activeTabId = 'tab';

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.linux),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: const AppMenus(child: AdaptiveShell()),
      ),
    );
    await settle(tester);

    final terminalFocus = FocusManager.instance.primaryFocus;
    expect(find.byType(TerminalView), findsOneWidget);
    expect(
      terminalFocus?.context?.findAncestorWidgetOfExactType<AppMenus>(),
      isNotNull,
      reason: 'the active terminal holds focus inside the app',
    );
    expect(find.byKey(const ValueKey('servers.filter.field')), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    // Held down, the chord repeats; a repeat must not slip past either.
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);

    expect(find.byKey(const ValueKey('servers.filter.field')), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(terminalFocus));
  });
}

/// Just enough of a live SSH session for the terminal to count as connected.
class _OpenSshSession implements SshSession {
  _OpenSshSession(this.engine);

  @override
  final TerminalEngine engine;

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => engine.dispose();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
