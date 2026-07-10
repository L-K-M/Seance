import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/file_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(MethodChannelFileExportPlatform.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'method channel sends the SAF method names and export metadata',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'pickExportDirectory' => true,
          'hasExportDirectoryAccess' => false,
          'exportFile' => 'content://provider/tree/root/document/report.txt',
          'releaseExportDirectory' => null,
          _ => throw MissingPluginException(),
        };
      });
      final platform = MethodChannelFileExportPlatform(channel: channel);

      expect(await platform.pickExportDirectory(), isTrue);
      expect(await platform.hasExportDirectoryAccess(), isFalse);
      expect(
        await platform.exportFile(
          sourcePath: '/cache/staged-report.txt',
          fileName: 'report.txt',
          mimeType: 'text/plain',
        ),
        'content://provider/tree/root/document/report.txt',
      );
      await platform.releaseExportDirectory();

      expect(calls.map((call) => call.method), [
        'pickExportDirectory',
        'hasExportDirectoryAccess',
        'exportFile',
        'releaseExportDirectory',
      ]);
      expect(calls[0].arguments, isNull);
      expect(calls[1].arguments, isNull);
      expect(calls[2].arguments, {
        'sourcePath': '/cache/staged-report.txt',
        'fileName': 'report.txt',
        'mimeType': 'text/plain',
      });
      expect(calls[3].arguments, isNull);
    },
  );

  test('method channel preserves safe native errors', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'NO_EXPORT_DIRECTORY',
        message: 'Choose an export directory before exporting files.',
      );
    });
    final platform = MethodChannelFileExportPlatform(channel: channel);

    await expectLater(
      platform.exportFile(
        sourcePath: '/cache/report.txt',
        fileName: 'report.txt',
        mimeType: 'text/plain',
      ),
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'NO_EXPORT_DIRECTORY')
            .having(
              (error) => error.message,
              'message',
              'Choose an export directory before exporting files.',
            ),
      ),
    );
  });

  test('stages a stream and returns a share-ready XFile', () async {
    final root = await Directory.systemTemp.createTemp('seance_export_test');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final service = FileExportService(
      platform: _UnexpectedPlatform(),
      stagingDirectoryProvider: () async => root,
      useAndroidSaf: false,
    );

    final staged = await service.stageFile(
      fileName: 'session.log',
      contents: Stream<List<int>>.fromIterable([
        [1, 2],
        [3, 4],
      ]),
      mimeType: 'text/plain',
    );
    final shareFile = await service.shareReadyFile(staged);

    expect(await staged.file.readAsBytes(), [1, 2, 3, 4]);
    expect(staged.file.path, contains('seance-export-'));
    expect(shareFile.path, staged.file.path);
    expect(shareFile.name, 'session.log');
    expect(shareFile.mimeType, 'text/plain');
  });

  test('uses the injected desktop saver without invoking Android', () async {
    final root = await Directory.systemTemp.createTemp('seance_export_test');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    StagedExportFile? received;
    final service = FileExportService(
      platform: _UnexpectedPlatform(),
      stagingDirectoryProvider: () async => root,
      desktopSave: (file) async {
        received = file;
        return '/saved/${file.fileName}';
      },
      useAndroidSaf: false,
    );
    final staged = await service.stageFile(
      fileName: 'keys.json',
      contents: Stream<List<int>>.value([7, 8, 9]),
      mimeType: 'application/json',
    );

    expect(await service.exportFile(staged), '/saved/keys.json');
    expect(received, same(staged));
    expect(await service.pickExportDirectory(), isFalse);
    expect(await service.hasExportDirectoryAccess(), isFalse);
    await service.releaseExportDirectory();
  });
}

class _UnexpectedPlatform implements FileExportPlatform {
  Never _unexpected() => throw StateError('Android platform was invoked');

  @override
  Future<String> exportFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async => _unexpected();

  @override
  Future<bool> hasExportDirectoryAccess() async => _unexpected();

  @override
  Future<bool> pickExportDirectory() async => _unexpected();

  @override
  Future<void> releaseExportDirectory() async => _unexpected();
}
