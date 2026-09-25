import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/family_hues.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/remote_files_controller.dart';
import 'package:seance_app/services/remote_git_controller.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/sidebar_panel.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Real-font captures of the side panel for the colour vocabulary the
/// sibling apps share (Poltergeist's D34): the tabs in their hues with
/// the underline in the open one's, the Files listing's kind glyphs, and
/// the Git tab's glyphs and verbs, in both themes. The scenes are pumped
/// and checked on every run; PNGs are written only with SEANCE_CAPTURE=1,
/// to SEANCE_CAPTURE_DIR (default `build/colour-captures`), each name
/// prefixed with SEANCE_CAPTURE_PREFIX so a run on the old code and one
/// on the new make a before/after pair.
final _captureOn = Platform.environment['SEANCE_CAPTURE'] == '1';
final _captureDir =
    Platform.environment['SEANCE_CAPTURE_DIR'] ?? 'build/colour-captures';
final _prefix = Platform.environment['SEANCE_CAPTURE_PREFIX'] ?? '';

const _fontFamily = 'Capture Sans';
const _home = '/home/ada';
final _modified = DateTime(2026, 9, 21, 14, 5);

/// NUL, spelled without a Dart escape so the intent survives formatters.
final _nul = String.fromCharCode(0);

Future<void> _loadRealFonts() async {
  Future<ByteData> bytes(File file) async {
    final data = file.readAsBytesSync();
    return ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
  }

  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
  final icons = File(
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(bytes(icons))).load();
  }
  for (final dir in [
    Platform.environment['SEANCE_CAPTURE_FONT_DIR'],
    '/usr/share/fonts/truetype/dejavu',
    '${Platform.environment['HOME']}/.local/share/fonts',
  ]) {
    if (dir == null) continue;
    final regular = File('$dir/DejaVuSans.ttf');
    if (!regular.existsSync()) continue;
    final loader = FontLoader(_fontFamily)..addFont(bytes(regular));
    final bold = File('$dir/DejaVuSans-Bold.ttf');
    if (bold.existsSync()) loader.addFont(bytes(bold));
    await loader.load();
    // Paths and git's status letters ask for 'monospace'.
    final mono = File('$dir/DejaVuSansMono.ttf');
    if (mono.existsSync()) {
      final monoLoader = FontLoader('monospace')..addFont(bytes(mono));
      final monoBold = File('$dir/DejaVuSansMono-Bold.ttf');
      if (monoBold.existsSync()) monoLoader.addFont(bytes(monoBold));
      await monoLoader.load();
    }
    return;
  }
}

ThemeData _theme(Brightness brightness) {
  final base = brightness == Brightness.dark
      ? SeanceTheme.dark(platform: TargetPlatform.linux)
      : SeanceTheme.light(platform: TargetPlatform.linux);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _fontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _fontFamily),
  );
}

RemoteFileEntry _entry(String name, {RemoteFileType? type, int? size}) =>
    RemoteFileEntry(
      path: '$_home/$name',
      name: name,
      type: type ?? RemoteFileType.file,
      size: size,
      modifiedAt: _modified,
    );

/// A home folder with one of every kind the listing tints.
class _HomeFileSystem implements RemoteFileSystem {
  static final _listing = [
    for (final name in ['docker', 'projects', 'www'])
      _entry(name, type: RemoteFileType.directory),
    _entry('backup.tar.gz', size: 734003200),
    _entry('beach.jpg', size: 3355443),
    _entry('deploy.sh', size: 1843),
    _entry('docker-compose.yml', size: 2211),
    _entry('invoice.pdf', size: 88210),
    _entry('keynote.mov', size: 214958080),
    _entry('notes.md', size: 4410),
    _entry('podcast.mp3', size: 48234496),
    _entry('vault.bin', size: 65536),
    _entry('latest', type: RemoteFileType.symbolicLink),
  ];

  @override
  Future<String> canonicalize(String path) async => path == '.' ? _home : path;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async =>
      path == _home ? _listing : const [];

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A repository with a staged, a modified, a deleted and an untracked
/// file, answered to every probe the controller runs.
Future<RemoteCommandResult> _repo(String command, {Duration? timeout}) async =>
    RemoteCommandResult(
      stdout:
          '/srv/site\n'
          '# branch.oid deadbeef\n'
          '# branch.head main\n'
          '1 A. N... 000000 100644 100644 h h src/colours.dart$_nul'
          '1 .M N... 100644 100644 100644 h h README.md$_nul'
          '1 .D N... 100644 100644 000000 h h old/logo.svg$_nul'
          '? notes/todo.md$_nul'
          '$_nul'
          'abc1234\tGive the glyphs their colour\n'
          'def5678\tSplit the kinds\n',
      exitCode: 0,
    );

/// A session the app believes is open, without a network.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;
  final notifiers = <ValueNotifier<String?>>[];

