import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/built_in_text_editor.dart';

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

  testWidgets('protects unsaved changes when leaving', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'unsaved');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    expect(find.text('unsaved'), findsOneWidget);
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
}
