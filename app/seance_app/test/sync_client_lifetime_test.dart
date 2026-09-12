import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/secure_master_key.dart';
import 'package:seance_core/seance_core.dart';

const _baseUrl = 'https://sync.test';
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

enum _Enrollment { register, login }
enum _ResponseMode { accepted, rejected }

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler);
  int closes = 0;

  @override
  void close() {
    closes++;
    super.close();
  }
}


/// A keystore that serves reads and ordinary writes but can refuse the vault
/// master key specifically, which is how a locked keyring fails the one write
/// that installs a re-key's new key.
class _SelectiveKeystore extends FlutterSecureStorage {
  _SelectiveKeystore();
  static const _masterKeyName = 'seance.vault.masterKey.v1';
  final Map<String, String> _map = {};
  bool refuseMasterKey = false;
  bool commitMasterKeyBeforeFailure = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _map[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (refuseMasterKey && key == _masterKeyName) {
      if (commitMasterKeyBeforeFailure && value != null) _map[key] = value;
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
    if (value == null) {
      _map.remove(key);
      return;
    }
    _map[key] = value;
  }

  // Nothing in MasterKeyManager deletes today, but an unstubbed override
  // reaches the real platform channel, which no-ops under the test binding
  // instead of failing — so the fake would diverge silently rather than loudly.
  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _map.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-sync-lifetime-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    services.settings.syncBaseUrl = _baseUrl;
    await services.masterKeys.putApiKey('sync.token', 'session-token');
  });

  tearDown(() async {
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  for (final enrollment in _Enrollment.values) {
    for (final responseMode in _ResponseMode.values) {
      test('${enrollment.name} ${responseMode.name} closes its client', () async {
        const sharedSecret = Secret(
          id: 'shared',
          kind: SecretKind.password,
          value: 'shared-password',
        );
        await services.vault.putSecret(sharedSecret);
        for (final id in ['first', 'second']) {
          await services.configStore.putServer(ServerConfig(
            id: id,
            label: id,
            host: '$id.test',
            username: 'user',
            secretRef: sharedSecret.id,
            createdAt: 1,
            updatedAt: 1,
          ));
        }
        final transport = _TrackedClient((request) async {
          if (request.url.path == '/v1/prelogin') {
            return http.Response(jsonEncode({
              'argonSalt': base64Encode(List<int>.filled(16, 0)),
              'argonParams': const Argon2Params().toJson(),
            }), HttpStatus.ok);
          }
          if (responseMode == _ResponseMode.rejected) {
            return http.Response('unavailable', HttpStatus.serviceUnavailable);
          }
          if (request.url.path == '/v1/sync') {
            return http.Response(
                jsonEncode(const PullResponse(records: [], latestSeq: 0).toJson()),
                HttpStatus.ok);
          }
          return http.Response(jsonEncode({'token': 'enrolled-token'}),
              HttpStatus.ok);
        });
        final enroll = switch (enrollment) {
          _Enrollment.register => services.registerSync,
          _Enrollment.login => services.loginSync,
        };
        final result = http.runWithClient(
          () => enroll(
            baseUrl: _baseUrl,
            username: 'user',
            password: 'password',
            encryptionPassphrase: 'password',
          ),
          () => transport,
        );
        if (responseMode == _ResponseMode.rejected) {
          await expectLater(result, throwsA(isA<ApiError>()));
        } else {
          await result;
          expect(await services.masterKeys.getApiKey('sync.token'), 'enrolled-token');
        }
        expect(transport.closes, 1);
        expect((await services.vault.getSecret(sharedSecret.id))?.value,
            sharedSecret.value);
        final reopened = await AppServices.initialize();
        addTearDown(() => reopened.probe.dispose());
        expect((await reopened.vault.getSecret(sharedSecret.id))?.value,
            sharedSecret.value,
            reason: 'shared credentials must remain decryptable after restart');
      }, timeout: const Timeout(Duration(minutes: 2)));
    }
  }

  test('successful sync closes its client after consuming the response', () async {
    final transport = _TrackedClient((request) async {
      expect(request.headers['authorization'], 'Bearer session-token');
      return http.Response(
          jsonEncode(const PullResponse(records: [], latestSeq: 0).toJson()),
          HttpStatus.ok);
    });
    await http.runWithClient(services.runSync, () => transport);
    expect(transport.closes, 1);
  });

  test('failed sync closes its client', () async {
    final transport = _TrackedClient((_) async =>
        http.Response('unavailable', HttpStatus.serviceUnavailable));
    await expectLater(http.runWithClient(services.runSync, () => transport),
        throwsA(isA<ApiError>()));
    expect(transport.closes, 1);
  });

  test('malformed prelogin closes its client', () async {
    final transport = _TrackedClient((_) async =>
        http.Response('not-json', HttpStatus.ok));
    await expectLater(
      http.runWithClient(
        () => services.loginSync(
          baseUrl: _baseUrl,
          username: 'user',
          password: 'password',
          encryptionPassphrase: 'password',
        ),
        () => transport,
      ),
      throwsFormatException,
    );
    expect(transport.closes, 1);
  });

  test('weak prelogin is rejected before login and closes its client', () async {
    final paths = <String>[];
    final transport = _TrackedClient((request) async {
      paths.add(request.url.path);
      return http.Response(jsonEncode({
        'argonSalt': base64Encode(List<int>.filled(16, 0)),
        'argonParams': const Argon2Params.fast().toJson(),
      }), HttpStatus.ok);
    });
    await expectLater(
      http.runWithClient(
        () => services.loginSync(
          baseUrl: _baseUrl,
          username: 'user',
          password: 'password',
          encryptionPassphrase: 'password',
        ),
        () => transport,
      ),
      throwsA(isA<StateError>().having(
          (error) => error.message, 'reason', contains('weaker'))),
    );
    expect(paths, ['/v1/prelogin']);
    expect(transport.closes, 1);
  });

  for (final committedBeforeFailure in [false, true]) {
  test('a refused re-key preserves credentials (committed=$committedBeforeFailure)',
      () async {
    final keystore = _SelectiveKeystore();
    final own = await AppServices.initialize(
        masterKeyManager: MasterKeyManager(keystore));
    addTearDown(() => own.probe.dispose());

    final secrets = [
      for (final id in ['alpha', 'beta', 'gamma'])
        Secret(id: id, kind: SecretKind.password, value: 'password-$id'),
    ];
    for (final secret in secrets) {
      await own.vault.putSecret(secret);
      await own.configStore.putServer(ServerConfig(
        id: secret.id,
        label: secret.id,
        host: '${secret.id}.test',
        username: 'user',
        secretRef: secret.id,
        createdAt: 1,
        updatedAt: 1,
      ));
    }

    final transport = _TrackedClient((request) async {
      if (request.url.path == '/v1/prelogin') {
        return http.Response(jsonEncode({
          'argonSalt': base64Encode(List<int>.filled(16, 0)),
          'argonParams': const Argon2Params().toJson(),
        }), HttpStatus.ok);
      }
      if (request.url.path == '/v1/sync') {
        return http.Response(
            jsonEncode(const PullResponse(records: [], latestSeq: 0).toJson()),
            HttpStatus.ok);
      }
      return http.Response(
          jsonEncode({'token': 'enrolled-token'}), HttpStatus.ok);
    });

    // The vault file re-seals fine; the keyring refuses the one write that
    // would make the new key survive a restart.
    keystore.refuseMasterKey = true;
    keystore.commitMasterKeyBeforeFailure = committedBeforeFailure;
    await expectLater(
      http.runWithClient(
        () => own.registerSync(
          baseUrl: _baseUrl,
          username: 'user',
          password: 'password',
          encryptionPassphrase: 'separate-encryption-passphrase',
        ),
        () => transport,
      ),
      throwsA(isA<KeystoreException>()),
    );

    // The keystore still holds the original key, so that is the key the file
    // has to be readable with. Leaving it under the uninstalled one would put
    // every credential out of reach of the next launch.
    final reopened = await AppServices.initialize(
        masterKeyManager: MasterKeyManager(keystore));
    addTearDown(() => reopened.probe.dispose());
    for (final secret in secrets) {
      expect((await reopened.vault.getSecret(secret.id))!.value, secret.value);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
  }

}
