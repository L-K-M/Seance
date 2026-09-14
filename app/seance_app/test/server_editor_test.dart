import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/ui/server_appearance.dart';
import 'package:seance_app/ui/server_editor.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The server editor as a dialog: what Return does from where, and how the
/// colour row's custom choice reaches the saved record.
///
/// Stood up over a real [AppServices] like the list-pane tests, because a
/// save writes through the config store, and the point of these is what lands
/// there.
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
    state = null;
    services = null;
    directory = null;
  });

  /// A real [AppServices] over a temp directory. `AppServices.initialize()`
  /// touches the disk, which a widget test's fake-async zone never completes
  /// — hence [WidgetTester.runAsync].
  Future<void> boot(WidgetTester tester) => tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('seance-editor-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _pathChannel,
          (call) async => directory!.path,
        );
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services!);
  });

  Future<void> openEditor(WidgetTester tester, {ServerConfig? existing}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showServerEditor(context, state!, existing),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.text(existing == null ? 'Add server' : 'Edit server'),
      findsOneWidget,
    );
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  /// The dialog's own scrollable, as opposed to one of its text fields'.
  Future<void> scrollTo(WidgetTester tester, Finder target) =>
      tester.scrollUntilVisible(
        target,
        100,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );

  /// Type the three required fields, leaving the focus in the last of them.
  Future<void> fillRequired(WidgetTester tester) async {
    await tester.enterText(field('Label'), 'box');
    await tester.enterText(field('Host'), 'box.example.com');
    await tester.enterText(field('Username'), 'deploy');
    await tester.pump();
  }

  /// Poll [done] on the real event loop until it holds or five seconds pass.
  /// Only meaningful inside `runAsync`.
  Future<void> waitUntil(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Named as what it is: a save that never landed reads differently from
    // one that wrote the wrong thing, and the downstream expect only says
    // the second.
    expect(done(), isTrue, reason: 'timed out after 5 s waiting for a save');
  }

  /// Press [key] with the editor open, and give a save it triggers time to
  /// finish. The save writes through the config store on the real event
  /// loop, so the key press that starts it has to happen inside `runAsync`
  /// too (see AGENTS.md §5). With [expectSave] false the wait is a short
  /// fixed one: long enough for a save that should not happen to show up,
  /// without spending the whole deadline proving a negative.
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool expectSave = true,
  }) async {
    await tester.runAsync(() async {
      await tester.sendKeyEvent(key);
      if (expectSave) {
        await waitUntil(() => state!.servers.isNotEmpty);
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    });
    await tester.pumpAndSettle();
  }

  group('Return', () {
    testWidgets('in a one-line field saves the server', (tester) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);

      await press(tester, LogicalKeyboardKey.enter);

      expect(state!.servers.map((s) => s.label), ['box']);
      expect(
        find.text('Add server'),
        findsNothing,
        reason: 'the dialog closed',
      );
    });

    testWidgets('in the login script is a newline, not a save', (tester) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      final script = field('Login script (optional)');
      await scrollTo(tester, script);
      await tester.enterText(script, 'cd ~/work');

      await press(tester, LogicalKeyboardKey.enter, expectSave: false);

      expect(state!.servers, isEmpty);
      expect(find.text('Add server'), findsOneWidget);
    });

    testWidgets('with a modifier saves from the login script too', (
      tester,
    ) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      final script = field('Login script (optional)');
      await scrollTo(tester, script);
      await tester.enterText(script, 'cd ~/work');

      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await waitUntil(() => state!.servers.isNotEmpty);
      });
      await tester.pumpAndSettle();

      expect(state!.servers.map((s) => s.loginScript), ['cd ~/work']);
      expect(find.text('Add server'), findsNothing);
    });

    testWidgets('on a focused button presses that button', (tester) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      // The button's own focus node, through the text it wraps: the nearest
      // Focus above the label is the button's.
      await scrollTo(tester, find.text('Cancel'));
      Focus.of(tester.element(find.text('Cancel'))).requestFocus();
      await tester.pump();

      await press(tester, LogicalKeyboardKey.enter, expectSave: false);

      expect(state!.servers, isEmpty, reason: 'Cancel, not Save');
      expect(find.text('Add server'), findsNothing, reason: 'Cancel closed it');
    });

    testWidgets('on a focused colour swatch picks the colour', (tester) async {
      // A swatch is an InkWell, which activates on Return through its own
      // action; the save shortcut yields to that, so keyboard users can pick
      // a colour without the dialog closing under them.
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      await scrollTo(tester, find.byTooltip('Teal'));
      Focus.of(
        tester.element(
          find.descendant(
            of: find.byTooltip('Teal'),
            matching: find.byType(Container),
          ),
        ),
      ).requestFocus();
      await tester.pump();

      await press(tester, LogicalKeyboardKey.enter, expectSave: false);

      expect(state!.servers, isEmpty);
      expect(find.text('Add server'), findsOneWidget);
      final previews = tester.widgetList<ServerAccentBar>(
        find.byType(ServerAccentBar),
      );
      expect(previews, isNotEmpty);
      expect(previews.map((bar) => bar.tint).toSet(), {
        const ServerTint(named: ServerColor.teal),
      });
    });

    testWidgets('does nothing while the form does not validate', (
      tester,
    ) async {
      await boot(tester);
      await openEditor(tester);
      await tester.enterText(field('Label'), 'box');

      await press(tester, LogicalKeyboardKey.enter, expectSave: false);

      expect(state!.servers, isEmpty);
      expect(find.text('Required'), findsWidgets);
    });
  });

  group('custom colour', () {
    testWidgets('is stored with the nearest named accent beside it', (
      tester,
    ) async {
      await boot(tester);
      await openEditor(tester);
      await fillRequired(tester);
      await scrollTo(tester, find.byTooltip('Custom colour…'));
      await tester.tap(find.byTooltip('Custom colour…'));
      await tester.pumpAndSettle();
      expect(find.text('Custom colour'), findsOneWidget);
      // Deliberately no frame between typing and pressing: the press has to
      // take what was typed, not what was drawn.
      await tester.enterText(find.widgetWithText(TextField, 'Hex'), '1e90ff');
      await tester.tap(find.text('Use colour'));
      await tester.pumpAndSettle();
      // The swatch now shows the choice, and says what it is.
      expect(find.byTooltip('Custom colour (#1E90FF)'), findsOneWidget);

      // Into view first: the row is scrolled to the colour swatches, and a
      // tap on a button below the fold lands on nothing.
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await waitUntil(() => state!.servers.isNotEmpty);
      });
      await tester.pumpAndSettle();

      final saved = state!.servers.single;
      expect(saved.customColor, '#1E90FF');
      // What a build without the field draws: the closest of the ten by hue.
      expect(saved.color, ServerColor.blue);

      // And reopening finds the choice in force rather than the stand-in.
      await openEditor(tester, existing: saved);
      await scrollTo(tester, find.byTooltip('Custom colour (#1E90FF)'));
      expect(find.byTooltip('Custom colour (#1E90FF)'), findsOneWidget);
    });

    testWidgets('a named swatch replaces it', (tester) async {
      await boot(tester);
      final existing = ServerConfig(
        id: 'box',
        label: 'box',
        host: 'box.example.com',
        username: 'deploy',
        color: ServerColor.blue,
        customColor: '#1E90FF',
        createdAt: 1,
        updatedAt: 1,
      );
      await tester.runAsync(() => state!.saveServer(existing));
      await openEditor(tester, existing: existing);
      await scrollTo(tester, find.byTooltip('Teal'));
      await tester.tap(find.byTooltip('Teal'));
      await tester.pump();
      expect(find.byTooltip('Custom colour…'), findsOneWidget);

      // Into view first: the row is scrolled to the colour swatches, and a
      // tap on a button below the fold lands on nothing.
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await waitUntil(() => state!.servers.single.customColor == null);
      });
      await tester.pumpAndSettle();

      final saved = state!.servers.single;
      expect(saved.color, ServerColor.teal);
      expect(saved.customColor, isNull);
    });
  });
}
