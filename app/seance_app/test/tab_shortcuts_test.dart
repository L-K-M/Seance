import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
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
import 'package:seance_app/ui/keyboard_shortcuts_dialog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The tab shortcuts (`tabShortcuts` in app_menus.dart), driven through the
/// real shell: from the focused terminal, whose key handler has to see them
/// before xterm turns them into bytes for the shell, and from focus
/// elsewhere in the window, where AppMenus takes them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  /// Everything the terminals sent their shells, in order.
  final shellInput = <String>[];

  tearDown(() async {
    state?.dispose();
    state = null;
    await services?.probe.dispose();
    services = null;
    shellInput.clear();
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

  TerminalSession terminal(String id, String serverId) {
    final engine = XtermTerminalEngine();
    engine.userInput.listen((bytes) => shellInput.add(utf8.decode(bytes)));
    return TerminalSession(
        id: id,
        serverId: serverId,
        config: server(serverId),
        engine: engine,
      )
      ..session = _OpenSshSession(engine)
      ..connecting = false;
  }

  Future<void> settle(WidgetTester tester) async {
    // A live terminal animates indefinitely: pump fixed frames.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Three tabs on "box" (a, b, c) and one on "other", with [active] shown.
  Future<void> boot(
    WidgetTester tester,
    TargetPlatform platform, {
    List<PaneTab> Function()? tabs,
    String active = 'a',
    Future<void> Function()? beforePump,
  }) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-tabs-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _pathChannel,
            (call) async => directory!.path,
          );
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      await state!.saveServer(server('box'));
      await state!.saveServer(server('other'));
      await beforePump?.call();
    });
    state!
      ..tabs.addAll(
        tabs?.call() ??
            [
              terminal('a', 'box'),
              terminal('b', 'box'),
              terminal('c', 'box'),
              terminal('o', 'other'),
            ],
      )
      ..activeTabId = active;

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: platform),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: const AppMenus(child: AdaptiveShell()),
      ),
    );
    await settle(tester);
  }

  /// Press [key] with [modifiers] held, then let focus follow the tab.
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, [
    List<LogicalKeyboardKey> modifiers = const [],
  ]) async {
    for (final modifier in modifiers) {
      await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyEvent(key);
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
    await settle(tester);
  }

  const ctrl = LogicalKeyboardKey.controlLeft;
  const shift = LogicalKeyboardKey.shiftLeft;
  const alt = LogicalKeyboardKey.altLeft;
  const meta = LogicalKeyboardKey.metaLeft;

  String? activeTab() => state!.activeTabId;
  List<String> tabIds() => [for (final tab in state!.tabs) tab.id];

  /// The shell holds focus, so every press below starts in the terminal.
  void expectTerminalFocused() {
    final focus = FocusManager.instance.primaryFocus;
    expect(
      focus?.context?.findAncestorWidgetOfExactType<TerminalView>(),
      isNotNull,
      reason: 'the active terminal holds focus',
    );
  }

  group('off Apple platforms', () {
    testWidgets('Ctrl+Tab, Ctrl+Shift+Tab and Ctrl+Page Down/Up step through '
        "the server's tabs, wrapping, and send the shell nothing", (
      tester,
    ) async {
      await boot(tester, TargetPlatform.linux);
      expectTerminalFocused();

      await press(tester, LogicalKeyboardKey.tab, [ctrl]);
      expect(activeTab(), 'b');
      expectTerminalFocused();
      await press(tester, LogicalKeyboardKey.tab, [ctrl]);
      expect(activeTab(), 'c');
      // Wraps within the server's strip; "other" is never stepped into.
      await press(tester, LogicalKeyboardKey.tab, [ctrl]);
      expect(activeTab(), 'a');
      await press(tester, LogicalKeyboardKey.tab, [ctrl, shift]);
      expect(activeTab(), 'c');
      await press(tester, LogicalKeyboardKey.pageUp, [ctrl]);
      expect(activeTab(), 'b');
      await press(tester, LogicalKeyboardKey.pageDown, [ctrl]);
      expect(activeTab(), 'c');

      expect(shellInput, isEmpty);
    });

    testWidgets('Alt+digit jumps to that tab and Alt+9 to the last; the right '
        'Alt (AltGr) and the keypad stay out of it', (tester) async {
      await boot(tester, TargetPlatform.linux);

      await press(tester, LogicalKeyboardKey.digit2, [alt]);
      expect(activeTab(), 'b');
      await press(tester, LogicalKeyboardKey.digit9, [alt]);
      expect(activeTab(), 'c');
      await press(tester, LogicalKeyboardKey.digit1, [alt]);
      expect(activeTab(), 'a');
      // Past the last tab: nothing, and the shell does not get it either.
      await press(tester, LogicalKeyboardKey.digit5, [alt]);
      expect(activeTab(), 'a');
      expect(shellInput, isEmpty);

      // AltGr+2 types "@" on many layouts; the keypad digits with Alt are
      // Windows' character codes.
      await press(tester, LogicalKeyboardKey.digit2, [
        LogicalKeyboardKey.altRight,
      ]);
      expect(activeTab(), 'a');
      await press(tester, LogicalKeyboardKey.numpad2, [alt]);
      expect(activeTab(), 'a');
    });

    testWidgets('Ctrl+Shift+W closes the tab; plain Ctrl+W, Ctrl+C and '
        'Ctrl+A still reach the shell', (tester) async {
      await boot(tester, TargetPlatform.linux);

      await press(tester, LogicalKeyboardKey.keyW, [ctrl]);
      await press(tester, LogicalKeyboardKey.keyC, [ctrl]);
      await press(tester, LogicalKeyboardKey.keyA, [ctrl]);
      expect(shellInput.join(), '\x17\x03\x01');
      expect(tabIds(), ['a', 'b', 'c', 'o']);
      expect(activeTab(), 'a');
      shellInput.clear();

      await press(tester, LogicalKeyboardKey.keyW, [ctrl, shift]);
      expect(tabIds(), ['b', 'c', 'o']);
      expect(activeTab(), 'b', reason: 'the next tab of the same server');
      expectTerminalFocused();
      expect(shellInput, isEmpty);
    });

    testWidgets('a held Ctrl+Shift+W closes one tab, and its repeats do not '
        'reach the next shell as ^W', (tester) async {
      await boot(tester, TargetPlatform.linux);

      await tester.sendKeyDownEvent(ctrl);
      await tester.sendKeyDownEvent(shift);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await settle(tester);
      expect(tabIds(), ['b', 'c', 'o']);
      // The repeats land in the terminal that took over focus.
      expectTerminalFocused();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyW);
      await settle(tester);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(shift);
      await tester.sendKeyUpEvent(ctrl);
      await settle(tester);

      expect(tabIds(), ['b', 'c', 'o']);
      expect(activeTab(), 'b');
      expect(shellInput, isEmpty);
    });

    testWidgets('a dirty editor asks before Ctrl+Shift+W closes it, with '
        'focus in the editor rather than a terminal', (tester) async {
      final session = terminal('a', 'box');
      final editor = EditorTab(
        id: 'e',
        serverId: 'box',
        config: server('box'),
        remotePath: '/etc/motd',
        localPath: 'motd',
        ownerEditSessionId: session.editSessionId,
      );
      await boot(
        tester,
        TargetPlatform.linux,
        tabs: () => [session, editor],
        active: 'e',
        beforePump: () async {
          final file = services!.managedRemoteFiles.checkoutFile('motd');
          await file.parent.create(recursive: true);
          await file.writeAsString('hello\n');
        },
      );
      // The editor reads its checkout on the real event loop: give that
      // loop turns, and the fake one frames, until the text is in.
      final field = find.descendant(
        of: find.byKey(editor.editorKey),
        matching: find.byType(TextField),
      );
      for (var i = 0; i < 50 && field.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }

      await tester.enterText(field.first, 'changed\n');
      await settle(tester);
      expect(editor.dirty.value, isTrue);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<TerminalView>(),
        isNull,
        reason: 'the editor, not a terminal, holds focus',
      );

      await press(tester, LogicalKeyboardKey.keyW, [ctrl, shift]);
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await settle(tester);
      expect(tabIds(), ['a', 'e']);
      expect(activeTab(), 'e');

      await press(tester, LogicalKeyboardKey.keyW, [ctrl, shift]);
      await tester.tap(find.text('Discard'));
      await settle(tester);
      expect(tabIds(), ['a']);
      expect(activeTab(), 'a');
    });

    testWidgets("the terminal's menu lists this platform's shortcuts", (
      tester,
    ) async {
      await boot(tester, TargetPlatform.linux);
      await tester.tap(
        find.byType(TerminalView).first,
        buttons: kSecondaryButton,
      );
      await settle(tester);
      await tester.tap(find.text('Keyboard shortcuts'));
      await settle(tester);

      expect(find.text('Close tab'), findsOneWidget);
      expect(find.text('Ctrl+Shift+W'), findsOneWidget);
      expect(find.text('Ctrl+Tab or Ctrl+Page Down'), findsOneWidget);
      expect(find.text('Alt+1 to Alt+8'), findsOneWidget);
    });
  });

  testWidgets('on Apple platforms: ⌘W, ⇧⌘] and ⇧⌘[, Ctrl+Tab and ⌘1 to ⌘9 '
      'from the terminal; Option+digit is left to type', (tester) async {
    await boot(tester, TargetPlatform.macOS);

    await press(tester, LogicalKeyboardKey.bracketRight, [meta, shift]);
    expect(activeTab(), 'b');
    await press(tester, LogicalKeyboardKey.bracketLeft, [meta, shift]);
    expect(activeTab(), 'a');
    await press(tester, LogicalKeyboardKey.tab, [ctrl]);
    expect(activeTab(), 'b');
    await press(tester, LogicalKeyboardKey.digit9, [meta]);
    expect(activeTab(), 'c');
    await press(tester, LogicalKeyboardKey.digit1, [meta]);
    expect(activeTab(), 'a');
    await press(tester, LogicalKeyboardKey.digit2, [alt]);
    expect(activeTab(), 'a');
    shellInput.clear();

    await press(tester, LogicalKeyboardKey.keyW, [meta]);
    expect(tabIds(), ['b', 'c', 'o']);
    expect(activeTab(), 'b');
    expect(shellInput, isEmpty);
  });

  group('the shortcut list', () {
    Map<String, String> rows(TargetPlatform platform) => {
      for (final section in keyboardShortcutSections(platform))
        for (final row in section.rows) row.action: row.keys,
    };

    test('writes Apple chords as glyphs', () {
      expect(rows(TargetPlatform.macOS), {
        'New tab': '⌘T',
        'Close tab': '⌘W',
        'Next tab': '⇧⌘] or ⌃⇥',
        'Previous tab': '⇧⌘[ or ⌃⇧⇥',
        'Tab 1 to 8': '⌘1 to ⌘8',
        'Last tab': '⌘9',
        'Copy': '⌘C',
        'Paste': '⌘V',
        'Select all': '⌘A',
        'Zoom in': '⌘+',
        'Zoom out': '⌘-',
        'Actual size': '⌘0',
        'Generate command': '⌘K',
        'Filter servers': '⌥⌘F',
        'Settings': '⌘,',
      });
    });

    test('spells chords out elsewhere', () {
      expect(rows(TargetPlatform.windows), {
        'New tab': 'Ctrl+Shift+T',
        'Close tab': 'Ctrl+Shift+W',
        'Next tab': 'Ctrl+Tab or Ctrl+Page Down',
        'Previous tab': 'Ctrl+Shift+Tab or Ctrl+Page Up',
        'Tab 1 to 8': 'Alt+1 to Alt+8',
        'Last tab': 'Alt+9',
        'Copy': 'Ctrl+Shift+C',
        'Paste': 'Ctrl+Shift+V',
        'Select all': 'Ctrl+Shift+A',
        'Zoom in': 'Ctrl+Shift+=',
        'Zoom out': 'Ctrl+Shift+-',
        'Actual size': 'Ctrl+Shift+0',
        'Generate command': 'Ctrl+Shift+K',
        'Filter servers': 'Ctrl+Alt+F',
        'Settings': 'Ctrl+,',
      });
    });
  });

  test('every tab chord is bound once per platform', () {
    for (final platform in TargetPlatform.values) {
      final chords = [
        for (final shortcut in tabShortcuts(platform))
          shortcut.chord.debugDescribeKeys(),
      ];
      expect(chords.toSet(), hasLength(chords.length), reason: '$platform');
    }
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
