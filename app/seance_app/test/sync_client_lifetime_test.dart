import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_app/services/app_services.dart';
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
}
