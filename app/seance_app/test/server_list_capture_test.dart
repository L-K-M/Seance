import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/server_list_density.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_app/ui/sidebar/sidebar_kit.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Real-font captures of the server list for visual review, in both
/// postures, both densities and both brightnesses: the desktop rail
/// (Poltergeist's plan, 10 §5), a tablet's touch rail, and the phone home
/// (§9). The widget-test default font draws
/// boxes, so a real face is loaded when the host has one.
///
/// Nothing is written unless SEANCE_CAPTURE=1; the PNGs then land in
/// SEANCE_CAPTURE_DIR (default `build/sidebar-captures`). The scenes are
/// still pumped and sanity-checked on every run, so a capture that would
/// throw fails the suite rather than the next person who looks.
final _captureOn = Platform.environment['SEANCE_CAPTURE'] == '1';
final _captureDir =
    Platform.environment['SEANCE_CAPTURE_DIR'] ?? 'build/sidebar-captures';

const _fontFamily = 'Capture Sans';

Future<void> _loadRealFonts() async {
  Future<ByteData> bytes(File file) async {
    final data = file.readAsBytesSync();
    return ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
  }

  // Server glyphs and the chrome's icons are MaterialIcons codepoints; the
  // font ships inside the Flutter SDK. `flutter test` exports FLUTTER_ROOT;
  // run bare, the tester sits at bin/cache/artifacts/engine/<host>/ below
  // the SDK root, six levels up from the executable.
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ??
      File(
        Platform.resolvedExecutable,
      ).parent.parent.parent.parent.parent.parent.path;
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
    return;
  }
}

ThemeData _theme(Brightness brightness, TargetPlatform platform) {
  final base = brightness == Brightness.dark
      ? SeanceTheme.dark(platform: platform)
      : SeanceTheme.light(platform: platform);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _fontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _fontFamily),
  );
}

