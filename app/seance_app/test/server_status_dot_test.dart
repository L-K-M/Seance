import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/server_status_dot.dart';
import 'package:seance_app/ui/sidebar/sidebar_kit.dart';
import 'package:seance_core/seance_core.dart';

/// The one dot a server row shows, which the sibling apps share: the same
/// truth must read the same way in Séance's rail and Poltergeist's SERVERS.
void main() {
  group('serverDotFor', () {
    test('a live session outranks whatever the probe said', () {
      for (final probe in ProbeStatus.values) {
        expect(
          serverDotFor(session: TerminalStatus.connected, probe: probe),
          ServerDot.connected,
        );
        expect(
          serverDotFor(session: TerminalStatus.connecting, probe: probe),
          ServerDot.connecting,
        );
        expect(
          serverDotFor(session: TerminalStatus.error, probe: probe),
          ServerDot.failed,
        );
        // A failure at a changed host key blocks the server until the key
        // is reviewed, which is not the same as a failure to retry.
        expect(
          serverDotFor(
            session: TerminalStatus.error,
            probe: probe,
            hostKeyBlocked: true,
          ),
          ServerDot.blocked,
        );
        // Another tab still connected outranks it, as it outranks a failure.
        expect(
          serverDotFor(
            session: TerminalStatus.connected,
            probe: probe,
            hostKeyBlocked: true,
          ),
          ServerDot.connected,
        );
      }
    });

    test('with no live session the probe speaks, and unknown is no dot', () {
      for (final session in [null, TerminalStatus.disconnected]) {
        expect(
          serverDotFor(session: session, probe: ProbeStatus.online),
          ServerDot.reachable,
        );
        expect(
          serverDotFor(session: session, probe: ProbeStatus.offline),
          ServerDot.unreachable,
        );
        expect(
          serverDotFor(session: session, probe: ProbeStatus.unknown),
          ServerDot.none,
        );
      }
    });
  });

  test('session truth is solid; a probe observation is a ring', () {
    expect(
      [for (final dot in ServerDot.values) (dot, dot.style)],
      [
        (ServerDot.none, SidebarDotStyle.solid),
        (ServerDot.connected, SidebarDotStyle.solid),
        (ServerDot.connecting, SidebarDotStyle.solid),
        (ServerDot.failed, SidebarDotStyle.solid),
        (ServerDot.blocked, SidebarDotStyle.blocked),
        (ServerDot.reachable, SidebarDotStyle.ring),
        (ServerDot.unreachable, SidebarDotStyle.ring),
      ],
    );
    // Every drawn dot says what it means (the row folds it into its label).
    for (final dot in ServerDot.values) {
      expect(dot.description == null, dot == ServerDot.none, reason: '$dot');
    }
  });

  testWidgets('green, amber and red, by the theme\'s status colours', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.dark(),
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(ServerDot.none.color(context), isNull);
    expect(ServerDot.connected.color(context), StatusColors.online(context));
    expect(ServerDot.reachable.color(context), StatusColors.online(context));
    expect(
      ServerDot.connecting.color(context),
      StatusColors.connecting(context),
    );
    expect(ServerDot.failed.color(context), StatusColors.offline(context));
    expect(ServerDot.blocked.color(context), StatusColors.offline(context));
    expect(ServerDot.unreachable.color(context), StatusColors.offline(context));
  });

  group('aggregateSessionStatus', () {
    ServerConfig config() => const ServerConfig(
      id: 'box',
      label: 'box',
      host: 'box.example.com',
      username: 'deploy',
      createdAt: 1,
      updatedAt: 1,
    );

    TerminalSession tab({bool connecting = false, String? error}) =>
        TerminalSession(
          id: 'tab-${identityHashCode(Object())}',
          serverId: 'box',
          config: config(),
          engine: XtermTerminalEngine(),
          connecting: connecting,
          error: error,
        );

    test('no tabs is no session at all', () {
      expect(aggregateSessionStatus(const []), isNull);
    });

    test('connecting wins, then error, else disconnected', () {
      expect(
        aggregateSessionStatus([tab(error: 'x'), tab(connecting: true)]),
        TerminalStatus.connecting,
      );
      expect(
        aggregateSessionStatus([tab(), tab(error: 'x')]),
        TerminalStatus.error,
      );
      expect(aggregateSessionStatus([tab()]), TerminalStatus.disconnected);
    });
  });
}
