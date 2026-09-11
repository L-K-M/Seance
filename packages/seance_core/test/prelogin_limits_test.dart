import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  test('default prelogin work factors are accepted', () async {
    const params = Argon2Params();
    final salt = base64Encode(List<int>.filled(16, 0));
    final transport = MockClient((request) async => http.Response(
          jsonEncode({'argonSalt': salt, 'argonParams': params.toJson()}),
          HttpStatus.ok,
        ));
    addTearDown(transport.close);
    final client = HttpSyncClient(
      baseUrl: 'https://sync.test',
      client: transport,
    );

    final result = await client.prelogin('user');
    expect(result.argonSalt, salt);
    expect(result.argonParams.toJson(), params.toJson());
    expect(result.argonParams.meetsMinimum(Argon2Params.minimum), isTrue);
  });

  test('hostile prelogin work factors never reach key derivation', () async {
    final transport = MockClient((request) async {
      expect(request.url.path, '/v1/prelogin');
      return http.Response(
        jsonEncode({
          'argonSalt': base64Encode(List<int>.filled(16, 0)),
          'argonParams': const Argon2Params(iterations: 1000000).toJson(),
        }),
        HttpStatus.ok,
      );
    });
    addTearDown(transport.close);
    final client = HttpSyncClient(
      baseUrl: 'https://sync.test',
      client: transport,
    );
    await expectLater(client.prelogin('user'), throwsFormatException);
  });
}
