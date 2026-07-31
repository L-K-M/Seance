import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/local_shell_service.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/server_appearance.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_core/seance_core.dart';

/// The app-side half of the local shell: which platforms offer it, what the
/// session model says about a tab with no server, and the pinned list row.
///
/// The pty itself is never started here — `flutter test` runs on the host Dart
/// VM, where the plugin's native library does not exist. That is exactly why
/// [LocalShellService.launch] is injectable; `LocalShellSession`'s wiring is
/// covered against a fake in `packages/seance_core/test/local_shell_test.dart`.
void main() {
  LocalShellService service({
    required LocalShellPlatform platform,
    Map<String, String> environment = const {},
  }) => LocalShellService(
    platform: platform,
    environment: environment,
    launch: (_, __) async => throw StateError('not started in tests'),
  );

  group('availability', () {
    test('offered on Linux and macOS, refused with a reason elsewhere', () {
      for (final platform in LocalShellPlatform.values) {
        final local = service(platform: platform);
        if (platform == LocalShellPlatform.linux ||
            platform == LocalShellPlatform.macos) {
          expect(local.supported, isTrue, reason: '$platform');
          expect(local.unavailableReason, isEmpty, reason: '$platform');
        } else {
          expect(local.supported, isFalse, reason: '$platform');
          expect(local.unavailableReason, isNotEmpty, reason: '$platform');
        }
      }
    });

    test('the setting alone never makes an unsupported platform offer it', () {
      // A settings file is device-local but portable: enabling this on a
      // laptop must not put a dead row in a phone's list.
      expect(
        service(platform: LocalShellPlatform.ios)
            .availableWhen(enabledInSettings: true),
        isFalse,
      );
      expect(
        service(platform: LocalShellPlatform.linux)
            .availableWhen(enabledInSettings: true),
        isTrue,
      );
      expect(
        service(platform: LocalShellPlatform.linux)
            .availableWhen(enabledInSettings: false),
        isFalse,
      );
    });

    test('the host platform maps onto the core enum', () {
      // Registered before the loop: an expect that throws must still put the
      // override back, or every widget test after this one runs on the wrong
      // platform and fails for reasons that have nothing to do with them.
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final entry in const {
        TargetPlatform.linux: LocalShellPlatform.linux,
        TargetPlatform.macOS: LocalShellPlatform.macos,
        TargetPlatform.windows: LocalShellPlatform.windows,
        TargetPlatform.android: LocalShellPlatform.android,
        TargetPlatform.iOS: LocalShellPlatform.ios,
        TargetPlatform.fuchsia: LocalShellPlatform.unknown,
      }.entries) {
        debugDefaultTargetPlatformOverride = entry.key;
        expect(LocalShellService.hostPlatform(), entry.value);
      }
    });
  });

  group('the macOS sandbox', () {
    test('is detected from the container variable, and only on macOS', () {
      const sandboxEnv = {'APP_SANDBOX_CONTAINER_ID': 'com.lkm.seance-app'};
      expect(
        service(platform: LocalShellPlatform.macos, environment: sandboxEnv)
            .sandboxed,
        isTrue,
      );
      expect(
        service(platform: LocalShellPlatform.macos).sandboxed,
        isFalse,
      );
      // The variable can only mean something on macOS; a stray one elsewhere
      // must not produce a warning about a sandbox that isn't there.
      expect(
        service(platform: LocalShellPlatform.linux, environment: sandboxEnv)
            .sandboxed,
        isFalse,
      );
    });

    test('a sandboxed session is warned in its own scrollback', () {
      final notice = service(
        platform: LocalShellPlatform.macos,
        environment: const {'APP_SANDBOX_CONTAINER_ID': 'x'},
      ).sandboxNotice;
      expect(notice, isNotNull);
      expect(notice, contains(r'$HOME'));
      // A pty needs the carriage return; a bare \n would leave the shell's
      // first prompt indented under the notice.
      expect(notice, endsWith('\r\n'));
      expect(service(platform: LocalShellPlatform.linux).sandboxNotice, isNull);
    });
  });

  group('the shell being run', () {
    test(r'is named from $SHELL, for the tab and the row', () {
      expect(
        service(
          platform: LocalShellPlatform.linux,
          environment: const {'SHELL': '/usr/bin/fish'},
        ).shellName,
        'fish',
      );
      expect(service(platform: LocalShellPlatform.macos).shellName, 'zsh');
    });
  });

  group('a local session in the tab model', () {
    final engines = <XtermTerminalEngine>[];
    TerminalSession local({String id = 'local-1', String? shell = 'zsh'}) {
      final engine = XtermTerminalEngine();
      engines.add(engine);
      return TerminalSession(
        id: id,
        serverId: kLocalShellServerId,
        shellName: shell,
        engine: engine,
      );
    }

    TerminalSession remote(String id, String serverId) {
      final engine = XtermTerminalEngine();
      engines.add(engine);
      return TerminalSession(
        id: id,
        serverId: serverId,
        config: ServerConfig(
          id: serverId,
          label: serverId,
          host: 'h',
          port: 22,
          username: 'u',
          createdAt: 0,
          updatedAt: 0,
        ),
        engine: engine,
      );
    }

    tearDown(() async {
      for (final e in engines) {
        await e.dispose();
      }
      engines.clear();
    });

    test('has no server, and never renders one', () {
      final session = local();
      expect(session.isLocal, isTrue);
      expect(session.config, isNull);
      expect(session.displayLabel, 'Local shell');
      expect(session.displayTarget, 'zsh · this machine');
      // The failure mode a stand-in ServerConfig would have produced.
      expect(session.displayTarget, isNot(contains('@')));
      expect(session.displayTarget, isNot(contains(':0')));
    });

    test('falls back to a generic name when the shell is unknown', () {
      expect(local(shell: null).displayTarget, 'shell · this machine');
    });

    test('an SSH session still renders its target', () {
      final session = remote('a', 'srv');
      expect(session.isLocal, isFalse);
      expect(session.displayLabel, 'srv');
      expect(session.displayTarget, 'u@h:22');
    });

    test('local tabs group and stay contiguous like any server', () {
      final list = [
        remote('a1', 'A'),
        local(id: 'l1'),
        remote('b1', 'B'),
        local(id: 'l2'),
      ];
      expect(
        AppState.sessionsForServerIn(list, kLocalShellServerId)
            .map((s) => s.id),
        ['l1', 'l2'],
      );
      expect(AppState.insertIndexFor(list, kLocalShellServerId), 4);
    });

    test('closing a local tab falls back to its sibling, then to a server', () {
      final first = local(id: 'l1');
      final second = local(id: 'l2');
      final server = remote('a1', 'A');
      expect(
        AppState.fallbackAfterClosing(
          closed: first,
          siblingsBefore: [first, second],
          remaining: [second, server],
          lastSessionForServer: const {},
        )?.id,
        'l2',
      );
      expect(
        AppState.fallbackAfterClosing(
          closed: second,
          siblingsBefore: [second],
          remaining: [server],
          lastSessionForServer: const {},
        )?.id,
        'a1',
      );
    });

    test('an exit status is carried only by a local session', () {
      final session = local()..shellExitCode = 130;
      expect(session.shellExitCode, 130);
      expect(remote('a', 'srv').shellExitCode, isNull);
    });
  });

  group('the pinned list row', () {
    Future<void> pump(
      WidgetTester tester, {
      required int tabCount,
      TerminalStatus connection = TerminalStatus.disconnected,
      VoidCallback? onTap,
      VoidCallback? onNewTab,
      VoidCallback? onCloseAll,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocalShellTile(
            connection: connection,
            tabCount: tabCount,
            shellName: 'zsh',
            selected: false,
            onTap: onTap ?? () {},
            onNewTab: onNewTab ?? () {},
            onCloseAll: onCloseAll ?? () {},
          ),
        ),
      ),
    );

    testWidgets('names this machine and the shell it runs', (tester) async {
      await pump(tester, tabCount: 0);
      expect(find.text('Local shell'), findsOneWidget);
      expect(find.text('zsh · this machine'), findsOneWidget);
      // No reachability dot: this machine is demonstrably here.
      expect(find.byIcon(Icons.circle_outlined), findsNothing);
    });

    testWidgets('wears the same badge shape as a server row', (tester) async {
      // Structurally a server row — badge, corner status dot — so the list
      // reads as one thing. The glyph is what says which kind it is.
      await pump(tester, tabCount: 0);
      expect(find.byType(ServerAvatar), findsOneWidget);
      expect(find.byIcon(Icons.terminal), findsOneWidget);
    });

    testWidgets('counts its tabs only once there is more than one',
        (tester) async {
      await pump(tester, tabCount: 1);
      expect(find.text('×1'), findsNothing);
      await pump(tester, tabCount: 3);
      expect(find.text('×3'), findsOneWidget);
    });

    testWidgets('opens on tap', (tester) async {
      var opened = 0;
      await pump(tester, tabCount: 0, onTap: () => opened++);
      await tester.tap(find.text('Local shell'));
      expect(opened, 1);
    });

    testWidgets('offers a new shell, but nothing to close, when idle',
        (tester) async {
      await pump(tester, tabCount: 0);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('New shell'), findsOneWidget);
      expect(find.textContaining('Close'), findsNothing);
    });

    testWidgets('offers to close every open shell at once', (tester) async {
      await pump(tester, tabCount: 2);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Close all shells'), findsOneWidget);
    });

    testWidgets('a starting shell shows a spinner', (tester) async {
      await pump(
        tester,
        tabCount: 1,
        connection: TerminalStatus.connecting,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('a running shell shows the connected dot', (tester) async {
      await pump(tester, tabCount: 1, connection: TerminalStatus.connected);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byTooltip('connected'), findsOneWidget);
    });
  });

  group('the setting', () {
    test('is off by default and round-trips through JSON', () {
      expect(AppSettings().localShell, isFalse);
      final on = AppSettings(localShell: true);
      expect(AppSettings.fromJson(on.toJson()).localShell, isTrue);
      expect(
        AppSettings.fromJson(AppSettings(localShell: false).toJson())
            .localShell,
        isFalse,
      );
    });

    test('an older settings file without the key stays off', () {
      final json = AppSettings().toJson()..remove('localShell');
      expect(AppSettings.fromJson(json).localShell, isFalse);
    });
  });
}
