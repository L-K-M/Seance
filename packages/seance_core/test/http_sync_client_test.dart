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

  group('HttpSyncClient error surfaces', () {
    HttpSyncClient failingWith(String body, int status) => HttpSyncClient(
          baseUrl: 'https://host',
          client: MockClient((req) async => http.Response(body, status)),
        );

    test("the server's own JSON errors pass through untouched", () async {
      final sync = failingWith(
          jsonEncode({'error': 'registration_closed', 'message': 'Registration is disabled'}),
          403);
      await expectLater(
        sync.pull(since: 0),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'registration_closed')
            .having((e) => e.message, 'message', 'Registration is disabled')),
      );
    });

    test('a 502 (proxy could not reach the server) is explained, not echoed',
        () async {
      // Cloudflare-style plain-text body for API clients.
      final sync = failingWith('error code: 502', 502);
      await expectLater(
        sync.pull(since: 0),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'http_502')
            .having((e) => e.message, 'message',
                contains('could not reach the sync server'))),
      );
    });

    test('an HTML error page never reaches the UI as raw markup', () async {
      final sync = failingWith(
          '<html>\n<head><title>404 Not Found</title></head>\n'
          '<body><h1>Not Found</h1><hr><center>nginx</center></body>\n</html>',
          404);
      try {
        await sync.pull(since: 0);
        fail('expected an ApiError');
      } on ApiError catch (e) {
        expect(e.code, 'http_404');
        expect(e.message, isNot(contains('<')));
        expect(e.message, contains('404 Not Found'));
      }
    });

    test('a huge body is capped to a short snippet', () async {
      final sync = failingWith('x' * 5000, 500);
      try {
        await sync.pull(since: 0);
        fail('expected an ApiError');
      } on ApiError catch (e) {
        expect(e.code, 'http_500');
        expect(e.message.length, lessThan(220));
      }
    });

    test('a JSON body that is not an object still maps to http_<status>',
        () async {
      // jsonDecode succeeds here; the old cast-based path threw a TypeError.
      final sync = failingWith('"boom"', 500);
      await expectLater(
        sync.pull(since: 0),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'http_500')
            .having((e) => e.message, 'message', contains('boom'))),
      );
    });

    test('a JSON object without an error code is not mistaken for the server',
        () async {
      final sync = failingWith(jsonEncode({'detail': 'gateway exploded'}), 500);
      await expectLater(
        sync.pull(since: 0),
        throwsA(isA<ApiError>()
            .having((e) => e.code, 'code', 'http_500')
            .having((e) => e.message, 'message', contains('gateway exploded'))),
      );
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