  setUpAll(_loadRealFonts);

  tearDown(() async {
    state?.dispose();
    await services?.probe.dispose();
    for (final notifier in notifiers) {
      notifier.dispose();
    }
    notifiers.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    state = null;
    services = null;
    directory = null;
  });

  /// One connected session with a Files tree and a Git repository.
  Future<void> boot(WidgetTester tester) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-hues-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathChannel, (_) async => directory!.path);
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      await state!.saveServer(
        ServerConfig(
          id: 'web',
          label: 'web',
          host: 'web.example.com',
          username: 'ada',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
    });
    final config = state!.servers.single;
    final session = TerminalSession(
      id: 't1',
      serverId: config.id,
      config: config,
      engine: XtermTerminalEngine(),
    );
    final files = RemoteFilesController(
      () async => _HomeFileSystem(),
      shellDirectory: session.engine.workingDirectory,
      managedFileStore: services!.managedRemoteFiles,
      serverId: session.serverId,
      editSessionId: session.editSessionId,
    );
    final shellDirectory = ValueNotifier<String?>('/srv/site');
    final terminalTitle = ValueNotifier<String?>(null);
    final activeCommand = ValueNotifier<String?>(null);
    notifiers.addAll([shellDirectory, terminalTitle, activeCommand]);
    final git = RemoteGitController(
      _repo,
      shellDirectory: shellDirectory,
      terminalTitle: terminalTitle,
      activeCommand: activeCommand,
    );
    await tester.runAsync(() async {
      await files.initialize();
      await git.initialize();
    });
    session
      ..session = _OpenSshSession(session.engine)
      ..files = files
      ..git = git
      ..connecting = false;
    state!.tabs.add(session);
    state!.activeTabId = session.id;
  }

  Future<RenderRepaintBoundary> pumpPanel(
    WidgetTester tester,
    Brightness brightness,
  ) async {
    tester.view.physicalSize = const Size(380, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(brightness),
          home: AppScope(
            state: state!,
            child: const Scaffold(body: SidebarPanel()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    return tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    // The tab's pane mounts on its first visit and loads through real
    // futures (the listing, the git probe).
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> capture(
    WidgetTester tester,
    RenderRepaintBoundary boundary,
    String name,
  ) async {
    if (!_captureOn) return;
    final png = (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }))!;
    // Sync I/O: awaiting real file futures can strand the fake-async zone.
    Directory(_captureDir).createSync(recursive: true);
    File('$_captureDir/$_prefix$name.png').writeAsBytesSync(png);
  }

  for (final brightness in Brightness.values) {
    final tone = brightness.name;

    testWidgets('captures the Files tab ($tone)', (tester) async {
      await boot(tester);
      final boundary = await pumpPanel(tester, brightness);
      await openTab(tester, 'Files');
      expect(find.text('invoice.pdf'), findsOneWidget);
      await capture(tester, boundary, 'panel-files-$tone');
    });

    testWidgets('captures the Git tab ($tone)', (tester) async {
      await boot(tester);
      final boundary = await pumpPanel(tester, brightness);
      await openTab(tester, 'Git');
      expect(find.text('README.md'), findsOneWidget);
      await capture(tester, boundary, 'panel-git-$tone');
    });
  }

  testWidgets('each tab wears its hue; the underline takes the open one\'s', (
    tester,
  ) async {
    await boot(tester);
    await pumpPanel(tester, Brightness.dark);
    const palette = FamilyPalette.dark;
    Color? glyph(String label) => tester
        .widget<Icon>(
          find.descendant(
            of: find.ancestor(of: find.text(label), matching: find.byType(Tab)),
            matching: find.byType(Icon),
          ),
        )
        .color;
    expect(glyph('Assistant'), palette.glyph(FamilyHue.purple));
    expect(glyph('Snippets'), palette.glyph(FamilyHue.teal));
    expect(glyph('Files'), palette.glyph(FamilyHue.blue));
    expect(glyph('Git'), palette.glyph(FamilyHue.orange));

    Color? underline() => tester.widget<TabBar>(find.byType(TabBar)).indicatorColor;
    expect(underline(), palette.glyph(FamilyHue.teal)); // Snippets opens
    await openTab(tester, 'Git');
    await tester.pumpAndSettle();
    expect(underline(), palette.glyph(FamilyHue.orange));
  });
}
