import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  group('HttpSyncClient URL handling', () {
    test('tolerates a trailing slash in the base URL', () async {
      Uri? seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response(jsonEncode({'token': 't'}), 200);
      });
      final sync = HttpSyncClient(
          baseUrl: 'https://seance.example.ch/', client: client);
      await sync.login(
          const LoginRequest(username: 'u', authVerifier: 'v'));
      expect(seen, Uri.parse('https://seance.example.ch/v1/login'));
    });

    test('trims whitespace and repeated slashes', () {
      final sync = HttpSyncClient(baseUrl: ' https://host// ');
      expect(sync.baseUrl, 'https://host');
    });

    test('leaves a clean base URL untouched', () {
      final sync = HttpSyncClient(baseUrl: 'http://localhost:8080');
      expect(sync.baseUrl, 'http://localhost:8080');
    });
  });

  group('HttpSyncClient timeout', () {
    test('a hung request times out instead of hanging forever', () async {
      final client = MockClient((req) async {
        // Never responds within the client's timeout.
        await Future<void>.delayed(const Duration(seconds: 5));
        return http.Response('{}', 200);
      });
      final sync = HttpSyncClient(
        baseUrl: 'https://host',
        client: client,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        sync.pull(since: 0),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
