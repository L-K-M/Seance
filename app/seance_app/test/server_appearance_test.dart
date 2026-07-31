import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/ui/server_appearance.dart';
import 'package:seance_core/seance_core.dart';

/// The brightness is applied with an explicit [Theme] rather than
/// `MaterialApp.theme`, which is only *a candidate* — MaterialApp still picks
/// between it and `darkTheme` using the platform brightness, and would have
/// handed both halves of the brightness test the same light scheme.
Widget _wrap(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      home: Theme(
        data: ThemeData(brightness: brightness),
        child: Scaffold(body: Center(child: child)),
      ),
    );

/// The badge's fill, read back off the widget tree.
Color? _badgeFill(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byType(ServerBadge),
      matching: find.byType(Container),
    ),
  );
  return (container.decoration as BoxDecoration?)?.color;
}

void main() {
  group('ServerBadge', () {
    testWidgets('an untagged server gets the default glyph', (tester) async {
      await tester.pumpWidget(
        _wrap(const ServerBadge(color: null, icon: null)),
      );
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    });

    testWidgets('the chosen icon is the one drawn', (tester) async {
      await tester.pumpWidget(
        _wrap(const ServerBadge(color: null, icon: ServerIcon.rocket)),
      );
      expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
      expect(find.byIcon(Icons.dns_outlined), findsNothing);
    });

    testWidgets('a colour changes the fill; none leaves it neutral', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ServerBadge(color: null, icon: null)));
      final neutral = _badgeFill(tester);

      await tester.pumpWidget(
        _wrap(const ServerBadge(color: ServerColor.red, icon: null)),
      );
      expect(_badgeFill(tester), isNot(neutral));
    });

    testWidgets('the same accent resolves differently per brightness', (
      tester,
    ) async {
      // The point of storing a name rather than an ARGB value: a colour picked
      // in light mode still has to be legible in dark mode.
      await tester.pumpWidget(
        _wrap(const ServerBadge(color: ServerColor.teal, icon: null)),
      );
      final light = _badgeFill(tester);

      await tester.pumpWidget(
        _wrap(
          const ServerBadge(color: ServerColor.teal, icon: null),
          brightness: Brightness.dark,
        ),
      );
      expect(_badgeFill(tester), isNot(light));
    });

    testWidgets('every colour and icon renders', (tester) async {
      // Cheap insurance that the enums and their mappings stay exhaustive: a
      // value added to the protocol without a case here fails the switch at
      // compile time, and one added without a seed would throw right here.
      for (final color in ServerColor.values) {
        for (final icon in ServerIcon.values) {
          await tester.pumpWidget(_wrap(ServerBadge(color: color, icon: icon)));
          expect(find.byType(ServerBadge), findsOneWidget);
        }
      }
    });
  });

  group('ServerAvatar', () {
    testWidgets('carries the connection status alongside the badge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ServerAvatar(
            color: ServerColor.red,
            icon: ServerIcon.rocket,
            connection: TerminalStatus.connected,
          ),
        ),
      );
      expect(find.byType(ServerBadge), findsOneWidget);
      expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
      expect(
        find.byTooltip('connected'),
        findsOneWidget,
        reason: 'the status dot keeps the tooltip it had as a standalone dot',
      );
    });

    testWidgets('shows a spinner while connecting', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const ServerAvatar(connection: TerminalStatus.connecting),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byTooltip('connecting'), findsOneWidget);
    });
  });

  group('serverAccent', () {
    testWidgets('resolves to null for an uncoloured server', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(serverAccent(captured, null), isNull);
      expect(serverAccent(captured, ServerColor.violet), isNotNull);
    });
  });
}
