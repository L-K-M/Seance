import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
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
import 'package:seance_app/ui/terminal_find_bar.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The terminal's find bar, driven through the real shell: the shortcut,
/// the context menu, stepping, the counter and handing focus back.
///
/// The terminal's shortcuts key off the host (Platform.isMacOS), so these
/// run the Ctrl+Shift+F path and skip on a Mac host.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final apple = Platform.isMacOS;
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
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Pumps the shell with one connected terminal and returns its engine.
  Future<XtermTerminalEngine> pumpTerminal(WidgetTester tester) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-find-');
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
    engine.terminal.write('needle one\r\nhay\r\nNeedle two\r\nhay\r\n');
    await settle(tester);
    return engine;
  }

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
    bool shift = false,
  }) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
  }

  TerminalController terminalController() => state!.activeSession!.controller!;

  Finder queryField() => find.descendant(
    of: find.byType(TerminalFindBar),
    matching: find.byType(EditableText),
  );

  testWidgets('Ctrl+Shift+F finds, steps with wrap-around, and Escape '
      'returns to the shell', (tester) async {
    if (apple) return;
    await pumpTerminal(tester);
    final terminalFocus = FocusManager.instance.primaryFocus;
    expect(find.byType(TerminalFindBar), findsNothing);

    await chord(tester, LogicalKeyboardKey.keyF, control: true, shift: true);
    expect(find.byType(TerminalFindBar), findsOneWidget);
    expect(
      tester.widget<EditableText>(queryField()).focusNode.hasFocus,
      isTrue,
      reason: 'the query field takes focus when the bar opens',
    );

    await tester.enterText(queryField(), 'needle');
    await settle(tester);
    // Case-insensitive by default; starts on the newest hit in view.
    expect(find.text('2 of 2'), findsOneWidget);
    expect(terminalController().highlights, hasLength(2));
    expect(terminalController().selection, isNull);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text('1 of 2'), findsOneWidget, reason: 'Enter wraps');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
    expect(find.text('2 of 2'), findsOneWidget, reason: 'Shift+Enter wraps');
    await chord(tester, LogicalKeyboardKey.f3);
    expect(find.text('1 of 2'), findsOneWidget);
    await chord(tester, LogicalKeyboardKey.f3, shift: true);
    expect(find.text('2 of 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Match case'));
    await settle(tester);
    expect(find.text('1 of 1'), findsOneWidget);
    await tester.enterText(queryField(), 'nothing like it');
    await settle(tester);
    expect(find.text('No matches'), findsOneWidget);
    expect(terminalController().highlights, isEmpty);
    await tester.enterText(queryField(), 'needle');
    await settle(tester);

    await chord(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TerminalFindBar), findsNothing);
    expect(terminalController().highlights, isEmpty);
    expect(FocusManager.instance.primaryFocus, same(terminalFocus));
  });

  testWidgets('plain Ctrl+F still reaches the shell', (tester) async {
    if (apple) return;
    final engine = await pumpTerminal(tester);
    final sent = <int>[];
    final subscription = engine.userInput.listen(sent.addAll);
    addTearDown(subscription.cancel);

    await chord(tester, LogicalKeyboardKey.keyF, control: true);

    expect(find.byType(TerminalFindBar), findsNothing);
    expect(utf8.decode(sent), '\x06', reason: "readline's forward-char");
  });

  testWidgets('the context menu opens it, and it reopens with the last '
      'query', (tester) async {
    await pumpTerminal(tester);
    await tester.tap(find.byType(TerminalView), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Find…'));
    await settle(tester);
    expect(find.byType(TerminalFindBar), findsOneWidget);

    await tester.enterText(queryField(), 'hay');
    await settle(tester);
    await tester.tap(find.byTooltip('Close search'));
    await settle(tester);
    expect(find.byType(TerminalFindBar), findsNothing);

    await tester.tap(find.byType(TerminalView), buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(find.text('Find…'));
    await settle(tester);
    expect(tester.widget<EditableText>(queryField()).controller.text, 'hay');
    expect(find.text('2 of 2'), findsOneWidget);
  });

  testWidgets('opening it does not resize the terminal', (tester) async {
    if (apple) return;
    final engine = await pumpTerminal(tester);
    final before = (engine.terminal.viewWidth, engine.terminal.viewHeight);
    await chord(tester, LogicalKeyboardKey.keyF, control: true, shift: true);
    expect(find.byType(TerminalFindBar), findsOneWidget);
    expect((engine.terminal.viewWidth, engine.terminal.viewHeight), before);
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
