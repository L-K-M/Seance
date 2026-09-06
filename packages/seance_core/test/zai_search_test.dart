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

  /// Handshakes served, so each `initialize` can hand out a *different* id.
  ///
  /// The real gateway mints a fresh one per handshake. Re-issuing the same
  /// constant let a client that re-initializes correctly but keeps sending
  /// the retired id pass the re-handshake tests — which is exactly the
  /// production failure they exist to simulate.
  int _handshakes = 0;
  String? get _issuedSessionId => sessionId == null
      ? null
      : (_handshakes > 1 ? 'session-$_handshakes' : sessionId);

  /// Replies substituted for a method, by name (a gateway envelope, an error).
  final Map<String, Map<String, dynamic>> overrides = {};

  /// Answer 404 to this many `tools/call`s, as a retired session id does.
  int expireSession = 0;

  /// Tag each result link with the query it answered, so racing callers can
  /// be told apart: the same reply handed to both would be wrong for one.
  bool echoQueryInLinks = false;

  /// Hold every error status's body open forever. A gateway that answers
  /// 4xx and then stalls is the shape the error drains' deadline exists for.
  bool stallErrorBodies = false;

  /// Drop the connection mid-body on every error status, as a gateway that
  /// resets after sending its status line does.
  bool resetErrorBodies = false;

  /// The `cursor` each `tools/list` asked for, so a test can prove the client
  /// echoes `nextCursor` rather than re-listing blind — which this fake's
  /// page counter alone cannot tell apart.
  final List<Object?> listCursors = [];

  FakeMcpServer({
    this.sse = false,
    this.noise = false,
    this.sessionId = 'session-1',
  });

  http.Client get client => MockClient.streaming((request, body) async {
        // Kept for this request rather than read back as `headers.last`
        // below: the body read that follows is an await, and a concurrent
        // request can append its own headers before this one resumes. The
        // three records are appended together after that await, so
        // `methods`, `headers` and `requests` share one ordering.
        final sent = <String, String>{
          // Lowercased: HTTP header names are case-insensitive, so a client
          // that capitalized one would otherwise fail as a null deep inside
          // this fake rather than as the expectation that meant to catch it.
          for (final entry in request.headers.entries)
            entry.key.toLowerCase(): entry.value,
        };
        final payload =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        final method = payload['method'] as String;
        requests.add(request);
        headers.add(sent);
        methods.add(method);

        if (method == 'initialize') _handshakes++;

        if (expireSession > 0 && method == 'tools/call') {
          expireSession--;
          return _stream(404, '');
        }
        // A retired id answers 404, like the gateway does — so a client that
        // re-handshakes but keeps sending the old id fails here rather than
        // silently passing.
        // Every request after the handshake, as the gateway does: a client
        // that re-initializes but keeps the retired id on its notification or
        // listing would otherwise pass half the re-handshake conversation.
        if (method != 'initialize' &&
            sent['mcp-session-id'] != _issuedSessionId) {
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
        listCursors.add((payload['params'] as Map?)?['cursor']);
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
        var reply = _results;
        if (echoQueryInLinks) {
          final query = lastArguments?.entries
              .where((e) => e.key.contains('query') && e.value is String)
              .map((e) => e.value as String)
              .firstOrNull;
          reply = {
            'search_result': [
              for (final r in _results['search_result'] as List)
                {...r as Map, 'link': '${r['link']}?q=$query'},
            ],
          };
        }
        return {
          'content': [
            {'type': 'text', 'text': jsonEncode(reply)},
          ],
        };
      default:
        return const {};
    }
  }

  http.StreamedResponse _stream(int status, String body) {
    final text = sse && body.isNotEmpty ? _asSse(body) : body;
    return http.StreamedResponse(
      status >= 400 && stallErrorBodies
          ? StreamController<List<int>>().stream
          : status >= 400 && resetErrorBodies
              ? Stream<List<int>>.error(http.ClientException('reset'))
              : Stream.value(utf8.encode(text)),
      status,
      headers: {
        'content-type': sse && body.isNotEmpty
            ? 'text/event-stream'
            : 'application/json',
        if (_issuedSessionId != null) 'mcp-session-id': _issuedSessionId!,
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
      // The no-`limit` shape, pinned too: `count` is the interface's default
      // of five, sent as a number — not omitted, and never a null.
      expect(server.lastArguments, {
        'search_query': 'again',
        'count': 5,
        'search_engine': 'search-prime',
      });

      expect(server.methods, [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/call',
        // The handshake is cached: the second search is one request.
        'tools/call',
      ]);
      // Every request, not just the handshake: the gateway authenticates each
      // POST independently, and the header is built by spreading `...headers`
      // over a literal, so a session map that ever gained an `authorization`
      // key would silently override the bearer token.
      expect(
        server.headers.map((h) => h['authorization']).toSet(),
        {'Bearer zai-key'},
      );
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
      // On every post-handshake request, not only the last: the entries
      // after the handshake's three are the two tools/call requests.
      expect(
        server.headers.skip(3).map((h) => h['mcp-protocol-version']).toSet(),
        {'2025-06-18'},
      );
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

    test('two searches racing the first handshake share it', () async {
      // `_ensureHandshake` caches the *Future*, not its result, so a second
      // caller arriving before the first has finished awaits the same
      // attempt. Only ever asserted sequentially before, which the classic
      // racing implementation (`_session ??= await …`) also passes.
      final server = FakeMcpServer()..echoQueryInLinks = true;
      final search = ZaiSearch(apiKey: 'k', client: server.client);

      final results = await Future.wait([
        search.search('dart'),
        search.search('flutter'),
      ]);

      expect(results, everyElement(isNotEmpty));
      expect(server.methods.where((m) => m == 'initialize').length, 1);
      // Sharing the handshake must not coalesce the searches: the two
      // queries are different, so one answer handed to both callers would be
      // wrong for one of them — which two calls alone would not show, so
      // each caller's links carry the query it asked.
      expect(server.methods.where((m) => m == 'tools/call').length, 2);
      expect(results[0].map((r) => r.url), everyElement(contains('q=dart')));
      expect(
          results[1].map((r) => r.url), everyElement(contains('q=flutter')));
    });

    test('a burst of expiries costs one re-handshake, not one each', () async {
      // Every caller sharing a retired session sees the same 404. Without the
      // guard in `_reset`, the first installs a fresh attempt and the second
      // nulls that still-in-flight one to start another — N handshakes and N
      // abandoned server-side sessions for one expiry.
      final server = FakeMcpServer()..expireSession = 3;
      final search = ZaiSearch(apiKey: 'k', client: server.client);

      final results = await Future.wait([
        search.search('a'),
        search.search('b'),
        search.search('c'),
      ]);

      expect(results, everyElement(isNotEmpty));
      // One for the original session, one for the shared replacement.
      expect(server.methods.where((m) => m == 'initialize').length, 2);
    });

    test('a listing that never stops paginating says so', () async {
      // Searching the truncated list instead would report "no search tool…
      // needs a GLM Coding Plan" — an entitlement accusation for a transport
      // fault, sending the user to check their plan and key.
      final server = FakeMcpServer()
        ..extraToolPages = ZaiSearch.maxToolPages + 5;
      final search = ZaiSearch(apiKey: 'k', client: server.client);

      await expectLater(
        search.search('dart'),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('kept paginating'),
          ),
        ),
      );
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
      // Three listings is what a cursor-blind client produces too; the pages
      // are handed out by count. Only the cursors sent back tell them apart.
      expect(server.listCursors, [null, 'cursor-1', 'cursor-2']);
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
        // A sentence, not "Future not completed": the deadline reaches the
        // UI, so it says what happened like every other failure here does.
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('stopped sending'),
          ),
        ),
      );
    });

    test('a 4xx whose body stalls is still reported as that status', () async {
      // The drain after an error status is deadlined, and its own
      // TimeoutException was escaping — "Future not completed" in place of
      // the status line that had already said what went wrong.
      final stalled = StreamController<List<int>>();
      addTearDown(stalled.close);
      final client = MockClient.streaming((request, body) async =>
          http.StreamedResponse(stalled.stream, 502));
      await expectLater(
        ZaiSearch(
          apiKey: 'k',
          client: client,
          timeout: const Duration(milliseconds: 50),
        ).search('dart'),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 502'),
          ),
        ),
      );
    });

    test('a retired session whose 404 body stalls is still retried', () async {
      // Same drain on the 404 branch, where the escaping TimeoutException
      // displaced the session-expiry signal — so the one re-handshake that
      // branch exists to trigger never ran.
      final server = FakeMcpServer()
        ..expireSession = 1
        ..stallErrorBodies = true;
      final results = await ZaiSearch(
        apiKey: 'k',
        client: server.client,
        timeout: const Duration(milliseconds: 50),
      ).search('dart');
      expect(results, isNotEmpty);
      expect(server.methods.where((m) => m == 'initialize').length, 2);
    });

    test('a retired session whose 404 body resets is still retried', () async {
      // The drain on that branch swallowed only its own deadline; a
      // connection dropped mid-body raised a transport error past it, and
      // that displaced the session-expiry signal exactly as the deadline
      // used to.
      final server = FakeMcpServer()
        ..expireSession = 1
        ..resetErrorBodies = true;
      final results =
          await ZaiSearch(apiKey: 'k', client: server.client).search('dart');
      expect(results, isNotEmpty);
      expect(server.methods.where((m) => m == 'initialize').length, 2);
    });

    test('a search after a double expiry starts with a fresh handshake',
        () async {
      // The replacement session was retired too, and the gateway said so.
      // Kept, the next call would send it, eat the 404 and only then start
      // over — one round trip spent on a session already known to be dead.
      final server = FakeMcpServer()..expireSession = 2;
      final search = ZaiSearch(apiKey: 'k', client: server.client);
      await expectLater(
        search.search('dart'),
        throwsA(isA<http.ClientException>()),
      );
      expect(await search.search('dart'), isNotEmpty);
      // The original, the retry's replacement, and a fresh one afterwards.
      expect(server.methods.where((m) => m == 'initialize').length, 3);
    });

    test('a notification whose stream never closes is a named failure',
        () async {
      // No status speaks for this one: the gateway answered 200 and held the
      // stream. It is a failure of its own, and reaches the UI as a sentence.
      final stalled = StreamController<List<int>>();
      addTearDown(stalled.close);
      final client = MockClient.streaming((request, body) async {
        final payload =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        if (payload.containsKey('id')) {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({
              'jsonrpc': '2.0',
              'id': payload['id'],
              'result': {'protocolVersion': '2025-06-18'},
            }))),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.StreamedResponse(
          stalled.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      await expectLater(
        ZaiSearch(
          apiKey: 'k',
          client: client,
          timeout: const Duration(milliseconds: 50),
        ).search('dart'),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('held the search stream open'),
          ),
        ),
      );
    });

    test('a 202 that holds an event stream open is cancelled, not waited out',
        () async {
      // 202 is the reply the protocol owes a notification, with no body. A
      // server that holds an event stream open past it is owed nothing
      // either; drained to its deadline instead, every handshake would have
      // paid a full timeout at the notification step.
      final server = FakeMcpServer();
      var cancelled = false;
      final held = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      addTearDown(held.close);
      final client = MockClient.streaming((request, body) async {
        final bytes = await body.toBytes();
        final payload = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (!payload.containsKey('id')) {
          return http.StreamedResponse(
            held.stream,
            202,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        final forwarded = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = bytes;
        return server.client.send(forwarded);
      });

      final clock = Stopwatch()..start();
      final results = await ZaiSearch(
        apiKey: 'k',
        client: client,
        timeout: const Duration(seconds: 3),
      ).search('dart');

      expect(results, isNotEmpty);
      expect(cancelled, isTrue);
      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
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

  group('parseToolResult shapes', () {
    test('a non-web link does not hide the usable url beside it', () {
      final results = ZaiSearch.parseToolResult({
        'content': [
          {
            'type': 'text',
            'text': jsonEncode({
              'search_result': [
                {
                  'title': 'Relative',
                  'link': '/relative',
                  'url': 'https://example.com/x',
                  'content': 'text',
                },
              ],
            }),
          },
        ],
      }, 5);
      expect(results.map((r) => r.url), ['https://example.com/x']);
    });

    test('a duplicate result is a leaf, not a container to walk', () {
      // The first copy is a leaf; the second used to fall through to the
      // entry walk, so a `content` that happened to be JSON decoded into a
      // result of its own — and only from the duplicate.
      final results = ZaiSearch.parseToolResult({
        'content': [
          {
            'type': 'text',
            'text': jsonEncode({
              'search_result': [
                {
                  'title': 'Once',
                  'link': 'https://example.com/a',
                  'content': 'text',
                },
                {
                  'title': 'Again',
                  'link': 'https://example.com/a',
                  'content': jsonEncode({
                    'title': 'Planted',
                    'link': 'https://example.com/planted',
                    'content': 'x',
                  }),
                },
              ],
            }),
          },
        ],
      }, 5);
      expect(results.map((r) => r.url), ['https://example.com/a']);
    });

    test('a localized title object is read, like a localized snippet', () {
      final results = ZaiSearch.parseToolResult({
        'content': [
          {
            'type': 'text',
            'text': jsonEncode({
              'search_result': [
                {
                  'title': {'lang': 'en', 'text': 'Real title'},
                  'link': 'https://example.com/t',
                  'content': 'text',
                },
              ],
            }),
          },
        ],
      }, 5);
      expect(results.single.title, 'Real title');
    });
  });

  group('readRpcResult', () {
    test('a JSON-RPC error names its code and nothing else', () {
      // The number tells a method-not-found from bad params; the server's
      // own text stays out, like every other message here.
      expect(
        () => ZaiSearch.readRpcResult({
          'jsonrpc': '2.0',
          'id': 7,
          'error': {'code': -32601, 'message': 'secret server prose'},
        }, method: 'tools/call', id: 7),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          allOf(contains('(code -32601)'), isNot(contains('secret'))),
        )),
      );
      // No code, no parenthesis; an error that is not even a map, the same.
      for (final error in [const <String, Object>{}, 'down', 1]) {
        expect(
          () => ZaiSearch.readRpcResult({
            'jsonrpc': '2.0',
            'id': 7,
            'error': error,
          }, method: 'tools/call', id: 7),
          throwsA(isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            allOf(isNot(contains('(code')), isNotEmpty),
          )),
        );
      }
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

    test('a required parameter\'s name is echoed bounded', () {
      // The name is the gateway's to choose and the message reaches the UI.
      final name = 'p' * 500;
      expect(
        () => ZaiSearch.buildArguments({
          'properties': {name: const {'type': 'string'}},
          'required': [name],
        }, 'dart', 5),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message.length,
          'message length',
          lessThan(160),
        )),
      );
    });

    test('the echoed name is not cut between the halves of an emoji', () {
      final name = '${'p' * 47}😀tail';
      expect(
        () => ZaiSearch.buildArguments({
          'properties': {name: const {'type': 'string'}},
          'required': [name],
        }, 'dart', 5),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          // Any lone surrogate, not only one followed by the ellipsis: a cut
          // on raw code units that appended nothing would leave one at the
          // end, and U+FFFD only appears once such a string is encoded.
          predicate<String>(
            (m) =>
                !m.contains('\uFFFD') &&
                !m.runes.any((r) => r >= 0xD800 && r <= 0xDFFF),
            'free of replacement characters and unpaired surrogates',
          ),
        )),
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
      // localized object for `title`; interpolating either puts `{en: A}`
      // into a result a person reads. The text inside is read out instead —
      // the list joined, the object's strings taken — and a title that
      // yields nothing that way falls back to the media name, then the URL.
      final results = ZaiSearch.parseToolResult(const {
        'content': [
          {
            'type': 'text',
            'text': '[{"link":"https://a.example","title":{"en":"A"},'
                '"content":["one","two",3]},'
                '{"link":"https://b.example","title":{"en":7}}]',
          },
        ],
      }, 5);
      expect(results.first.title, 'A');
      expect(results.first.snippet, 'one two');
      expect(results.last.title, 'https://b.example');
    });

    test('an empty link falls back to the url beside it', () {
      // `link ?? url` keeps the empty string, the isNotEmpty guard then fails,
      // and the result is dropped even though a usable URL was right there.
      final results = ZaiSearch.parseToolResult(const {
        'structuredContent': {
          'results': [
            {'link': '', 'url': 'https://a.example', 'title': 'A'},
            {'link': null, 'url': 'https://b.example', 'title': 'B'},
            {'link': 42, 'url': 'https://c.example', 'title': 'C'},
          ],
        },
      }, 5);
      expect(
        results.map((r) => r.url),
        ['https://a.example', 'https://b.example', 'https://c.example'],
      );
    });

    test('an empty title falls back to the media name', () {
      // `??` only handles null, so an explicitly empty title kept the empty
      // string and rendered the raw URL with a usable name beside it — the
      // same trap `link` was already fixed for two lines up.
      final results = ZaiSearch.parseToolResult(const {
        'structuredContent': {
          'results': [
            {'link': 'https://a.example', 'title': '', 'media': 'Example News'},
            {'link': 'https://b.example', 'title': 42, 'media': 'Fallback'},
          ],
        },
      }, 5);
      expect(results.map((r) => r.title), ['Example News', 'Fallback']);
    });

    test('a localized snippet object is read, not dropped', () {
      // The shape the comment beside it names. The list case is already
      // joined, so returning '' for a map was an asymmetry rather than a
      // policy — it vanished the whole snippet for the payload this walk
      // exists to survive.
      final results = ZaiSearch.parseToolResult(const {
        'structuredContent': {
          'results': [
            {
              'link': 'https://a.example',
              'title': 'A',
              'content': {'lang': 'en', 'text': 'hello'},
            },
          ],
        },
      }, 5);
      // The tag is for the client, not the reader.
      expect(results.single.snippet, 'hello');
    });

    test('only http(s) URLs with a host become results', () {
      // These strings are the gateway's, and a search result is a web page by
      // definition — so anything else is either not a result or a scheme
      // someone would like this app to launch.
      final results = ZaiSearch.parseToolResult(const {
        'structuredContent': {
          'results': [
            {'link': 'javascript:alert(1)', 'title': 'x'},
            {'link': 'data:text/html,<script>', 'title': 'x'},
            {'link': 'file:///etc/passwd', 'title': 'x'},
            {'link': 'https:no-host', 'title': 'x'},
            {'link': 'https://', 'title': 'x'},
            {'link': 'https://ok.example/page', 'title': 'ok'},
          ],
        },
      }, 10);
      expect(results.map((r) => r.url), ['https://ok.example/page']);
    });

    test('a payload nested past any real shape is walked, not crashed', () {
      // Server-controlled, and StackOverflowError is an Error — it would sail
      // past the `on Exception` handling every caller of this class relies on.
      var nested = <String, Object?>{'link': 'https://deep.example'};
      for (var i = 0; i < 100000; i++) {
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

      // Any cap in [600, 1800) tells the two strategies apart: counting
      // bytes trips at 1200 on the second chunk, counting decoded units only
      // ever reaches 600. A cap of 500 was tripped by both.
      await expectLater(
        ZaiSearch.bounded(source(), 1000, const Duration(seconds: 1)).toList(),
        throwsA(isA<http.ClientException>()),
      );
      await expectLater(
        ZaiSearch.bounded(source(), 5000, const Duration(seconds: 1)).toList(),
        completion(hasLength(3)),
      );
    });

    test('a stream that trickles past the deadline is cut off too', () async {
      // Every chunk resets the idle deadline, so a proxy feeding heartbeats
      // forever never trips it; the overall deadline is checked as each
      // chunk arrives, thrown into the stream so ending the loop cancels the
      // subscription — the leak a `.timeout` on the awaited future left.
      var cancelled = false;
      late final Timer drip;
      final controller = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
          drip.cancel();
        },
      );
      drip = Timer.periodic(const Duration(milliseconds: 5), (_) {
        if (!controller.isClosed) controller.add(utf8.encode('.'));
      });

      await expectLater(
        ZaiSearch.bounded(
          controller.stream,
          1 << 20,
          const Duration(seconds: 1),
          total: const Duration(milliseconds: 40),
          totalMessage: 'held open',
          // Test-side only: a deadline that stopped being enforced would
          // otherwise hang this until the runner's own timeout.
        ).toList().timeout(const Duration(seconds: 5)),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          'held open',
        )),
      );
      expect(cancelled, isTrue);
      await controller.close();
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
        // Readable, like the byte cap's: both guards exist for the same
        // 200-then-stall case and both reach the UI, so neither surfaces as
        // "Future not completed".
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('stopped sending'),
          ),
        ),
      );
      expect(cancelled, isTrue);
      await controller.close();
    });
  });

  group('CompositeSearch', () {
    test('one page reported three ways is one result', () async {
      // Two indexes agreeing is one result. A trailing slash and a fragment
      // are the same page by any reading, and letting each take a slot makes
      // the merge look worse than it is.
      final results = await CompositeSearch([
        _Fixed([_hit('https://x.example/docs')]),
        _Fixed([_hit('https://x.example/docs/')]),
        _Fixed([_hit('https://x.example/docs#install')]),
      ]).search('q', limit: 5);
      expect(results.map((r) => r.url), ['https://x.example/docs']);
    });

    test('a slash inside a query value is data, not a trailing slash',
        () async {
      // `?next=/docs/` and `?next=/docs` are two different redirects; the
      // trailing-slash trim applies to a path, not to a query value.
      final results = await CompositeSearch([
        _Fixed([_hit('https://x.example/go?next=/docs/')]),
        _Fixed([_hit('https://x.example/go?next=/docs')]),
      ]).search('q', limit: 5);
      expect(results, hasLength(2));
    });

    test('an explicit default port is the same page', () async {
      // Pinned either way, so a normalization refactor changes this on
      // purpose: Dart's `Uri` drops an explicit `:443`.
      final results = await CompositeSearch([
        _Fixed([_hit('https://x.example/docs')]),
        _Fixed([_hit('https://x.example:443/docs')]),
      ]).search('q', limit: 5);
      expect(results, hasLength(1));
    });

    test('a query string is not a duplicate', () async {
      // Deliberately conservative: `?id=1` and `?id=2` are different pages,
      // so normalization stops at the fragment and trailing slashes.
      final results = await CompositeSearch([
        _Fixed([_hit('https://x.example/p?id=1')]),
        _Fixed([_hit('https://x.example/p?id=2')]),
      ]).search('q', limit: 5);
      expect(results, hasLength(2));
    });

    test('interleaves backends and drops duplicate URLs', () async {
      // Round-robin, not concatenation: a fast backend must not fill the whole
      // limit before a slower one is heard from.
      final results = await CompositeSearch([
        _Fixed([
          _hit('https://a'),
          _hit('https://b'),
          _hit('https://c'),
          // A fifth unique URL, so the deduped union exceeds the limit: with
          // exactly four, an implementation ignoring `limit` produced the
          // same expected list and truncation went untested.
          _hit('https://e'),
        ]),
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
      // The same object, not one with the same message: a merge loop that
      // caught and re-threw a copy would pass a message check.
      final error = http.ClientException('backend down');
      await expectLater(
        CompositeSearch([_Broken(error)]).search('q'),
        throwsA(same(error)),
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
