import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

const _url = 'https://example.com/team/snippets/raw/branch/main/snippets.json';
const _token = 'tok-3f9a1c';

String _file(List<Object?> snippets, {Object? version = 1}) =>
    jsonEncode({'version': version, 'snippets': snippets});

Map<String, Object?> _entry(String id, {String? title, String? body}) => {
  'id': id,
  'title': title ?? 'Title $id',
  'body': body ?? 'echo $id',
};

Matcher _failsWith(Object messageMatcher) => throwsA(
  isA<SnippetSourceException>().having(
    (e) => e.message,
    'message',
    messageMatcher,
  ),
);

void main() {
  group('SnippetSourceFile.parse', () {
    test('reads version-1 snippets in file order', () {
      final file = SnippetSourceFile.parse(
        _file([
          _entry('disk', title: 'Disk usage', body: 'du -sh {{path}}'),
          _entry('ports'),
        ]),
      );
      expect(file.skipped, 0);
      expect(file.snippets.map((s) => s.id), ['disk', 'ports']);
      expect(file.snippets.first.title, 'Disk usage');
      expect(file.snippets.first.placeholders, ['path']);
    });

    test('ignores unknown fields at both levels', () {
      final file = SnippetSourceFile.parse(
        jsonEncode({
          'version': 1,
          'generator': 'agent',
          'snippets': [
            {
              ..._entry('a'),
              'tags': ['x'],
              'danger': true,
            },
          ],
        }),
      );
      expect(file.snippets.single.id, 'a');
    });

    test('skips invalid entries and counts them', () {
      final file = SnippetSourceFile.parse(
        _file([
          _entry('good'),
          'not an object',
          {'id': 'no-body', 'title': 'x'},
          {'id': 3, 'title': 'x', 'body': 'y'},
          _entry('blank-title', title: '  '),
          _entry('blank-body', body: ' '),
          {'title': 'no id', 'body': 'ls'},
          _entry('good', title: 'duplicate id'),
        ]),
      );
      expect(file.snippets.map((s) => s.id), ['good']);
      expect(file.snippets.single.title, 'Title good');
      expect(file.skipped, 7);
    });

    test('an empty list is a valid, empty source', () {
      final file = SnippetSourceFile.parse(_file([]));
      expect(file.snippets, isEmpty);
      expect(file.skipped, 0);
    });

    test('rejects a wrong version', () {
      expect(
        () => SnippetSourceFile.parse(_file([_entry('a')], version: 2)),
        _failsWith(contains('Unsupported format version 2')),
      );
      expect(
        () => SnippetSourceFile.parse(_file([_entry('a')], version: '1')),
        _failsWith(contains('Unsupported format version "1"')),
      );
      expect(
        () => SnippetSourceFile.parse(jsonEncode({'snippets': []})),
        _failsWith(contains('no "version"')),
      );
    });

    test('rejects malformed files', () {
      expect(
        () => SnippetSourceFile.parse('{"version": 1, "snippets": ['),
        _failsWith('The file is not valid JSON.'),
      );
      expect(
        () => SnippetSourceFile.parse('[1, 2]'),
        _failsWith(contains('Expected a JSON object')),
      );
      expect(
        () => SnippetSourceFile.parse(jsonEncode({'version': 1})),
        _failsWith('"snippets" must be a list.'),
      );
      expect(
        () => SnippetSourceFile.parse('<html>Sign in</html>'),
        _failsWith('The file is not valid JSON.'),
      );
    });
  });

  group('validateSnippetSourceUrl', () {
    test('accepts https and loopback http', () {
      expect(validateSnippetSourceUrl(_url), isNull);
      expect(validateSnippetSourceUrl('  $_url  '), isNull);
      expect(validateSnippetSourceUrl('http://localhost:8080/s.json'), isNull);
      expect(validateSnippetSourceUrl('http://127.0.0.1/s.json'), isNull);
      expect(validateSnippetSourceUrl('http://[::1]:9/s.json'), isNull);
    });

    test('refuses plain http elsewhere, other schemes and non-URLs', () {
      for (final url in [
        'http://example.com/s.json',
        'http://localhost.example.com/s.json',
        'ftp://example.com/s.json',
        'file:///etc/passwd',
        'example.com/s.json',
        '',
      ]) {
        expect(validateSnippetSourceUrl(url), isNotNull, reason: url);
      }
    });

    test('refuses credentials embedded in the URL', () {
      expect(
        validateSnippetSourceUrl('https://user:secret@example.com/s.json'),
        contains('token field'),
      );
    });
  });

  group('SnippetSourceFetcher', () {
    late List<http.BaseRequest> requests;
    setUp(() => requests = []);

    SnippetSourceFetcher fetcher(
      Future<http.Response> Function(http.Request request) handler, {
      Duration timeout = SnippetSourceFetcher.defaultTimeout,
      int maxBytes = SnippetSourceFetcher.defaultMaxBytes,
    }) => SnippetSourceFetcher(
      client: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
      timeout: timeout,
      maxBytes: maxBytes,
    );

    test('fetches and parses, sending the token as a bearer header', () async {
      final file = await fetcher(
        (_) async => http.Response(_file([_entry('a')]), 200),
      ).fetch(_url, token: _token);

      expect(file.snippets.single.id, 'a');
      expect(requests.single.url.toString(), _url);
      expect(requests.single.headers['Authorization'], 'Bearer $_token');
      expect(requests.single.followRedirects, isFalse);
    });

    test('sends no Authorization header without a token', () async {
      for (final token in [null, '', '   ']) {
        requests.clear();
        await fetcher(
          (_) async => http.Response(_file([]), 200),
        ).fetch(_url, token: token);
        expect(
          requests.single.headers.containsKey('Authorization'),
          isFalse,
          reason: 'token: "$token"',
        );
      }
    });

    test('reports HTTP errors without the token or the body', () async {
      for (final (status, expected) in [
        (401, 'Check the access token'),
        (403, 'Check the access token'),
        (404, 'Not found (HTTP 404)'),
        (500, 'The server answered HTTP 500.'),
      ]) {
        final call = fetcher(
          (_) async => http.Response('secret page $_token', status),
        ).fetch(_url, token: _token);
        await expectLater(
          call,
          _failsWith(
            allOf(
              contains(expected),
              isNot(contains(_token)),
              isNot(contains('example.com')),
            ),
          ),
        );
      }
    });

    test('says a token is needed when access is denied without one', () {
      expect(
        fetcher((_) async => http.Response('', 401)).fetch(_url),
        _failsWith(contains('needs an access token')),
      );
    });

    test('times out a server that never answers', () async {
      final never = Completer<http.Response>();
      await expectLater(
        fetcher(
          (_) => never.future,
          timeout: const Duration(milliseconds: 50),
        ).fetch(_url, token: _token),
        _failsWith(startsWith('Timed out')),
      );
    });

    test('times out a body that stalls', () async {
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      body.add(utf8.encode('{"version": 1, '));
      final stalled = SnippetSourceFetcher(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(body.stream, 200),
        ),
        timeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        stalled.fetch(_url),
        _failsWith(startsWith('Timed out')),
      );
    });

    test('refuses an oversized file by its declared length', () {
      expect(
        fetcher(
          (_) async => http.Response('x' * 2048, 200),
          maxBytes: 1024,
        ).fetch(_url),
        _failsWith(contains('larger than 1 KB')),
      );
    });

    test('refuses an oversized file that declares no length', () async {
      final chunks = StreamController<List<int>>();
      final big = SnippetSourceFetcher(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(chunks.stream, 200),
        ),
        maxBytes: 1024,
      );
      final result = big.fetch(_url);
      for (var i = 0; i < 4; i++) {
        chunks.add(List.filled(512, 0x20));
      }
      await expectLater(result, _failsWith(contains('larger than 1 KB')));
      expect(chunks.hasListener, isFalse, reason: 'the download is cancelled');
      await chunks.close();
    });

    test('reports bad JSON and a wrong version from the server', () async {
      await expectLater(
        fetcher((_) async => http.Response('<html></html>', 200)).fetch(_url),
        _failsWith('The file is not valid JSON.'),
      );
      await expectLater(
        fetcher(
          (_) async => http.Response(_file([], version: 7), 200),
        ).fetch(_url),
        _failsWith(contains('Unsupported format version 7')),
      );
    });

    test('recognizes a sign-in page served in place of the file', () async {
      // What Forgejo does for a private raw URL fetched without a token:
      // 303 to its login page, which answers 200 with HTML.
      final call = fetcher((request) async {
        if (request.url.path == '/user/login') {
          return http.Response(
            '<html>Sign in</html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        return http.Response('', 303, headers: {'location': '/user/login'});
      }).fetch(_url);
      await expectLater(
        call,
        _failsWith(
          allOf(contains('sign-in page'), contains('need an access token')),
        ),
      );
    });

    test('refuses a URL the validator refuses, before any request', () async {
      await expectLater(
        fetcher(
          (_) async => http.Response(_file([]), 200),
        ).fetch('http://example.com/s.json', token: _token),
        _failsWith(contains('https://')),
      );
      expect(requests, isEmpty);
    });

    test('follows a same-origin redirect with the token', () async {
      final file = await fetcher((request) async {
        if (request.url.path.endsWith('/old.json')) {
          return http.Response('', 302, headers: {'location': '/new.json'});
        }
        return http.Response(_file([_entry('moved')]), 200);
      }).fetch('https://example.com/old.json', token: _token);

      expect(file.snippets.single.id, 'moved');
      expect(requests.map((r) => r.headers['Authorization']), [
        'Bearer $_token',
        'Bearer $_token',
      ]);
    });

    test('drops the token on a redirect to another host', () async {
      await fetcher((request) async {
        if (request.url.host == 'example.com') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://cdn.example.net/s.json'},
          );
        }
        return http.Response(_file([]), 200);
      }).fetch(_url, token: _token);

      expect(requests.last.url.host, 'cdn.example.net');
      expect(requests.last.headers.containsKey('Authorization'), isFalse);
    });

    test('refuses a redirect to plain http', () async {
      await expectLater(
        fetcher(
          (_) async => http.Response(
            '',
            301,
            headers: {'location': 'http://example.com/s.json'},
          ),
        ).fetch(_url, token: _token),
        _failsWith(contains('redirected')),
      );
      expect(requests, hasLength(1));
    });

    test('gives up on a redirect loop', () async {
      await expectLater(
        fetcher(
          (_) async =>
              http.Response('', 302, headers: {'location': '/again.json'}),
        ).fetch(_url),
        _failsWith('Too many redirects.'),
      );
    });

    test('names only the host when the connection fails', () async {
      await expectLater(
        fetcher(
          (request) async =>
              throw http.ClientException('boom $_token', request.url),
        ).fetch('$_url?private_token=$_token', token: _token),
        _failsWith('Could not reach example.com.'),
      );
    });
  });
}
