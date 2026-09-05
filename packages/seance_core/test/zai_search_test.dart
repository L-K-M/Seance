import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// The schema Z.AI advertises today: the query is `search_query`, the count is
/// `count`, and `search_engine` is required with a single accepted value.
const Map<String, dynamic> _schema = {
  'type': 'object',
  'properties': {
    'search_query': {'type': 'string'},
    'count': {'type': 'integer'},
    'search_engine': {
      'type': 'string',
      'enum': ['search-prime'],
    },
  },
  'required': ['search_query', 'search_engine'],
};

const Map<String, dynamic> _results = {
  'search_result': [
    {
      'title': 'Dart 3',
      'link': 'https://dart.dev/3',
      'content': 'A summary.',
      'icon': 'https://dart.dev/favicon.ico',
    },
    {
      'title': 'Records',
      'link': 'https://dart.dev/records',
      'content': 'Another summary.',
    },
  ],
};

/// A stand-in for the MCP endpoint. Records what it was asked, and can be told
/// to answer over SSE or to fail in each of the shapes the real gateway does.
class FakeMcpServer {
  final bool sse;

  /// Emit non-JSON events (a heartbeat, a bare `data:` line) alongside the
  /// real one — all legal SSE, none of them JSON-RPC.
  final bool noise;
  final String? sessionId;
  final List<String> methods = [];
  final List<Map<String, String>> headers = [];
  final List<http.BaseRequest> requests = [];

  /// Pages of extra tools to hand back before the real listing, to exercise
  /// `tools/list` pagination.
  int extraToolPages = 0;
  int _toolPagesServed = 0;
  Map<String, dynamic>? lastArguments;

  /// Replies substituted for a method, by name (a gateway envelope, an error).
  final Map<String, Map<String, dynamic>> overrides = {};

  /// Answer 404 to this many `tools/call`s, as a retired session id does.
  int expireSession = 0;

  FakeMcpServer({
    this.sse = false,
    this.noise = false,
    this.sessionId = 'session-1',
  });

  http.Client get client => MockClient.streaming((request, body) async {
        requests.add(request);
        headers.add({
          // Lowercased: HTTP header names are case-insensitive, so a client
          // that capitalized one would otherwise fail as a null deep inside
          // this fake rather than as the expectation that meant to catch it.
          for (final entry in request.headers.entries)
            entry.key.toLowerCase(): entry.value,
        });
        final payload =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        final method = payload['method'] as String;
        methods.add(method);

        if (expireSession > 0 && method == 'tools/call') {
          expireSession--;
          return _stream(404, '');
        }

        // A notification carries no id and gets no body back.
        if (!payload.containsKey('id')) return _stream(202, '');

        final id = payload['id'];
        final override = overrides[method];
        final message = override != null
            ? {...override, if (!override.containsKey('id')) 'id': id}
            : {'jsonrpc': '2.0', 'id': id, 'result': _result(method, payload)};
        return _stream(200, jsonEncode(message));
      });

  Map<String, dynamic> _result(String method, Map<String, dynamic> payload) {
    switch (method) {
      case 'initialize':
        return {'protocolVersion': '2025-06-18'};
      case 'tools/list':
        if (_toolPagesServed < extraToolPages) {
          _toolPagesServed++;
          return {
            'tools': [
              {'name': 'page_$_toolPagesServed', 'inputSchema': const {}},
            ],
            'nextCursor': 'cursor-$_toolPagesServed',
          };
        }
        return {
          'tools': [
            {'name': 'unrelated_tool', 'inputSchema': const {}},
            {'name': 'web_search_prime', 'inputSchema': _schema},
          ],
        };
      case 'tools/call':
        // Null-aware: MCP allows a tools/call with no arguments, and a hard
        // cast would crash inside this fake instead of failing the assertion
        // that is watching lastArguments.
        final params = payload['params'] as Map?;
        lastArguments = (params?['arguments'] as Map?)?.cast<String, dynamic>();
        return {
          'content': [
            {'type': 'text', 'text': jsonEncode(_results)},
          ],
        };
      default:
        return const {};
    }
  }

