import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/managed_remote_file_store.dart';
import 'package:seance_app/services/remote_files_controller.dart';
import 'package:seance_app/ui/built_in_text_editor.dart';
import 'package:seance_app/ui/editor_syntax.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-editor-test-');
    file = File('${directory.path}/config.txt');
    await file.writeAsString('one\ntwo\n');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('loads UTF-8 and atomically saves edited text', () async {
    expect(await loadBuiltInTextDocument(file), 'one\ntwo\n');

    await saveBuiltInTextDocument(file, 'changed\n');

    expect(await file.readAsString(), 'changed\n');
    expect(await directory.list().length, 1);
  });

  test('preserves a UTF-8 BOM and CRLF line endings', () async {
    await file.writeAsBytes([0xef, 0xbb, 0xbf, ...'one\r\ntwo\r\n'.codeUnits]);
    final document = await loadBuiltInTextDocumentDetails(file);

    expect(document.text, 'one\r\ntwo\r\n');
    expect(document.hasUtf8Bom, isTrue);
    expect(document.lineEnding, '\r\n');

    await saveBuiltInTextDocument(
      file,
      '${document.text}three\n',
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), [
      0xef,
      0xbb,
      0xbf,
      ...'one\r\ntwo\r\nthree\r\n'.codeUnits,
    ]);
  });

  test('refuses to overwrite an independently changed local copy', () async {
    final document = await loadBuiltInTextDocumentDetails(file);
    await file.writeAsString('external change\n');

    await expectLater(
      saveBuiltInTextDocument(
        file,
        'built-in change\n',
        expectedSha256: document.sha256,
      ),
      throwsStateError,
    );
    expect(await file.readAsString(), 'external change\n');
  });

  test('rejects malformed, binary, and oversized content', () async {
    await file.writeAsBytes([0xff]);
    await expectLater(loadBuiltInTextDocument(file), throwsStateError);

    await file.writeAsBytes([0, 1, 2]);
    await expectLater(loadBuiltInTextDocument(file), throwsStateError);

    await file.writeAsBytes([1, 2, 3]);
    await expectLater(
      loadBuiltInTextDocument(file, maximumBytes: 2),
      throwsStateError,
    );
  });

  testWidgets('edits, saves, and reports the local save', (tester) async {
    var saved = 0;
    String? savedText;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
          saveDocument: (_, text) async => savedText = text,
          onSaved: () async => saved++,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('one\ntwo\n'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'edited locally\n');
    await tester.pump();
    await tester.tap(find.byTooltip('Save locally'));
    await tester.pumpAndSettle();

    expect(savedText, 'edited locally\n');
    expect(saved, 1);
    expect(find.textContaining('Saved locally'), findsOneWidget);
  });

  testWidgets('protects unsaved changes when its tab is closed', (
    tester,
  ) async {
    final key = GlobalKey<BuiltInTextEditorScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          key: key,
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'unsaved');
    await tester.pump();

    // The tab strip's close button asks the editor through this call.
    final closing = key.currentState!.confirmDiscard();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    expect(find.text('unsaved'), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(await closing, isFalse);

    final discarding = key.currentState!.confirmDiscard();
    await tester.pump();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(await discarding, isTrue);
  });

  testWidgets('a clean buffer closes without asking', (tester) async {
    final key = GlobalKey<BuiltInTextEditorScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          key: key,
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
        ),
      ),
    );
    await tester.pump();

    expect(await key.currentState!.confirmDiscard(), isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('mirrors the dirty flag into the hosting strip', (tester) async {
    final dirty = ValueNotifier<bool>(true);
    addTearDown(dirty.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
          dirtyNotifier: dirty,
        ),
      ),
    );
    await tester.pump();
    expect(dirty.value, isFalse); // clean buffer

    await tester.enterText(find.byType(TextField), 'unsaved');
    await tester.pump();
    expect(dirty.value, isTrue);
  });

  testWidgets('going inactive releases the editor\'s focus', (tester) async {
    Widget host(bool active) => MaterialApp(
      home: BuiltInTextEditorScreen(
        file: file,
        remotePath: '/etc/config.txt',
        initialText: 'one\ntwo\n',
        isActive: active,
      ),
    );

    await tester.pumpWidget(host(true));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.focusNode!.hasFocus, isTrue);

    // The tab slid into the background: its focus goes with it, or the
    // foreground tab's keystrokes would land here.
    await tester.pumpWidget(host(false));
    await tester.pump();
    expect(field.focusNode!.hasFocus, isFalse);
  });

  testWidgets('a focus restore queued before deactivation does not fire', (
    tester,
  ) async {
    Widget host(bool active) => MaterialApp(
      home: BuiltInTextEditorScreen(
        file: file,
        remotePath: '/etc/config.txt',
        initialText: 'one\ntwo\n',
        isActive: active,
      ),
    );

    await tester.pumpWidget(host(false));
    // Activation queues a post-frame requestFocus; the deactivation that
    // follows it must still be the last word on who holds focus.
    await tester.pumpWidget(host(true));
    await tester.pumpWidget(host(false));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.focusNode!.hasFocus, isFalse);
  });

  Future<void> pressCtrlS(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  testWidgets('Ctrl-S saves and uploads a server file immediately', (
    tester,
  ) async {
    var uploads = 0;
    var saved = 0;
    String? savedText;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
          saveDocument: (_, text) async => savedText = text,
          onSaved: () async => saved++,
          onUpload: () async {
            uploads++;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(savedText, 'edited\n');
    expect(uploads, 1);
    // The upload reconciles the copy itself; onSaved only runs when it fails.
    expect(saved, 0);
    expect(find.text('Saved and uploaded.'), findsOneWidget);
    // No confirmation dialog of any kind appeared.
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Cmd-S (meta) is the same save-and-upload as Ctrl-S', (
    tester,
  ) async {
    var uploads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\n',
          saveDocument: (_, text) async {},
          onUpload: () async {
            uploads++;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(uploads, 1);
    expect(find.text('Saved and uploaded.'), findsOneWidget);
  });

  testWidgets('Ctrl-S falls back to reconciling when the upload fails', (
    tester,
  ) async {
    var saved = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\n',
          saveDocument: (_, text) async {},
          onSaved: () async => saved++,
          onUpload: () async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(saved, 1);
    expect(find.text('Saved locally; not uploaded.'), findsOneWidget);
  });

  testWidgets('Ctrl-S still reconciles when the upload throws', (tester) async {
    var saved = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\n',
          saveDocument: (_, text) async {},
          onSaved: () async => saved++,
          onUpload: () async => throw StateError('connection lost'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(saved, 1);
    expect(find.textContaining('connection lost'), findsOneWidget);
  });

  testWidgets('Ctrl-S saves locally when there is no upload target', (
    tester,
  ) async {
    var saved = 0;
    String? savedText;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\n',
          saveDocument: (_, text) async => savedText = text,
          onSaved: () async => saved++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(savedText, 'edited\n');
    expect(saved, 1);
    expect(find.text('Saved locally.'), findsOneWidget);
  });

  testWidgets('opens scrolled to the top with the caret at the start', (
    tester,
  ) async {
    final longText = List.generate(400, (index) => 'line $index').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/long.txt',
          initialText: longText,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(TextField),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.pixels, 0);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.selection.baseOffset, 0);
  });

  testWidgets('uses a monospace font stack', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\n',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final style = tester.widget<TextField>(find.byType(TextField)).style;
    expect(style?.fontFamilyFallback, contains('monospace'));
  });

  testWidgets('find bar counts matches, navigates, wraps, and toggles case', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'alpha beta\nBeta gamma\nbeta end\n',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Find'));
    await tester.pumpAndSettle();
    final searchField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == 'Find in file',
    );
    expect(searchField, findsOneWidget);

    await tester.enterText(searchField, 'beta');
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);

    await tester.tap(find.byTooltip('Next match'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous match'));
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous match'));
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget); // wraps backwards

    // The caret is parked on the third match; the case-sensitive re-search
    // drops 'Beta' and resumes from the caret, i.e. its second match.
    await tester.tap(find.byTooltip('Match case'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);

    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(searchField, findsNothing);
  });

  testWidgets('search highlights land on the editor text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'alpha beta\n',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Find'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Find in file',
      ),
      'beta',
    );
    await tester.pumpAndSettle();

    final editorField = find
        .byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.controller is CodeEditingController,
        )
        .first;
    final controller =
        tester.widget<TextField>(editorField).controller!
            as CodeEditingController;
    expect(controller.searchMatches, hasLength(1));
    expect(controller.searchMatches.single.start, 6);
    expect(controller.activeMatchIndex, 0);
  });

  testWidgets('edits made during a save remain unsaved', (tester) async {
    final saveStarted = Completer<void>();
    final finishSave = Completer<void>();
    String? persisted;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'initial',
          saveDocument: (_, text) async {
            persisted = text;
            saveStarted.complete();
            await finishSave.future;
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'first edit');
    await tester.pump();
    await tester.tap(find.byTooltip('Save locally'));
    await tester.pump();
    await saveStarted.future;
    await tester.enterText(find.byType(TextField), 'newer edit');
    finishSave.complete();
    await tester.pumpAndSettle();

    expect(persisted, 'first edit');
    expect(find.textContaining('Unsaved'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.save_outlined),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('offers reload once the server copy drifts', (tester) async {
    // runAsync throughout: checkout, refresh and reload all do real file IO.
    // pumpAndSettle is unusable there (the blinking cursor never settles), so
    // frames are driven by bounded pumps instead.
    await tester.runAsync(() async {
      final remote = _FakeRemoteFileSystem({'/etc/config.txt': 'one\ntwo\n'});
      final controller = await _driftController(remote);
      addTearDown(controller.dispose);
      final copy = await controller.checkoutRemoteFile(
        remote.entry('/etc/config.txt'),
      );

      // The server copy moves on after the checkout was taken.
      remote.files['/etc/config.txt'] = 'one\ntwo\nthree\n';

      await tester.pumpWidget(
        MaterialApp(
          home: BuiltInTextEditorScreen(
            file: controller.localFile(copy),
            remotePath: copy.remotePath,
            remoteFiles: controller,
          ),
        ),
      );
      await tester.pump();
      // The document loads off the real event loop — wait for the editor
      // body before the banner so neither races the loading spinner.
      await _pollUntil(
        tester,
        () => find.byType(TextField).evaluate().isNotEmpty,
      );
      await _pollUntil(
        tester,
        () =>
            find.text('This file changed on the server.').evaluate().isNotEmpty,
      );

      // The mount-time check flags the drift without any user action.
      expect(find.text('This file changed on the server.'), findsOneWidget);

      await tester.tap(find.text('Reload'));
      await _pollUntil(
        tester,
        () => _editorText(tester) == 'one\ntwo\nthree\n',
      );

      expect(find.text('This file changed on the server.'), findsNothing);
      expect(controller.remoteChangedFor(copy.remotePath), isFalse);
    });
  });

  testWidgets('reload confirms before discarding local edits', (tester) async {
    await tester.runAsync(() async {
      final remote = _FakeRemoteFileSystem({'/etc/config.txt': 'one\ntwo\n'});
      final controller = await _driftController(remote);
      addTearDown(controller.dispose);
      final copy = await controller.checkoutRemoteFile(
        remote.entry('/etc/config.txt'),
      );
      remote.files['/etc/config.txt'] = 'server side\n';

      await tester.pumpWidget(
        MaterialApp(
          home: BuiltInTextEditorScreen(
            file: controller.localFile(copy),
            remotePath: copy.remotePath,
            remoteFiles: controller,
          ),
        ),
      );
      await tester.pump();
      await _pollUntil(
        tester,
        () => find.byType(TextField).evaluate().isNotEmpty,
      );
      await _pollUntil(
        tester,
        () =>
            find.text('This file changed on the server.').evaluate().isNotEmpty,
      );
      await tester.enterText(find.byType(TextField).first, 'local edit\n');
      await tester.pump();

      await tester.tap(find.text('Reload'));
      await tester.pump();
      expect(find.text('Discard local changes?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'local edit\n',
      );

      await tester.tap(find.text('Reload'));
      await tester.pump();
      await tester.tap(find.text('Discard and reload'));
      await _pollUntil(tester, () => _editorText(tester) == 'server side\n');
      expect(_editorText(tester), 'server side\n');
    });
  });

  testWidgets('a server-deleted file offers keep-local, not reload', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final remote = _FakeRemoteFileSystem({'/etc/config.txt': 'one\n'});
      final controller = await _driftController(remote);
      addTearDown(controller.dispose);
      final copy = await controller.checkoutRemoteFile(
        remote.entry('/etc/config.txt'),
      );
      remote.files.remove('/etc/config.txt');

      await tester.pumpWidget(
        MaterialApp(
          home: BuiltInTextEditorScreen(
            file: controller.localFile(copy),
            remotePath: copy.remotePath,
            remoteFiles: controller,
          ),
        ),
      );
      await tester.pump();
      await _pollUntil(
        tester,
        () => find.byType(TextField).evaluate().isNotEmpty,
      );
      await _pollUntil(
        tester,
        () => find
            .text('This file no longer exists on the server.')
            .evaluate()
            .isNotEmpty,
      );

      // Reload can only fail against a deleted remote — don't offer it.
      expect(find.text('Reload'), findsNothing);
      expect(find.text('Keep local copy'), findsOneWidget);

      await tester.tap(find.text('Keep local copy'));
      await tester.pump();
      expect(
        find.text('This file no longer exists on the server.'),
        findsNothing,
      );
      // The local copy is untouched.
      expect(_editorText(tester), 'one\n');
    });
  });

  test('lineStartOffsets counts logical lines', () {
    expect(lineStartOffsets(''), [0]);
    expect(lineStartOffsets('one'), [0]);
    expect(lineStartOffsets('one\ntwo\n'), [0, 4, 8]);
    expect(lineStartOffsets('\n'), [0, 1]);
    expect(lineStartOffsets('one\r\ntwo'), [0, 5]);
  });

  testWidgets('a gutter insets the text field', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gutter = find.byKey(const ValueKey('editor-line-gutter'));
    expect(gutter, findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(TextField)).dx,
      tester.getSize(gutter).width,
    );
  });

  testWidgets('the gutter widens when line numbers grow a digit', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final oneDigit = tester.getTopLeft(find.byType(TextField)).dx;

    await tester.enterText(
      find.byType(TextField),
      List.generate(12, (i) => 'line $i').join('\n'),
    );
    await tester.pump();
    final twoDigits = tester.getTopLeft(find.byType(TextField)).dx;

    expect(twoDigits, greaterThan(oneDigit));
  });

  testWidgets('the status bar tracks the caret, size, and unsaved state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ln 1, Col 1 · 3 lines · 8 bytes'), findsOneWidget);
    expect(find.text('LF · UTF-8'), findsOneWidget);

    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();
    expect(find.textContaining('Ln 2, Col 2'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'one\ntwo\nthree');
    await tester.pump();
    expect(find.text('Ln 3, Col 6 · 3 lines · 13 bytes'), findsOneWidget);
    expect(find.textContaining('Unsaved edits'), findsOneWidget);
  });

  testWidgets('the status bar reports CRLF endings and a UTF-8 BOM', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await file.writeAsBytes([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('one\r\ntwo\r\n'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: BuiltInTextEditorScreen(
            file: file,
            remotePath: '/etc/config.txt',
          ),
        ),
      );
      await tester.pump();
      await _pollUntil(
        tester,
        () => find.textContaining('CRLF').evaluate().isNotEmpty,
      );
      expect(find.text('CRLF · UTF-8 BOM'), findsOneWidget);
    });
  });

  testWidgets('the status bar shows local changes and server drift', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final remote = _FakeRemoteFileSystem({'/etc/config.txt': 'one\ntwo\n'});
      final controller = await _driftController(remote);
      addTearDown(controller.dispose);
      final copy = await controller.checkoutRemoteFile(
        remote.entry('/etc/config.txt'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: BuiltInTextEditorScreen(
            file: controller.localFile(copy),
            remotePath: copy.remotePath,
            remoteFiles: controller,
          ),
        ),
      );
      await tester.pump();
      await _pollUntil(
        tester,
        () => find.byType(TextField).evaluate().isNotEmpty,
      );
      await _pollUntil(
        tester,
        () => find.textContaining('In sync').evaluate().isNotEmpty,
      );

      // A managed copy whose checkout no longer matches its baseline is a
      // local change waiting to be uploaded.
      controller.localCopies[copy.remotePath] = copy.copyWith(dirty: true);
      await controller.checkRemoteSnapshot(copy.remotePath);
      await tester.pump();
      expect(find.textContaining('Local changes'), findsOneWidget);
      expect(find.textContaining('In sync'), findsNothing);

      // The server copy moving on is a separate fact and is reported too.
      remote.files['/etc/config.txt'] = 'one\ntwo\nthree\n';
      await controller.checkRemoteSnapshot(copy.remotePath);
      await tester.pump();
      expect(find.textContaining('Changed on server'), findsOneWidget);
      expect(find.textContaining('Local changes'), findsOneWidget);
    });
  });
}