ServerConfig _server(
  String id, {
  String? group,
  ServerColor? color,
  ServerIcon? icon,
  bool excluded = false,
  String user = 'deploy',
}) => ServerConfig(
  id: id,
  label: id,
  host: '$id.example.com',
  username: user,
  group: group,
  color: color,
  icon: icon,
  excludeFromSync: excluded,
  createdAt: 1,
  updatedAt: 1,
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

  setUpAll(() async {
    await _loadRealFonts();
  });

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
    state = null;
    services = null;
    directory = null;
  });

  /// A list with every state a row can show: pinned, grouped, a collapsed
  /// group, each dot, `×2`, an excluded server, and the selection pill.
  Future<void> boot(WidgetTester tester, {bool empty = false}) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-capture-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathChannel, (_) async => directory!.path);
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      if (empty) {
        state!.updateInfo = UpdateInfo(
          latestVersion: '1.4.0',
          releasesUrl: Uri.parse('https://example.com/releases'),
        );
        return;
      }
      for (final config in [
        _server('web-01', color: ServerColor.violet, icon: ServerIcon.web),
        _server(
          'db-primary',
          color: ServerColor.teal,
          icon: ServerIcon.database,
        ),
        _server('build-runner'),
        _server('nas', icon: ServerIcon.files, color: ServerColor.amber),
        _server('pi-hole', icon: ServerIcon.router),
        _server('laptop', excluded: true, icon: ServerIcon.laptop),
        _server(
          'prod-api-eu-west-1.internal.example',
          group: 'Production',
          color: ServerColor.red,
          icon: ServerIcon.cloud,
        ),
        _server('prod-worker', group: 'Production', color: ServerColor.red),
        _server('prod-cache', group: 'Production'),
        _server('stage-api', group: 'Staging', color: ServerColor.blue),
        _server('stage-db', group: 'Staging', color: ServerColor.blue),
      ]) {
        await state!.saveServer(config);
      }
      await state!.toggleServerPin('web-01');
      await state!.toggleServerPin('db-primary');
      await state!.toggleServerGroup(serverGroupKey('Staging'));
      services!.settings.syncBaseUrl = 'https://sync.example.com';
    });
    if (empty) return;
    ServerConfig config(String id) =>
        state!.servers.firstWhere((s) => s.id == id);
    TerminalSession tab(String id, String serverId) => TerminalSession(
      id: id,
      serverId: serverId,
      config: config(serverId),
      engine: XtermTerminalEngine(),
    );
    final connected = tab('t1', 'web-01');
    connected
      ..session = _OpenSshSession(connected.engine)
      ..connecting = false;
    final second = tab('t2', 'web-01');
    second
      ..session = _OpenSshSession(second.engine)
      ..connecting = false;
    final failed = tab('t3', 'build-runner')
      ..connecting = false
      ..error = 'Connection refused';
    final worker = tab('t4', 'prod-worker');
    worker
      ..session = _OpenSshSession(worker.engine)
      ..connecting = false;
    state!.tabs.addAll([
      connected,
      second,
      tab('t5', 'db-primary'),
      failed,
      worker,
    ]);
    state!
      ..activeTabId = 't1'
      ..statuses = {
        'nas': ProbeStatus.online,
        'pi-hole': ProbeStatus.offline,
        'prod-cache': ProbeStatus.online,
        'stage-api': ProbeStatus.online,
      }
      ..lastSyncAt = DateTime.now().subtract(const Duration(minutes: 2));
  }

  Future<RenderRepaintBoundary> pumpPane(
    WidgetTester tester, {
    required Brightness brightness,
    required ServerListPosture posture,
    required Size size,
    bool? phone,
  }) async {
    phone ??= posture == ServerListPosture.home;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      // The boundary wraps the app, not the pane: a context menu renders on
      // the Navigator's overlay, a sibling of `home`.
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(
            brightness,
            phone ? TargetPlatform.android : TargetPlatform.linux,
          ),
          home: AppScope(
            state: state!,
            child: ServerListPane(posture: posture, onOpen: (_) {}),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    return tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
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
    File('$_captureDir/$name.png').writeAsBytesSync(png);
  }

  Future<void> useDensity(WidgetTester tester, ServerListDensity density) =>
      tester.runAsync(() => state!.setServerListDensity(density));

  for (final brightness in Brightness.values) {
    final tone = brightness.name;

    testWidgets('captures the desktop rail ($tone)', (tester) async {
      await boot(tester);
      // Comfortable, the default: two-line rows under 32 px badges.
      final boundary = await pumpPane(
        tester,
        brightness: brightness,
        posture: ServerListPosture.rail,
        size: const Size(280, 720),
      );
      expect(find.text('PINNED'), findsOneWidget);
      expect(find.text('Production'), findsOneWidget);
      expect(find.text('×2'), findsOneWidget);
      expect(find.text('deploy@web-01.example.com'), findsOneWidget);
      expect(
        find.text('Connection failed · deploy@build-runner.example.com'),
        findsOneWidget,
      );
      await capture(tester, boundary, 'rail-comfortable-$tone');

      // Hover a connected row: the disconnect glyph replaces `×2`.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('prod-worker')));
      await tester.pump(const Duration(milliseconds: 300));
      await capture(tester, boundary, 'rail-hover-$tone');

      await tester.tap(
        find.text('prod-worker'),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Duplicate'), findsOneWidget);
      await capture(tester, boundary, 'rail-menu-$tone');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.byKey(const ValueKey('servers.filter.field')),
        'prod',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('3 of 11 · ↵ opens the first'), findsOneWidget);
      await capture(tester, boundary, 'rail-filter-$tone');

      await tester.enterText(
        find.byKey(const ValueKey('servers.filter.field')),
        '',
      );
      await useDensity(tester, ServerListDensity.compact);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('deploy@web-01.example.com'), findsNothing);
      await capture(tester, boundary, 'rail-compact-$tone');

      // Fold the group holding a live session: its row keeps the dot.
      await useDensity(tester, ServerListDensity.comfortable);
      await tester.tap(find.text('Production'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('prod-worker'), findsNothing);
      expect(
        tester
            .widgetList<SidebarSectionHeader>(find.byType(SidebarSectionHeader))
            .where((header) => header.status != null)
            .map((header) => header.title),
        ['Production'],
      );
      await capture(tester, boundary, 'rail-folded-$tone');
    });

    for (final density in ServerListDensity.values) {
      testWidgets('captures the rail at its narrowest (${density.name}, '
          '$tone)', (tester) async {
        // The shell's minimum list width: the bottom bar's chip gives way
        // before anything overflows.
        await boot(tester);
        await useDensity(tester, density);
        final boundary = await pumpPane(
          tester,
          brightness: brightness,
          posture: ServerListPosture.rail,
          size: const Size(200, 620),
        );
        expect(find.byType(SidebarDensitySwitch), findsOneWidget);
        await capture(tester, boundary, 'rail-narrow-${density.name}-$tone');
      });

      testWidgets('captures a tablet rail (${density.name}, $tone)', (
        tester,
      ) async {
        // A touch window at the wide breakpoint gets the rail, drawn at
        // touch sizes, with the "⋮" in view at either density.
        await boot(tester);
        await useDensity(tester, density);
        final boundary = await pumpPane(
          tester,
          brightness: brightness,
          posture: ServerListPosture.rail,
          size: const Size(320, 900),
          phone: true,
        );
        expect(find.byTooltip('More actions'), findsWidgets);
        await capture(tester, boundary, 'tablet-${density.name}-$tone');
      });

      testWidgets('captures the phone home (${density.name}, $tone)', (
        tester,
      ) async {
        await boot(tester);
        await useDensity(tester, density);
        final boundary = await pumpPane(
          tester,
          brightness: brightness,
          posture: ServerListPosture.home,
          size: const Size(390, 844),
        );
        expect(find.byType(FloatingActionButton), findsOneWidget);
        expect(find.byType(SidebarDensitySwitch), findsOneWidget);
        await capture(tester, boundary, 'home-phone-${density.name}-$tone');
      });

      testWidgets('captures a narrow desktop window (${density.name}, '
          '$tone)', (tester) async {
        // Below the wide breakpoint a desktop window gets the home screen
        // too, at the desktop's row extents.
        await boot(tester);
        await useDensity(tester, density);
        final boundary = await pumpPane(
          tester,
          brightness: brightness,
          posture: ServerListPosture.home,
          size: const Size(520, 720),
          phone: false,
        );
        expect(find.byType(FloatingActionButton), findsOneWidget);
        await capture(tester, boundary, 'home-desktop-${density.name}-$tone');
      });
    }

    testWidgets('captures the empty rail ($tone)', (tester) async {
      await boot(tester, empty: true);
      final boundary = await pumpPane(
        tester,
        brightness: brightness,
        posture: ServerListPosture.rail,
        size: const Size(280, 620),
      );
      expect(find.text('No servers yet'), findsOneWidget);
      await capture(tester, boundary, 'rail-empty-$tone');
    });
  }
}
