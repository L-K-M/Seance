import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/remote_files_controller.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/adaptive_shell.dart';
import 'package:seance_app/ui/files_pane.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The narrow layout swaps the terminal in with a state flag, not a route.
/// Without a pop handler the Android system back reaches the root route,
/// bubbles to `SystemNavigator.pop`, and finishes the activity, which tears
/// down the engine and every live SSH session. These tests drive a real
/// system back through `handlePopRoute`: it answers true when the framework
/// consumed the back, false when it was handed to the platform.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    await services?.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
  });

  ServerConfig server(String id) => ServerConfig(
    id: id,
    label: id,
    host: '$id.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  /// A narrow shell over one saved server that already has a tab. The tab
  /// stays `connecting` (no SSH is attempted), so opening the server only
  /// focuses it.
  Future<TerminalSession> pumpNarrowShell(WidgetTester tester) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-back-');
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
    final session = TerminalSession(
      id: 'tab',
      serverId: 'box',
      config: server('box'),
      engine: XtermTerminalEngine(),
    );
    state!.tabs.add(session);

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      // As in the app: the scope sits above the navigator, so pushed routes
      // (Files) see it too.
      MaterialApp(
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: const AdaptiveShell(),
      ),
    );
    await tester.pump();
    return session;
  }

  Future<void> settle(WidgetTester tester) async {
    // A connecting terminal animates indefinitely, so pump fixed frames past
    // the screen switch and the page transition instead of settling.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openTerminal(WidgetTester tester) async {
    await tester.tap(find.text('box'));
    await settle(tester);
    expect(find.byType(TerminalPane), findsOneWidget);
    expect(find.byType(ServerListPane), findsNothing);
  }

  testWidgets('system back on the terminal returns to the server list and '
      'keeps the session', (tester) async {
    final session = await pumpNarrowShell(tester);
    await openTerminal(tester);

    final handled = await tester.binding.handlePopRoute();
    await settle(tester);

    expect(
      handled,
      isTrue,
      reason: 'the back must not reach SystemNavigator.pop',
    );
    expect(find.byType(ServerListPane), findsOneWidget);
    expect(find.byType(TerminalPane), findsNothing);
    expect(state!.tabs, [same(session)]);
    expect(state!.activeTabId, session.id);
  });

  testWidgets('system back on the server list is left to the platform', (
    tester,
  ) async {
    await pumpNarrowShell(tester);
    await openTerminal(tester);
    await tester.binding.handlePopRoute();
    await settle(tester);

    // Back at the root: the platform decides (background the app).
    expect(await tester.binding.handlePopRoute(), isFalse);
    expect(find.byType(ServerListPane), findsOneWidget);
  });

  /// Connects [session] to an in-memory SFTP tree rooted at `/home/test`, so
  /// the terminal's Files button pushes the Files screen.
  Future<RemoteFilesController> connectFiles(
    WidgetTester tester,
    TerminalSession session,
  ) async {
    final files = RemoteFilesController(
      () async => _TreeFileSystem(),
      shellDirectory: session.engine.workingDirectory,
      managedFileStore: services!.managedRemoteFiles,
      serverId: session.serverId,
      editSessionId: session.editSessionId,
    );
    // Initializing restores local copies from disk: real I/O.
    await tester.runAsync(files.initialize);
    session
      ..session = _OpenSshSession()
      ..files = files
      ..connecting = false;
    state!.notifyListeners();
    return files;
  }

  testWidgets(
    'system back in Files walks up the tree, then leaves the screen',
    (tester) async {
      final session = await pumpNarrowShell(tester);
      final files = await connectFiles(tester, session);
      await openTerminal(tester);
      await tester.tap(find.byTooltip('Remote files'));
      await settle(tester);
      expect(find.byType(FilesScreen), findsOneWidget);
      expect(files.currentPath, '/home/test');

      for (final parent in ['/home', '/']) {
        expect(await tester.binding.handlePopRoute(), isTrue);
        await settle(tester);
        expect(files.currentPath, parent);
        expect(find.byType(FilesScreen), findsOneWidget);
      }

      // At the root, back leaves Files for the terminal, not the list.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await settle(tester);
      expect(find.byType(FilesScreen), findsNothing);
      expect(find.byType(TerminalPane), findsOneWidget);
    },
  );

  testWidgets('the Files app bar arrow leaves the screen from any folder', (
    tester,
  ) async {
    final session = await pumpNarrowShell(tester);
    final files = await connectFiles(tester, session);
    await openTerminal(tester);
    await tester.tap(find.byTooltip('Remote files'));
    await settle(tester);

    await tester.tap(find.byType(BackButton));
    await settle(tester);

    expect(find.byType(FilesScreen), findsNothing);
    expect(find.byType(TerminalPane), findsOneWidget);
    expect(files.currentPath, '/home/test');
  });

  testWidgets('system back closes the terminal screen\'s drawer first', (
    tester,
  ) async {
    await pumpNarrowShell(tester);
    await openTerminal(tester);
    await tester.tap(find.byTooltip('Assistant & snippets'));
    await settle(tester);
    expect(find.byType(Drawer), findsOneWidget);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await settle(tester);

    expect(find.byType(Drawer), findsNothing);
    expect(find.byType(TerminalPane), findsOneWidget);
  });
}

/// Just enough of a live SSH session for the terminal to count as connected.
class _OpenSshSession implements SshSession {
  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `/home/test` with its ancestors, each holding the next directory down.
class _TreeFileSystem implements RemoteFileSystem {
  static const _children = {
    '/': [
      RemoteFileEntry(
        path: '/home',
        name: 'home',
        type: RemoteFileType.directory,
      ),
    ],
    '/home': [
      RemoteFileEntry(
        path: '/home/test',
        name: 'test',
        type: RemoteFileType.directory,
      ),
    ],
    '/home/test': [
      RemoteFileEntry(
        path: '/home/test/notes.txt',
        name: 'notes.txt',
        type: RemoteFileType.file,
        size: 5,
      ),
    ],
  };

  @override
  Future<String> canonicalize(String path) async =>
      path == '.' ? '/home/test' : path;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async =>
      _children[path] ?? const [];

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
