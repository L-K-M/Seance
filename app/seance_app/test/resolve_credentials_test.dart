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
    // Named, not merely `throwsArgumentError`: this is the one test whose
    // whole job is to pin that guard, and a generic validation added later
    // ("key auth with nothing to authenticate with") would satisfy the bare
    // matcher while the guard was gone.
    await expectLater(
      services.resolveCredentials(
        config(AuthMethod.privateKey),
        draftIdentityBookmark: stray,
      ),
      throwsA(isA<ArgumentError>()
          .having((e) => e.name, 'name', 'draftIdentityBookmark')),
    );
  });

  test('a stray grant beside a typed PEM is a harmless leftover', () async {
    // The typed PEM is returned before anything consults a path or a grant,
    // so the leftover cannot change what is tested here either.
    final credentials = await services.resolveCredentials(
      config(AuthMethod.privateKey),
      draftPrivateKey: 'PEM',
      draftIdentityBookmark: stray,
    );
    expect(credentials.privateKeyPem, 'PEM');
  });

  test('a grant beside a configured identity path is not refused', () async {
    // The complement of the first test, and the mode the grant exists for:
    // referenced-key auth is what the editor's Test connection runs in, so a
    // guard that fired whenever a bookmark was present — comparing the wrong
    // field, or trimming too hard — would break the only path that needs it
    // while every other test here stayed green. The file does not exist, so
    // reading it fails; what matters is that it got that far.
    //
    // Under this test's own temp directory rather than `stray.path`: that one
    // is absent because no machine happens to have `/keys/id`, which is an
    // assumption about the host rather than something this test controls —
    // and on Windows it resolves against the current drive's root. The two
    // tests either side are unaffected, since the guard fires before any file
    // is opened.
    final absent = '${directory.path}/absent-id';
    await expectLater(
      services.resolveCredentials(
        config(AuthMethod.privateKey).copyWith(identityFilePath: absent),
        draftIdentityBookmark:
            IdentityFileBookmark(path: absent, bookmark: 'grant'),
      ),
      // The concrete failure, not merely "not the guard": a regression that
      // failed earlier for an unrelated reason would satisfy a negative
      // matcher while this path lost its coverage silently.
      throwsA(isA<IdentityFileException>()),
    );
  });

  test('a stray grant under password auth is a harmless leftover', () async {
    // The editor keeps a picked file's grant across an auth-method switch.
    // Under a password it is never consulted, so it cannot change what is
    // tested — and a throw here would fail the test for nothing.
    final credentials = await services.resolveCredentials(
      config(AuthMethod.password),
      draftPassword: 'pw',
      draftIdentityBookmark: stray,
    );
    // Not merely "did not throw": the password typed is what was resolved,
    // and nothing of the grant rode along with it.
    expect(credentials.method, AuthMethod.password);
    expect(credentials.password, 'pw');
    expect(credentials.privateKeyPem, isNull);
  });
}
