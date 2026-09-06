import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The guard that refuses a stray identity-file grant fires only where the
/// grant could change what is tested.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-resolve-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
  });

  tearDown(() async {
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  ServerConfig config(AuthMethod auth) => ServerConfig(
        id: 's1',
        label: 'prod',
        host: 'prod.example.com',
        username: 'deploy',
        authMethod: auth,
        createdAt: 1,
        updatedAt: 1,
      );
  const stray = IdentityFileBookmark(path: '/keys/id', bookmark: 'grant');

  test('a stray grant under key auth with no path is refused', () async {
    // Dropped silently, the vault credential would be tested instead — a
    // green result for a key nobody asked to try.
    await expectLater(
      services.resolveCredentials(
        config(AuthMethod.privateKey),
        draftIdentityBookmark: stray,
      ),
      throwsArgumentError,
    );
  });

  test('a stray grant under password auth is a harmless leftover', () async {
    // The editor keeps a picked file's grant across an auth-method switch.
    // Under a password it is never consulted, so it cannot change what is
    // tested — and a throw here would fail the test for nothing.
    await expectLater(
      services.resolveCredentials(
        config(AuthMethod.password),
        draftPassword: 'pw',
        draftIdentityBookmark: stray,
      ),
      completes,
    );
  });
}