  http.StreamedResponse _stream(int status, String body) {
    final text = sse && body.isNotEmpty ? _asSse(body) : body;
    return http.StreamedResponse(
      Stream.value(utf8.encode(text)),
      status,
      headers: {
        'content-type': sse && body.isNotEmpty
            ? 'text/event-stream'
            : 'application/json',
        if (sessionId != null) 'mcp-session-id': sessionId!,
      },
    );
  }

  /// One event whose payload is pretty-printed, so its `data` really does
  /// span several lines that only parse joined — preceded by an unrelated
  /// notification the reader has to walk past rather than answer with.
  String _asSse(String body) {
    final pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
    final data = pretty.split('\n').map((line) => 'data: $line').join('\n');
    final heartbeat = noise
        ? ': keep-alive\n'
            '\n'
            'event: message\n'
            'data: ping\n'
            '\n'
            'event: message\n'
            'data:\n'
            '\n'
        : '';
    return '$heartbeat'
        'event: message\n'
        'data: {"jsonrpc":"2.0","method":"notifications/progress"}\n'
        '\n'
        'event: message\n'
        '$data\n'
        '\n';
  }
}

void main() {
  group('ZaiSearch over MCP', () {
    test('handshakes once, then searches', () async {
      final server = FakeMcpServer();
      final search = ZaiSearch(apiKey: 'zai-key', client: server.client);

      final first = await search.search('dart records', limit: 2);
      await search.search('again');

      expect(server.methods, [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/call',
        // The handshake is cached: the second search is one request.
        'tools/call',
      ]);
      expect(server.headers.first['authorization'], 'Bearer zai-key');
      // Every MCP message is a POST to the one endpoint. Without this, a
      // refactor that changed either would surface as an opaque crash inside
      // the fake rather than as a failed expectation.
      expect(server.requests.map((r) => r.method).toSet(), {'POST'});
      expect(
        server.requests.map((r) => r.url.toString()).toSet(),
        {ZaiSearch.defaultEndpoint},
      );
      expect(
        server.headers.first['content-type'],
        contains('application/json'),
      );
      // The version the *server* answered with, not the one we proposed, and
      // the session id it handed back in a header.
      expect(server.headers.last['mcp-protocol-version'], '2025-06-18');
      expect(server.headers.last['mcp-session-id'], 'session-1');

      expect(first.map((r) => r.url), [
        'https://dart.dev/3',
        'https://dart.dev/records',
      ]);
      expect(first.first.title, 'Dart 3');
      expect(first.first.snippet, 'A summary.');
    });

    test('sends the arguments the advertised schema asks for', () async {
      final server = FakeMcpServer();
      await ZaiSearch(apiKey: 'k', client: server.client)
          .search('dart records', limit: 3);

      expect(server.lastArguments, {
        'search_query': 'dart records',
        'count': 3,
        // Required, and never mentioned in this file's own code: it comes
        // from the schema's enum.
        'search_engine': 'search-prime',
      });
    });

    test('reads a reply that arrives as an event stream', () async {
      // Same conversation over text/event-stream, with the payload split
      // across two data: lines and an unrelated event in front of it.
      final server = FakeMcpServer(sse: true);
      final results =
          await ZaiSearch(apiKey: 'k', client: server.client).search('dart');
      expect(results.map((r) => r.url), contains('https://dart.dev/3'));
    });

    test('re-handshakes once when the session id has been retired', () async {
      final server = FakeMcpServer()..expireSession = 1;
      final results =
          await ZaiSearch(apiKey: 'k', client: server.client).search('dart');

      expect(results, isNotEmpty);
      // initialize, notify, list, (404), initialize, notify, list, call.
      expect(server.methods.where((m) => m == 'initialize').length, 2);
      expect(server.methods.last, 'tools/call');
    });

    test('a session that keeps dropping fails readably, not privately',
        () async {
      // Retrying forever would spend the user's quota on a wall, and the
      // internal marker must never reach a caller.
      final server = FakeMcpServer()..expireSession = 5;
      await expectLater(
        ZaiSearch(apiKey: 'k', client: server.client).search('dart'),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('dropping the search session'),
          ),
        ),
      );
      expect(server.methods.where((m) => m == 'initialize').length, 2);
    });

    test('a rejected key says so instead of naming the quota', () async {
      final server = FakeMcpServer();
      server.overrides['initialize'] = {
        'success': false,
        'code': 1002,
        'msg': 'Invalid API key',
      };
      final search = ZaiSearch(apiKey: 'bad', client: server.client);

      await expectLater(
        search.search('dart'),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('rejected the search API key'),
          ),
        ),
      );
    });

    test('a failed handshake is retried rather than cached', () async {
      // Caching the failed future would leave the instance permanently broken
      // after one blip, and the app keeps one per chat session.
      final server = FakeMcpServer();
      server.overrides['tools/list'] = {
        'jsonrpc': '2.0',
        'error': {'code': -32603, 'message': 'internal'},
      };
      final search = ZaiSearch(apiKey: 'k', client: server.client);

      await expectLater(
        search.search('dart'),
        throwsA(isA<http.ClientException>()),
      );
      server.overrides.clear();
      expect(await search.search('dart'), isNotEmpty);
    });

    test('an HTTP failure never quotes the body back', () async {
      // The gateway can echo the request — Authorization header included — in
      // an error page, and this string reaches the UI.
      final client = MockClient.streaming((request, body) async =>
          http.StreamedResponse(
            Stream.value(utf8.encode('Bearer zai-secret was rejected')),
            502,
          ));
      await expectLater(
        ZaiSearch(apiKey: 'zai-secret', client: client).search('dart'),
        throwsA(
          isA<http.ClientException>()
              .having((e) => e.message, 'message', contains('HTTP 502'))
              .having((e) => e.message, 'message', isNot(contains('secret'))),
        ),
      );
    });

    test('a paginated tool listing is walked to the end', () async {
      // MCP paginates tool listings; a search tool on page two must still be
      // found rather than reported as "no web search tool".
      final server = FakeMcpServer()..extraToolPages = 2;
      final results =
          await ZaiSearch(apiKey: 'k', client: server.client).search('dart');

      expect(results, isNotEmpty);
      expect(server.methods.where((m) => m == 'tools/list').length, 3);
    });

    test('a non-JSON event in the stream is walked past, not fatal', () async {
      // Heartbeats, banners and a bare `data:` line are all legal SSE. One of
      // them must not turn a recoverable stream into a raw FormatException.
      final server = FakeMcpServer(sse: true, noise: true);
      final results =
          await ZaiSearch(apiKey: 'k', client: server.client).search('dart');
      expect(results.map((r) => r.url), contains('https://dart.dev/3'));
    });

    test('a 200 that is not JSON fails like any other bad reply', () async {
      // A gateway answering with an HTML error page is the same failure as a
      // reply of the wrong shape, and deserves the same error type.
      final client = MockClient.streaming((request, body) async =>
          http.StreamedResponse(
            Stream.value(utf8.encode('<html>gateway error</html>')),
            200,
            headers: {'content-type': 'text/html'},
          ));
      await expectLater(
        ZaiSearch(apiKey: 'k', client: client).search('dart'),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('unexpected search reply'),
          ),
        ),
      );
    });

    test('a stalled body times out instead of hanging', () async {
      // send() resolves when the *headers* arrive. Streamable HTTP lets a
      // server hold the stream open, so a proxy that answers 200 and then
      // says nothing would otherwise wedge the caller for good.
      final stalled = StreamController<List<int>>();
      addTearDown(stalled.close);
      final client = MockClient.streaming((request, body) async =>
          http.StreamedResponse(
            stalled.stream,
            200,
            headers: {'content-type': 'application/json'},
          ));
      await expectLater(
        ZaiSearch(
          apiKey: 'k',
          client: client,
          timeout: const Duration(milliseconds: 50),
        ).search('dart'),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('an errored tool result is a failure, not an empty answer', () async {
      final server = FakeMcpServer();
      server.overrides['tools/call'] = {
        'jsonrpc': '2.0',
        'result': {
          'isError': true,
          'content': [
            {'type': 'text', 'text': 'quota exceeded'},
          ],
        },
      };
      await expectLater(
        ZaiSearch(apiKey: 'k', client: server.client).search('dart'),
        throwsA(
          // The tool's own words, unlike a transport body: this is the only
          // place that says *which* of key, plan and quota is the problem.
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('quota exceeded'),
          ),
        ),
      );
    });

    test('a server with no search tool says what is missing', () async {
      final server = FakeMcpServer();
      server.overrides['tools/list'] = {
        'jsonrpc': '2.0',
        'result': {
          'tools': [
            {'name': 'unrelated_tool', 'inputSchema': const {}},
          ],
        },
      };
      await expectLater(
        ZaiSearch(apiKey: 'k', client: server.client).search('dart'),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('Coding Plan'),
          ),
        ),
      );
    });
  });

  group('buildArguments', () {
    test('uses whichever names the schema declares', () {
      expect(
        ZaiSearch.buildArguments(const {
          'properties': {
            'query': {'type': 'string'},
            'limit': {'type': 'integer'},
          },
        }, 'dart', 4),
        {'query': 'dart', 'limit': 4},
      );
    });

    test('fills a required parameter from its default', () {
      expect(
        ZaiSearch.buildArguments(const {
          'properties': {
            'search_query': {'type': 'string'},
            'search_engine': {'type': 'string', 'default': 'search-prime'},
          },
          'required': ['search_query', 'search_engine'],
        }, 'dart', 5),
        {'search_query': 'dart', 'search_engine': 'search-prime'},
      );
    });

    test('refuses to guess a required parameter it cannot fill', () {
      // Guessing would spend a search to get an answer to a different question.
      expect(
        () => ZaiSearch.buildArguments(const {
          'properties': {
            'search_query': {'type': 'string'},
            'tenant': {'type': 'string'},
          },
          'required': ['search_query', 'tenant'],
        }, 'dart', 5),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('a tool with no query parameter is not a search tool', () {
      expect(
        () => ZaiSearch.buildArguments(const {'properties': {}}, 'dart', 5),
        throwsA(isA<http.ClientException>()),
      );
    });
  });

  group('parseToolResult', () {
    test('a title or snippet that is not text does not reach the UI', () {
      // Some search APIs return `content` as a list of paragraphs, or a
      // localized object for `title`; interpolating either puts `{lang: en}`
      // into a result a person reads.
      final results = ZaiSearch.parseToolResult(const {
        'content': [
          {
            'type': 'text',
            'text': '[{"link":"https://a.example","title":{"en":"A"},'
                '"content":["one","two",3]}]',
          },
        ],
      }, 5);
      expect(results.single.title, 'https://a.example');
      expect(results.single.snippet, 'one two');
    });

    test('a payload nested past any real shape is walked, not crashed', () {
      // Server-controlled, and StackOverflowError is an Error — it would sail
      // past the `on Exception` handling every caller of this class relies on.
      var nested = <String, Object?>{'link': 'https://deep.example'};
      for (var i = 0; i < 5000; i++) {
        nested = <String, Object?>{'a': nested};
      }
      expect(() => ZaiSearch.parseToolResult({'structuredContent': nested}, 5),
          returnsNormally);
    });

    test('walks into a text block that holds JSON, skipping icons', () {
      final results = ZaiSearch.parseToolResult({
        'content': [
          {'type': 'text', 'text': jsonEncode(_results)},
        ],
      }, 5);
      expect(results, hasLength(2));
      // The favicon is a URL and not a result; walking into it would fill the
      // list with icons.
      expect(
        results.map((r) => r.url),
        isNot(contains('https://dart.dev/favicon.ico')),
      );
    });

    test('honours the limit and drops repeats', () {
      final results = ZaiSearch.parseToolResult({
        'structuredContent': {
          'search_result': [
            {'title': 'a', 'link': 'https://x', 'content': '1'},
            {'title': 'a again', 'link': 'https://x', 'content': '2'},
            {'title': 'b', 'link': 'https://y', 'content': '3'},
          ],
        },
      }, 2);
      // Two slots and three raw items, one of them a repeat. Asked with a
      // limit of 1 this could not tell "dedupe then limit" from "limit then
      // dedupe"; at 2 it can — the duplicate must not eat a slot 'y' should
      // have had.
      expect(results.map((r) => r.url), ['https://x', 'https://y']);
    });

    test('prose is returned rather than silently dropped', () {
      // The assistant is handed this as context; an empty list would throw
      // away an answer the search did find.
      final results = ZaiSearch.parseToolResult(const {
        'content': [
          {'type': 'text', 'text': 'Dart 3 was released in May 2023.'},
        ],
      }, 5);
      expect(results, hasLength(1));
      expect(results.single.snippet, contains('May 2023'));
      expect(results.single.url, isEmpty);
    });

    test('an empty result is empty, not a blank row', () {
      expect(ZaiSearch.parseToolResult(const {'content': []}, 5), isEmpty);
    });
  });

  group('bounded', () {
    test('caps on bytes, not on decoded length', () async {
      // One CJK character is three UTF-8 bytes and a single code unit, so a
      // count taken after decoding is three times too generous for exactly
      // the results this endpoint returns.
      final chunk = utf8.encode('検索' * 100); // 600 bytes, 200 code units.
      Stream<List<int>> source() =>
          Stream.fromIterable(List.generate(3, (_) => chunk));

      expect(
        ZaiSearch.bounded(source(), 500, const Duration(seconds: 1)).toList(),
        throwsA(isA<http.ClientException>()),
      );
      await expectLater(
        ZaiSearch.bounded(source(), 5000, const Duration(seconds: 1)).toList(),
        completion(hasLength(3)),
      );
    });

    test('a stream that stalls is cut off rather than held open', () async {
      // The deadline lives here so ending the loop cancels the subscription;
      // as a `.timeout` on the awaited future it would free the caller and
      // leave the socket listening.
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      controller.add(utf8.encode('first'));

      await expectLater(
        ZaiSearch.bounded(
          controller.stream,
          1024,
          const Duration(milliseconds: 20),
        ).toList(),
        throwsA(isA<TimeoutException>()),
      );
      expect(cancelled, isTrue);
    });
  });

  group('CompositeSearch', () {
    test('interleaves backends and drops duplicate URLs', () async {
      // Round-robin, not concatenation: a fast backend must not fill the whole
      // limit before a slower one is heard from.
      final results = await CompositeSearch([
        _Fixed([_hit('https://a'), _hit('https://b'), _hit('https://c')]),
        _Fixed([_hit('https://b'), _hit('https://d')]),
      ]).search('q', limit: 4);

      // Rank 0 from each backend, then rank 1 — where the second backend's
      // repeat of "b" is skipped, so its "d" takes that slot.
      expect(
        results.map((r) => r.url),
        ['https://a', 'https://b', 'https://d', 'https://c'],
      );
    });

    test('one backend failing does not take the search with it', () async {
      final results = await CompositeSearch([
        _Broken(),
        _Fixed([_hit('https://a')]),
      ]).search('q');
      expect(results.map((r) => r.url), ['https://a']);

      // Any backend error is contained, not only the transport ones: a parse
      // failure in one backend is no more the others' problem.
      expect(
        await CompositeSearch([
          _Broken(const FormatException('bad payload')),
          _Fixed([_hit('https://a')]),
        ]).search('q'),
        isNotEmpty,
      );
    });

    test('the raised failure keeps the backend it came from', () async {
      // Rethrowing the bare object would point the stack at the merge loop
      // instead of at the backend that failed, in exactly the case this
      // branch exists to make legible.
      await expectLater(
        CompositeSearch([_Broken()]).search('q'),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            'backend down',
          ),
        ),
      );
    });

    test('all backends failing is an error, not an empty answer', () async {
      // "Nothing found" is a different answer, and a misleading one when the
      // real problem is a wrong key.
      await expectLater(
        CompositeSearch([_Broken(), _Broken()]).search('q'),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('no backends at all is simply nothing to search', () async {
      expect(await const CompositeSearch([]).search('q'), isEmpty);
    });
  });
}

SearchResult _hit(String url) =>
    SearchResult(title: url, url: url, snippet: '');

class _Fixed implements SearchProvider {
  final List<SearchResult> results;
  _Fixed(this.results);
  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async =>
      results.take(limit).toList();
}

class _Broken implements SearchProvider {
  final Object? error;
  _Broken([this.error]);

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async =>
      throw error ?? http.ClientException('backend down');
}
