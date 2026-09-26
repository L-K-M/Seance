import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Managed edits are a side feature: a checkout folder the store cannot
/// read must cost only the restored edit tabs, never the app's startup.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-startup-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  test('load() completes when managed edits cannot be restored', () async {
    final checkoutRoot = '${directory.path}/sftp-checkouts';
    final checkout = File('$checkoutRoot/deadbeef/app.conf');
    await checkout.create(recursive: true);
    await checkout.writeAsString('unsaved edit');

    final services = await IOOverrides.runZoned(
      AppServices.initialize,
      createDirectory: (path) => path == checkoutRoot
          ? _UnlistableDirectory(path)
          : Zone.root.run(() => Directory(path)),
    );
    addTearDown(() => services.probe.dispose());
    final state = AppState(services);
    addTearDown(state.dispose);

    await expectLater(state.load(), completes);
    expect(state.tabs, isEmpty);
    expect(await checkout.readAsString(), 'unsaved edit');
  });
}

class _UnlistableDirectory extends Fake implements Directory {
  _UnlistableDirectory(this.path);

  @override
  final String path;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => Stream.error(
    FileSystemException(
      'Directory listing failed',
      path,
      const OSError('Permission denied', 13),
    ),
  );
}