/// Bounded poll for async work landing inside `tester.runAsync` — a fixed
/// sleep would be both slower and flaky on a loaded CI runner. Returns as
/// soon as the condition holds; the 5 s ceiling only bites when it's stuck.
Future<void> _pollUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 500; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
    if (condition()) return;
  }
  fail('Polled condition was not met within 5s');
}

/// The editor buffer's current text, or null while the loading spinner is
/// still standing in for the TextField.
String? _editorText(WidgetTester tester) {
  final field = find.byType(TextField);
  if (field.evaluate().isEmpty) return null;
  return tester.widget<TextField>(field.first).controller!.text;
}

/// A controller backed by a temp-dir store and [_FakeRemoteFileSystem],
/// initialized so its remote handle is live.
Future<RemoteFilesController> _driftController(
  _FakeRemoteFileSystem remote,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'seance-editor-drift-',
  );
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  final controller = RemoteFilesController(
    () async => remote,
    shellDirectory: ValueNotifier<String?>(null),
    managedFileStore: ManagedRemoteFileStore(
      indexFile: File('${directory.path}/index.json'),
      checkoutRoot: Directory('${directory.path}/checkouts'),
    ),
    serverId: 'server',
    editSessionId: 'session',
  );
  await controller.initialize();
  return controller;
}

/// Minimal in-memory remote: one directory's worth of regular text files.
class _FakeRemoteFileSystem implements RemoteFileSystem {
  final Map<String, String> files;

  _FakeRemoteFileSystem(this.files);

  RemoteFileEntry entry(String path) => RemoteFileEntry(
    path: path,
    name: remoteBasename(path),
    type: RemoteFileType.file,
    size: files[path]?.length,
  );

  @override
  Future<String> canonicalize(String path) async => '/etc';

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async => [
    for (final file in files.keys)
      if (remoteParent(file) == path) entry(file),
  ];

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (!files.containsKey(path)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'inspect',
        path: path,
        message: 'Not found',
      );
    }
    return entry(path);
  }

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    final content = files[path];
    if (content == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'download',
        path: path,
        message: 'Not found',
      );
    }
    final bytes = utf8.encode(content);
    destination.add(bytes);
    onProgress?.call(bytes.length, bytes.length);
    return entry(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '_FakeRemoteFileSystem.${invocation.memberName}',
  );
}
