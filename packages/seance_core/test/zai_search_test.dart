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

  /// A `nextCursor` of the wrong type, to exercise the malformed-reply guard.
  Object? malformedCursor;
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
      // Derived from the configured base rather than a literal, so a test
      // that injects its own id gets a replacement anchored to it instead of
      // a `session-2` that looks like a client bug when the 404s start.
      : (_handshakes > 1 ? '$sessionId-$_handshakes' : sessionId);

  /// Replies substituted for a method, by name (a gateway envelope, an error).
  final Map<String, Map<String, dynamic>> overrides = {};

  /// Answer 404 to this many `tools/call`s, as a retired session id does.
  ///
  /// Every `tools/call` while the count stands, whichever session id it
  /// carries — including one from a re-handshake that has already happened.
  /// That is what `a session that keeps dropping` is built on: a gateway
  /// whose sessions die faster than the client can replace them, which the
  /// retry limit has to give up on rather than spin against. A countdown that
  /// only drained on the retired id could not express it.
  int expireSession = 0;

  /// The id the first [expireSession] 404 invalidated.
  ///
  /// A gateway retires an id for good. Without this the countdown ends and
  /// the id is *un*-retired: the check below compares against
  /// [_issuedSessionId], which has not moved because no re-handshake
  /// happened, so a client that answers the 404 by resending the same id gets
  /// a 200 on the next attempt and passes every expiry test that does not
  /// independently count `initialize`s.
  String? _retiredId;

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
    this.streamCase = false,
  }) : assert(
          !noise || sse || streamCase,
          // `noise` is only read inside `_asSse`, which only runs for an SSE
          // reply — so on its own it produces a fake identical to the default
          // one, and a test written to prove the reader walks past a heartbeat
          // would pass having sent none.
          'noise only shapes SSE replies: pass sse or streamCase with it',
        );

  /// Answer every reply as SSE typed `Text/Event-Stream`, which is the same
  /// media type spelled the way RFC 9110 allows and this client once misread.
  final bool streamCase;

  // `late final`, not a getter: a getter mints a fresh `MockClient` on every
  // read, so two reads of `server.client` hand out different objects that
  // only coincidentally share this fake's recording state. Nothing does that
  // today; the contract "server.client is *the* client talking to this fake"
  // is worth being true rather than observed.
  late final http.Client client = MockClient.streaming((request, body) async {
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
        final Object? decoded;
        try {
          decoded = jsonDecode(await body.bytesToString());
        } on FormatException {
          // Like the lowercased headers and the null-aware params below: a
          // client bug should fail as an expectation, not as a crash deep
          // inside this fake.
          throw StateError('ZaiSearch sent a non-JSON body to ${request.url}');
        }
        if (decoded is! Map<String, dynamic>) {
          throw StateError('ZaiSearch sent a non-object body: $decoded');
        }
        final payload = decoded;
        final Object? named = payload['method'];
        if (named is! String) {
          // Named like the guards above: a client bug should fail as an
          // expectation, not as a cast error deep inside this fake.
          throw StateError(
              'ZaiSearch sent a JSON-RPC message with no method to '
              '${request.url}');
        }
        final method = named;
        requests.add(request);
        headers.add(sent);
        methods.add(method);

        if (method == 'initialize') {
          _handshakes++;
          // A fresh session lists from page one again, as the gateway does.
          // Left running, a re-handshake's `tools/list` would land straight on
          // the final page, and any test combining an expiry with paging
          // could not tell a client that re-paginates from one that skips.
          _toolPagesServed = 0;
          // And the one field MCP requires the *client* to propose. The
          // guards above fail a malformed request as an expectation rather
          // than as a mysterious result; this is the same, for the handshake
          // the real gateway would reject. Nothing else in this file checks
          // it — the version every later request sends is echoed from the
          // server's reply, so a client that proposed none would pass.
          final initParams = payload['params'];
          if (initParams is! Map || initParams['protocolVersion'] is! String) {
            throw StateError(
                'initialize proposed no protocolVersion to ${request.url}');
          }
        }

        if (expireSession > 0 && method == 'tools/call') {
          _retiredId ??= _issuedSessionId;
          expireSession--;
          return _stream(404, '');
        }
        // Dead for good, not for the length of the countdown: see [_retiredId].
        if (method != 'initialize' &&
            _retiredId != null &&
            sent['mcp-session-id'] == _retiredId) {
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
        // `capabilities` is part of a real initialize result; carried so a
        // client that starts reading it meets the shape here first.
        return {'protocolVersion': '2025-06-18', 'capabilities': const {}};
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
          if (malformedCursor != null) 'nextCursor': malformedCursor,
        };
      case 'tools/call':
        // Null-aware: MCP allows a tools/call with no arguments, and a hard
        // cast would crash inside this fake instead of failing the assertion
        // that is watching lastArguments.
        final params = payload['params'] as Map?;
        // The listing deliberately puts `unrelated_tool` first: a client that
        // took the first tool, or matched on a prefix, must fail here rather
        // than be handed a well-formed answer for the wrong tool.
        if (params?['name'] != 'web_search_prime') {
          return {
            'isError': true,
            'content': [
              {'type': 'text', 'text': "no such tool: '${params?['name']}'"},
            ],
          };
        }
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
    final streaming = (sse || streamCase) && body.isNotEmpty;
    final text = streaming ? _asSse(body) : body;
    return http.StreamedResponse(
      status >= 400 && stallErrorBodies
          // A stream that never emits and never ends, said as itself: the
          // `StreamController` this used to be was dropped on the floor
          // unclosed, and a reader tidying that leak away with a `close()`
          // would have ended the stall and quietly disarmed the
          // drain-deadline tests this flag exists to drive.
          ? Stream<List<int>>.fromFuture(Completer<List<int>>().future)
          : status >= 400 && resetErrorBodies
              ? Stream<List<int>>.error(http.ClientException('reset'))
              : Stream.value(utf8.encode(text)),
      status,
      headers: {
        'content-type': streaming
            ? (streamCase ? 'Text/Event-Stream' : 'text/event-stream')
            : 'application/json',
        // Not on an error status: the gateway does not re-issue the id on a
        // 404, and a client that recovered one by scraping any response would
        // pass every re-handshake test here while failing in production.
        if (status < 400 && _issuedSessionId != null)
          'mcp-session-id': _issuedSessionId!,
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
      // `5 == 5.0` under num equality, and jsonDecode keeps the difference:
      // the schema says integer, so the wire type is pinned too.
      expect(server.lastArguments?['count'], isA<int>());

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
        // Every request, not just the handshake's: the fake does not check
        // it, so a regression that sent `text/plain` on `tools/call` would
        // otherwise pass the whole file.
        server.headers.map((h) => h['content-type']),
        everyElement(contains('application/json')),
      );
      // The version the *server* answered with, not the one we proposed, and
      // the session id it handed back in a header.
      // On every request after `initialize`, not only the last: the
      // notification, the listing and both tools/call requests all carry
      // the negotiated version.
      expect(
        server.headers.skip(1).map((h) => h['mcp-protocol-version']).toSet(),
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
      expect(server.lastArguments?['count'], isA<int>());
    });

    test('reads a reply that arrives as an event stream', () async {
      // Same conversation over text/event-stream, with the payload split
      // across two data: lines and an unrelated event in front of it.
      final server = FakeMcpServer(sse: true);
      final results = await ZaiSearch(apiKey: 'k', client: server.client)
          .search('dart')
          // Test-side only, like the racing tests': a reset that awaited
          // itself would hang here rather than fail the expectations below.
          .timeout(const Duration(seconds: 5));
      expect(results.map((r) => r.url), contains('https://dart.dev/3'));
    });

    test('re-handshakes once when the session id has been retired', () async {
      final server = FakeMcpServer()..expireSession = 1;
      final results = await ZaiSearch(apiKey: 'k', client: server.client)
          .search('dart')
          // Test-side only, like both neighbours': this drives the same
          // `_reset` path, and a deadlock in it should fail here rather than
          // stall the suite until the runner's own timeout.
          .timeout(const Duration(seconds: 5));

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
        ZaiSearch(apiKey: 'k', client: server.client)
            .search('dart')
            // Test-side only, like the racing tests': a retry loop that spun
            // would stall the suite rather than fail this expectation.
            .timeout(const Duration(seconds: 5)),
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
      // Test-side only, like the drain tests': a cache that ended up awaiting
      // itself would otherwise hang here until the runner's own timeout,
      // reported as a generic 30-second stall rather than this deadlock.
      ]).timeout(const Duration(seconds: 5));

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
      final server = FakeMcpServer()
        ..expireSession = 3
        ..echoQueryInLinks = true;
      final search = ZaiSearch(apiKey: 'k', client: server.client);

      final results = await Future.wait([
        search.search('a'),
        search.search('b'),
        search.search('c'),
      ]).timeout(const Duration(seconds: 5));

      expect(results, everyElement(isNotEmpty));
      // Shared handshake, separate calls: a guard that shared the retried
      // `tools/call` future as well would hand every caller the first one's
      // answer, with the handshake and call counts below unchanged. Each
      // caller's own query has to come back to it.
      expect(results[0].map((r) => r.url), everyElement(contains('q=a')));
      expect(results[1].map((r) => r.url), everyElement(contains('q=b')));
      expect(results[2].map((r) => r.url), everyElement(contains('q=c')));
      // One for the original session, one for the shared replacement.
      expect(server.methods.where((m) => m == 'initialize').length, 2);
      // And the call count the comment above leans on, which was never
      // actually asserted: three that met the retired session, three retries
      // after the shared re-handshake. A caller that inherited another's
      // retried call, or sent its own twice, leaves the initialize count and
      // the per-query echoes intact.
      expect(server.methods.where((m) => m == 'tools/call').length, 6);
    });

    test('a cursor of the wrong type is a malformed reply, not an ending',
        () async {
      // Read as "no more pages", a wrong-typed cursor ended the walk with the
      // listing truncated — and left no cursor for the pagination guard to
      // trip, so the search tool went missing and the user was told to check
      // their Coding Plan. That is the plan accusation for a transport fault
      // that the guard beside it exists to prevent.
      final server = FakeMcpServer()..malformedCursor = 3;

      await expectLater(
        ZaiSearch(apiKey: 'k', client: server.client).search('dart'),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('unexpected search reply'),
            isNot(contains('Coding Plan')),
          ),
        )),
      );
    });

    test('a listing that never stops paginating says so', () async {
      // Searching the truncated list instead would report "no search tool…
      // needs a GLM Coding Plan" — an entitlement accusation for a transport
      // fault, sending the user to check their plan and key.
      final server = FakeMcpServer()
        ..extraToolPages = ZaiSearch.maxToolPages + 5;
      final search = ZaiSearch(apiKey: 'k', client: server.client);

      await expectLater(
        // Test-side only, like the other loop tests': a pagination cap that
        // regressed into an unbounded walk should fail here rather than stall
        // the runner until its own generic timeout, where nothing says which
        // test was responsible.
        search.search('dart').timeout(const Duration(seconds: 5)),
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
      // Both spellings of the same rejection, like the quota loop below: a
      // gateway writes "api key" or "apikey" as it pleases, and either has to
      // reach the message that names the key rather than the one that lists
      // three things to check.
      for (final msg in ['Invalid API key', 'wrong apikey', 'Unauthorized']) {
        final server = FakeMcpServer();
        server.overrides['initialize'] = {
          'success': false,
          'code': 1002,
          'msg': msg,
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
          reason: msg,
        );
      }
    });

    test('a quota phrasing without a quota word is not blamed on the key',
        () async {
      // "tokens exhausted" carries "token" and none of quota/limit/balance/
      // insufficient, so the auth branch claimed it: someone with a working
      // key sent to rotate it, which is the confusion the quota test in front
      // of that branch exists to prevent.
      for (final msg in [
        'Tokens exhausted',
        'Token budget depleted',
        'Token budget exceeded',
      ]) {
        final server = FakeMcpServer();
        server.overrides['initialize'] = {
          'success': false,
          'code': 1113,
          'msg': msg,
        };

        await expectLater(
          ZaiSearch(apiKey: 'good', client: server.client).search('dart'),
          throwsA(
            isA<http.ClientException>()
                .having((e) => e.message, 'message',
                    isNot(contains('rejected the search API key')))
                // The generic message, which names all three possibilities
                // rather than picking the wrong one.
                .having((e) => e.message, 'message', contains('quota')),
          ),
          reason: '"$msg" is a quota failure, not a key failure',
        );
      }
    });

    test('a transport 429 says it is temporary, not a bare status', () async {
      // The gateway's own throttling reply is classified by `readRpcResult`;
      // this is the transport-level twin, from the gateway or anything in
      // front of it. It used to fall into the catch-all and read "Z.AI
      // search error HTTP 429", which says nothing about a failure that
      // clears itself.
      final client = MockClient.streaming((request, body) async =>
          http.StreamedResponse(Stream.value(utf8.encode('slow down')), 429));

      await expectLater(
        ZaiSearch(apiKey: 'k', client: client).search('dart'),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('try the search again'),
            isNot(contains('HTTP 429')),
            // And not the body, like every other status branch here.
            isNot(contains('slow down')),
          ),
        )),
      );
    });

    test('a 429 that says when passes the wait on; one that does not, does '
        'not', () async {
      // The header is the only thing in the reply that answers "when", and
      // the message and its caller both ask. Its other legal form is an
      // HTTP-date, which has to fall back rather than invent a delay — a
      // parse that reached for the leading digits would read `Wed, 21 Oct`
      // as "try again in 21 seconds".
      Future<String> messageFor(Map<String, String> headers) async {
        final client = MockClient.streaming(
          (request, body) async => http.StreamedResponse(
            Stream.value(utf8.encode('slow down')),
            429,
            headers: headers,
          ),
        );
        try {
          await ZaiSearch(apiKey: 'k', client: client).search('dart');
        } on http.ClientException catch (e) {
          return e.message;
        }
        return fail('a 429 should not answer with results');
      }

      expect(
        await messageFor({'retry-after': ' 30 '}),
        contains('try the search again in 30 seconds'),
      );
      expect(
        await messageFor({'retry-after': 'Wed, 21 Oct 2026 07:28:00 GMT'}),
        allOf(
          contains('try the search again.'),
          isNot(contains('21')),
          isNot(contains('seconds')),
        ),
      );
      expect(
        await messageFor(const {}),
        allOf(contains('try the search again.'), isNot(contains('seconds'))),
      );
    });

    test('an untrimmed key still redacts itself out of a tool error',
        () async {
      // The reason the constructor trims, and it is not cosmetic. A key
      // pasted with the newline its password manager appended went into the
      // `Authorization` header verbatim *and* became the needle the
      // tool-error branch redacts with — and the gateway echoes back the key
      // it actually parsed, without the newline. `replaceAll` then matched
      // nothing and the error message carried the key into the UI and the
      // log.
      final server = FakeMcpServer();
      server.overrides['tools/call'] = {
        'jsonrpc': '2.0',
        'result': {
          'isError': true,
          'content': [
            {'type': 'text', 'text': 'bad key: sk-secret'},
          ],
        },
      };
      await expectLater(
        ZaiSearch(apiKey: 'sk-secret\n', client: server.client).search('dart'),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          allOf(contains('[redacted]'), isNot(contains('sk-secret'))),
        )),
      );
    });

    test('throttling is blamed on neither the key nor the plan', () async {
      // Three spellings of one self-clearing failure. "rate limit exceeded"
      // sets the quota veto twice over and landed on the generic "check the
      // key, Coding Plan access, and quota"; the other two carry `token` or
      // `api key` and landed on the key message. All three sent a user to
      // fix something that is working and will clear itself.
      for (final msg in [
        'Rate limit exceeded for this account',
        'Too many requests for this api key',
        'Request throttled: token bucket empty',
      ]) {
        final server = FakeMcpServer();
        server.overrides['initialize'] = {
          'success': false,
          'code': 1002,
          'msg': msg,
        };

        await expectLater(
          ZaiSearch(apiKey: 'good', client: server.client).search('dart'),
          throwsA(
            isA<http.ClientException>().having(
              (e) => e.message,
              'message',
              allOf(
                isNot(contains('rejected the search API key')),
                isNot(contains('Coding Plan')),
                contains('try the search again'),
              ),
            ),
          ),
          reason: '"$msg" is throttling, not a bad key or an exhausted plan',
        );
      }
    });

    test('a transient failure is blamed on neither the key nor the plan',
        () async {
      // gRPC-shaped gateways say "deadline exceeded" and "timeout" for a
      // failure a retry fixes. The first two carry an auth word beside the
      // transient one and the third carries `token`, so without the veto each
      // reaches "rejected the search API key" and sends a user with a working
      // key to Settings for a wall that would have cleared itself.
      //
      // `exceeded` is not what this pins: a message that reads as quota
      // already lands on the generic text, so vetoing the quota reading —
      // where this veto first went — was a no-op there and reopened the key
      // message here.
      for (final msg in [
        'Auth deadline exceeded',
        'Unauthorized: upstream timeout',
        'Token validation timeout',
      ]) {
        final server = FakeMcpServer();
        server.overrides['initialize'] = {
          'success': false,
          'code': 1002,
          'msg': msg,
        };

        await expectLater(
          ZaiSearch(apiKey: 'good', client: server.client).search('dart'),
          throwsA(
            isA<http.ClientException>().having(
              (e) => e.message,
              'message',
              // Both halves. Pinned only on the absence, a regression that
              // moved these into the generic "check the key, Coding Plan
              // access, and quota" bucket — which still lists the key first —
              // would pass while giving the same wrong advice by another
              // route.
              allOf(
                isNot(contains('rejected the search API key')),
                isNot(contains('Coding Plan')),
                contains('try the search again'),
              ),
            ),
          ),
          reason: '"$msg" is a timeout, not a rejected key',
        );
      }
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
        // Test-side belt and braces only: this body is a `Stream.value`, so
        // it completes under any reading strategy and no drain deadline is
        // reached here. The stalled- and reset-body tests are what exercise
        // that deadline.
      ).timeout(const Duration(seconds: 5));
    });

    test('a rejected key is named as such whatever shape the refusal takes',
        () async {
      // The gateway's own rejection is a 200 carrying `{"success": false}`,
      // which `readRpcResult` names. A plain 401 or 403 — anything else in
      // front of the endpoint — is the same failure, and "HTTP 401" leaves
      // the user with nothing to act on.
      //
      // The two do not say the same thing, though: a 403 from this gateway is
      // as often a valid key without Web Search Prime, and re-checking a
      // working key is advice that cannot help. What both must do is name
      // something actionable and never echo the request.
      for (final status in [401, 403]) {
        final actionable = status == 401 ? 'Check the key' : 'Coding Plan';
        final client = MockClient.streaming((request, body) async =>
            http.StreamedResponse(
              Stream.value(utf8.encode('Bearer zai-secret was rejected')),
              status,
            ));
        await expectLater(
          ZaiSearch(apiKey: 'zai-secret', client: client).search('dart'),
          throwsA(
            isA<http.ClientException>()
                .having((e) => e.message, 'message', contains(actionable))
                .having((e) => e.message, 'message', isNot(contains('secret'))),
            ),
          reason: 'HTTP $status should name "$actionable"',
          // The same guard the stall tests carry: this drives the same
          // non-2xx body drain, so a regressed deadline would hang the loop
          // rather than fail it.
        ).timeout(const Duration(seconds: 5));
      }
    });

    test('a content type the server spelled differently is still a stream',
        () async {
      // Media types are case-insensitive; a reply typed `Text/Event-Stream`
      // was read as a JSON body and failed as an unexpected reply.
      final server = FakeMcpServer(streamCase: true);
      final results =
          await ZaiSearch(apiKey: 'k', client: server.client).search('dart');
      expect(results, isNotEmpty);
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
      // Not passed, and not an arrow either: `close()` on an unlistened
      // single-subscription controller never completes, and package:test
      // awaits whatever a teardown *returns* — which `() => close()` does,
      // making it the same thing as passing `close` itself. A block body
      // returns nothing, so a failed assertion here fails, rather than
      // wedging the runner until its own timeout hides it.
      addTearDown(() {
        unawaited(stalled.close());
      });
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
        // Test-side only, like its siblings below: a deadline that stopped
        // being enforced would hang this on a controller nothing closes,
        // until the runner's own timeout rather than at the assertion.
      ).timeout(const Duration(seconds: 5));
    });

    test('an error status whose body stalls is still reported as that status',
        () async {
      // The drain after an error status is deadlined, and its own
      // TimeoutException was escaping — "Future not completed" in place of
      // the status line that had already said what went wrong.
      final stalled = StreamController<List<int>>();
      // Not passed, and not an arrow either: `close()` on an unlistened
      // single-subscription controller never completes, and package:test
      // awaits whatever a teardown *returns* — which `() => close()` does,
      // making it the same thing as passing `close` itself. A block body
      // returns nothing, so a failed assertion here fails, rather than
      // wedging the runner until its own timeout hides it.
      addTearDown(() {
        unawaited(stalled.close());
      });
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
        // Like its siblings: the drain deadline is what ends this, and a
        // regression in it would hang until the runner's own timeout.
      ).timeout(const Duration(seconds: 5));
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
        // Test-side, like its siblings: a drain deadline that stopped being
        // enforced would hang until the runner's own timeout.
      ).search('dart').timeout(const Duration(seconds: 5));
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
      // And the listings, which are what tell the two readings apart. A client
      // that kept the dead session would send it, eat a fourth 404 and only
      // then handshake — same three `initialize` calls, same result, one more
      // doomed listing. Two in the first search, one in the second.
      expect(server.methods.where((m) => m == 'tools/list').length, 3);
    });

    test('a notification whose stream never closes is a named failure',
        () async {
      // No status speaks for this one: the gateway answered 200 and held the
      // stream. It is a failure of its own, and reaches the UI as a sentence.
      var stalledCancelled = false;
      final stalled = StreamController<List<int>>(
        onCancel: () => stalledCancelled = true,
      );
      // Not passed, and not an arrow either: `close()` on an unlistened
      // single-subscription controller never completes, and package:test
      // awaits whatever a teardown *returns* — which `() => close()` does,
      // making it the same thing as passing `close` itself. A block body
      // returns nothing, so a failed assertion here fails, rather than
      // wedging the runner until its own timeout hides it.
      addTearDown(() {
        unawaited(stalled.close());
      });
      // The guard below only saw id-bearing payloads, so the other half of
      // the reorder space — a notification sent before `initialize` — matched
      // no branch and passed with the same message.
      var initialized = false;
      final client = MockClient.streaming((request, body) async {
        final payload =
            jsonDecode(await body.bytesToString()) as Map<String, dynamic>;
        if (payload['method'] == 'initialize') {
          initialized = true;
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
        // Anything else means the client reordered the handshake, and this
        // test's stall would then be reported as "no web search tool" —
        // pointing at the wrong layer entirely.
        if (!initialized) {
          fail('${payload['method']} was sent before initialize');
        }
        if (payload.containsKey('id')) {
          fail('unexpected ${payload['method']} before the notification');
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
        // Test-side only, like the trickle test's: a deadline that stopped
        // being enforced would hang this until the runner's own timeout.
      ).timeout(const Duration(seconds: 5));
      // Failed, and let go of: the deadline is thrown into the stream, so
      // the subscription — and the socket behind it — is cancelled with it.
      expect(stalledCancelled, isTrue);
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
      // Block body, for the reason spelled out on the stalled-body teardowns
      // above: an arrow returns the future and package:test awaits it.
      addTearDown(() {
        unawaited(held.close());
      });
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

      // Named once and used for both the deadline and the bound below: two
      // literals a comment apart can be tuned one at a time, and lowering the
      // deadline alone would let a drain-to-deadline regression finish inside
      // the bound and pass.
      const deadline = Duration(seconds: 3);
      final clock = Stopwatch()..start();
      final results = await ZaiSearch(
        apiKey: 'k',
        client: client,
        timeout: deadline,
      ).search('dart').timeout(const Duration(seconds: 5));

      expect(results, isNotEmpty);
      expect(cancelled, isTrue);
      // Draining instead of cancelling costs the whole `deadline`, while the
      // passing path is in-process mock I/O costing whatever the runner is
      // doing — so any bound meaningfully below the deadline tells the two
      // apart, and three quarters leaves a loaded container room. Relative,
      // so tuning the deadline down tightens this with it. Parenthesised
      // because `*` and `~/` only associate left by luck of equal precedence,
      // and a clarifying `deadline * (3 ~/ 4)` would be zero — a bound
      // nothing can satisfy, since `clock.elapsed` is never below zero, so
      // the check would fail on every run rather than pass on every run.
      // (Written the other way round here last round, which had it exactly
      // backwards.)
      expect(clock.elapsed, lessThan((deadline * 3) ~/ 4));
    });

    test('an over-long tool error is clipped without splitting a character',
        () async {
      // The quoted prose is capped because a server that answers an error
      // with its whole corpus should not put it in a sentence — and it is
      // free text from a search engine, so an emoji lands astride the cut
      // about as often as anything else. A bare `substring` strands the high
      // half of the pair, which renders as a replacement character and is
      // mangled on its way into a log.
      final server = FakeMcpServer();
      server.overrides['tools/call'] = {
        'jsonrpc': '2.0',
        'result': {
          'isError': true,
          'content': [
            {'type': 'text', 'text': '${'a' * 511}\u{1F600} and more'},
          ],
        },
      };
      await expectLater(
        ZaiSearch(apiKey: 'k', client: server.client).search('dart'),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            // 511, not 512: the cut lands on the pair, so the clip steps back
            // off it rather than through it.
            'Z.AI search failed: ${'a' * 511}…',
          ),
        ),
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

    test('a double-encoded payload is decoded again, not dropped', () {
      // A tool that JSON-encodes its payload and then puts *that* string in
      // the text block — `json.dumps` applied twice, a common enough MCP
      // wart. The block decodes to a String, which the walk used to drop on
      // the spot: the results were lost whole and the caller fell through to
      // the prose path, which reports a JSON blob or nothing. Each re-entry
      // still counts against the depth cap, and prose that is not JSON stops
      // at the first `FormatException` as it always did.
      final results = ZaiSearch.parseToolResult({
        'content': [
          {
            'type': 'text',
            'text': jsonEncode(jsonEncode({
              'search_result': [
                {
                  'title': 'Wrapped twice',
                  'link': 'https://example.com/deep',
                  'content': 'text',
                },
              ],
            })),
          },
        ],
      }, 5);
      expect(results.map((r) => r.url), ['https://example.com/deep']);
      expect(results.single.title, 'Wrapped twice');
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

    test('an empty content of any shape does not hide the snippet beside it',
        () {
      // `??` answers for null alone, so an explicitly empty list or map was
      // kept and joined to nothing — the fall-through the string case had.
      for (final empty in [
        <Object?>[],
        <String, Object?>{},
        <Object?>[1, 2],
        true,
        '',
      ]) {
        final results = ZaiSearch.parseToolResult({
          'content': [
            {
              'type': 'text',
              'text': jsonEncode({
                'search_result': [
                  {
                    'title': 'T',
                    'link': 'https://example.com/e',
                    'content': empty,
                    'snippet': 'the real one',
                  },
                ],
              }),
            },
          ],
        }, 5);
        expect(results.single.snippet, 'the real one',
            reason: 'content: $empty should fall through');
      }
    });

    test('prose answers nothing when nothing was asked for', () {
      // The link path takes none when asked for none; prose answering anyway
      // would be a different count for the same ask.
      const prose = {
        'content': [
          {'type': 'text', 'text': 'just words, no links'},
        ],
      };
      expect(ZaiSearch.parseToolResult(prose, 0), isEmpty);
      expect(ZaiSearch.parseToolResult(prose, 1), hasLength(1));
    });

    test('a JSON container with no usable links answers nothing, not itself',
        () {
      // `_collect` decodes a text block that is JSON and walks it, so a
      // container holding no link-shaped entry leaves nothing found. The
      // prose fallback then used to join the *same* text back as an answer:
      // a synthetic "Z.AI web search" result whose snippet is raw JSON,
      // handed to the model and rendered in the UI. "Nothing found" is an
      // empty list.
      expect(
        ZaiSearch.parseToolResult({
          'content': [
            {'type': 'text', 'text': '{"results": []}'},
          ],
        }, 5),
        isEmpty,
      );
      // And the container is dropped rather than the whole fallback: real
      // prose beside it still answers, without the JSON glued onto it.
      final mixed = ZaiSearch.parseToolResult({
        'content': [
          {'type': 'text', 'text': '{"results": []}'},
          {'type': 'text', 'text': 'No matches for that query.'},
        ],
      }, 5);
      expect(mixed, hasLength(1));
      expect(mixed.single.snippet, 'No matches for that query.');
    });

    test('a list of localized parts is text, not nothing', () {
      // The list arm filtered with `whereType<String>()`, so a list of the
      // very objects the map arm exists to read was dropped whole and the
      // field fell through — an empty snippet beside a perfectly good one.
      final r = ZaiSearch.parseToolResult({
        'content': [
          {
            'type': 'text',
            'text': jsonEncode({
              'results': [
                {
                  'url': 'https://example.com/a',
                  'title': 'T',
                  'content': [
                    {'text': 'first'},
                    {'text': 'second'},
                  ],
                },
              ],
            }),
          },
        ],
      }, 5);
      expect(r.single.snippet, 'first second');
    });

    test('a bare JSON scalar block is prose, not its own source', () {
      // `jsonDecode` succeeds on a lone quoted string, and returning the
      // block handed back the quotes with it.
      final quoted = ZaiSearch.parseToolResult({
        'content': [
          {'type': 'text', 'text': '"No results for that query."'},
        ],
      }, 5);
      expect(quoted.single.snippet, 'No results for that query.');
      // And `null` is not an answer, which returning the block made it.
      expect(
        ZaiSearch.parseToolResult({
          'content': [
            {'type': 'text', 'text': 'null'},
          ],
        }, 5),
        isEmpty,
      );
    });

    test('a media name in any shape titles the result, not the URL', () {
      // `media` was the one field the shape walk did not go through: the
      // title switch returned it raw, so a localized object or a list failed
      // the `title is String` test at the bottom and the row rendered its
      // own URL — the exact symptom the map and list cases beside it exist
      // to prevent.
      for (final media in [
        {'en': 'A title'},
        ['A title'],
      ]) {
        final r = ZaiSearch.parseToolResult({
          'content': [
            {
              'type': 'text',
              'text': jsonEncode({
                'results': [
                  {
                    'url': 'https://example.com/a',
                    'media': media,
                    'snippet': 's',
                  },
                ],
              }),
            },
          ],
        }, 5);
        expect(r.single.title, 'A title', reason: 'media $media');
      }
    });

    test('an answer wrapped in an envelope is not thrown away with it', () {
      // The other half of the rule above, and the half the first version of
      // it broke: excluding every JSON container dropped a real answer that
      // happens to arrive inside one. `results` is empty so nothing
      // link-shaped is found, and the words are the whole reply.
      final answered = ZaiSearch.parseToolResult({
        'content': [
          {
            'type': 'text',
            'text': '{"answer": "Paris is the capital", "results": []}',
          },
        ],
      }, 5);
      expect(answered, hasLength(1));
      expect(answered.single.snippet, 'Paris is the capital');
      // Nested structure is not prose: `_collect` has already walked it, and
      // its punctuation is not an answer.
      expect(
        ZaiSearch.parseToolResult({
          'content': [
            {'type': 'text', 'text': '{"data": {"title": "unusable"}}'},
          ],
        }, 5),
        isEmpty,
      );
    });

    test('an empty snippet of any shape does not hide the description', () {
      // The same widening `content` got: a snippet that renders to nothing —
      // an empty list or map, or a scalar the rendering switch drops to '' —
      // kept its place and hid a usable description beside it. Both fields
      // now ask the renderer's own question, so they cannot disagree about
      // what "present" means.
      for (final empty in [<Object?>[], <String, Object?>{}, <Object?>[1, 2], true]) {
        final results = ZaiSearch.parseToolResult({
          'content': [
            {
              'type': 'text',
              'text': jsonEncode({
                'search_result': [
                  {
                    'title': 'T',
                    'link': 'https://example.com/d',
                    'snippet': empty,
                    'description': 'the usable one',
                  },
                ],
              }),
            },
          ],
        }, 5);
        expect(results.single.snippet, 'the usable one',
            reason: 'snippet: $empty should fall through');
      }
    });

    test('an empty snippet does not hide the description beside it', () {
      // The last hop of the fall-through chain: `??` answers for null alone,
      // so an explicitly empty snippet kept its place and dropped a usable
      // description — the asymmetry the three hops before it already fixed.
      final results = ZaiSearch.parseToolResult({
        'content': [
          {
            'type': 'text',
            'text': jsonEncode({
              'search_result': [
                {
                  'title': 'T',
                  'link': 'https://example.com/d',
                  'snippet': '',
                  'description': 'the usable one',
                },
              ],
            }),
          },
        ],
      }, 5);
      expect(results.single.snippet, 'the usable one');
    });

    test('an over-long URL keeps its result, to be clipped downstream', () {
      // One policy for one field. `clipSearchSnippets` caps every backend's
      // URL at `maxSearchUrlChars` with a visible ellipsis, so refusing here
      // dropped a Z.AI result — title and snippet with it — where the
      // identical URL from SearXNG or Brave was kept and truncated.
      final long = 'https://x.example/${'a' * (maxSearchUrlChars + 100)}';
      final results = ZaiSearch.parseToolResult({
        'content': [
          {
            'type': 'text',
            'text': jsonEncode({
              'search_result': [
                {'title': 'Huge', 'link': long, 'content': 'text'},
                {
                  'title': 'Fine',
                  'link': 'https://example.com/ok',
                  'content': 'text',
                },
              ],
            }),
          },
        ],
      }, 5);
      expect(results.map((r) => r.url), [long, 'https://example.com/ok']);
      expect(results.first.title, 'Huge',
          reason: 'the title and snippet ride through with it');

      // And the cap still lands, one layer on, where every backend meets it.
      final clipped = ChatController.clipSearchSnippets(results);
      expect(clipped.first.url.length, maxSearchUrlChars + 1);
      expect(clipped.first.url.endsWith('…'), isTrue);
      expect(clipped.first.title, 'Huge');
    });

    test('a title that arrives as a list is read, like a snippet is', () {
      final results = ZaiSearch.parseToolResult({
        'content': [
          {
            'type': 'text',
            'text': jsonEncode({
              'search_result': [
                {
                  'title': ['Part one', 'part two'],
                  'link': 'https://example.com/l',
                  'content': 'text',
                },
              ],
            }),
          },
        ],
      }, 5);
      expect(results.single.title, 'Part one part two');
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
      // A distinctive number rather than `1`: the matcher below bans the
      // payload's own string form anywhere in the message, and `1` bans the
      // digit — which any future wording carrying a count or an id would
      // trip, for a reason that has nothing to do with echoing a payload.
      for (final error in [const <String, Object>{}, 'down', 987654]) {
        expect(
          () => ZaiSearch.readRpcResult({
            'jsonrpc': '2.0',
            'id': 7,
            'error': error,
          }, method: 'tools/call', id: 7),
          throwsA(isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            // 'down' is the payload itself: "names its code and nothing
            // else" is the claim, and only the map case was checking it.
            allOf(
              isNot(contains('(code')),
              // Each payload against its own echo. `'down'` only says
              // anything for the string case; the map and the number were
              // asserted against a word they could not contain.
              isNot(contains('$error')),
              isNotEmpty,
            ),
          )),
        );
      }
    });
  });

  group('readRpcResult id', () {
    test('a reply for another request is not this call\'s answer', () {
      // The SSE reader filters by id, but the plain-JSON path hands whatever
      // came back straight over — and `readRpcResult` re-checks the reply's
      // id for exactly that. Every other fixture in this file passes a
      // matching id, so the guard was unpinned.
      expect(
        () => ZaiSearch.readRpcResult({
          'jsonrpc': '2.0',
          'id': 8,
          'result': {'content': <Object?>[]},
        }, method: 'tools/call', id: 7),
        throwsA(isA<http.ClientException>()),
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

    test('a non-positive count is omitted rather than sent', () {
      // `parseToolResult` already clamps one on the way back; forwarding it
      // spends a round trip to be told `-32602` by a gateway that cannot mean
      // anything by "give me zero results".
      for (final limit in [0, -3]) {
        expect(
          ZaiSearch.buildArguments(const {
            'properties': {
              'query': {'type': 'string'},
              'limit': {'type': 'integer'},
            },
          }, 'dart', limit),
          {'query': 'dart'},
          reason: 'limit $limit is not a count',
        );
      }
      // A required count still gets the schema's own default rather than
      // nothing, so the request stays well-formed.
      expect(
        ZaiSearch.buildArguments(const {
          'properties': {
            'query': {'type': 'string'},
            'count': {'type': 'integer', 'default': 10},
          },
          'required': ['count'],
        }, 'dart', 0),
        {'query': 'dart', 'count': 10},
      );
      // And the combination neither of those covers: required, no default,
      // nothing sensible to put there. Naming it is the same answer the
      // unfillable-parameter branch gives — better than spending a round trip
      // on `count: 0`, which no gateway can mean anything by, or on a request
      // missing a field its own schema calls required.
      expect(
        () => ZaiSearch.buildArguments(const {
          'properties': {
            'query': {'type': 'string'},
            'count': {'type': 'integer'},
          },
          'required': ['count'],
        }, 'dart', 0),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          contains('count'),
        )),
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
      // And a default fills a gap rather than replacing an answer: a required
      // count that declares one still takes the caller's. The case above uses
      // a string parameter, and the count cases elsewhere pass limit 0, so
      // the precedence between the two was the combination nothing pinned.
      expect(
        ZaiSearch.buildArguments(const {
          'properties': {
            'search_query': {'type': 'string'},
            'count': {'type': 'integer', 'default': 10},
          },
          'required': ['count'],
        }, 'dart', 3),
        {'search_query': 'dart', 'count': 3},
      );
    });

    test('a required parameter\'s name is echoed bounded', () {
      // The name is the gateway's to choose and the message reaches the UI.
      //
      // A *fillable* query parameter beside it, which this fixture used to
      // lack: with the long name as the only property, the tool has no query
      // parameter at all and the throw comes from that branch instead —
      // whose message is a constant, and so passed a bound on the length
      // while never echoing a name. The test was green for a reason that had
      // nothing to do with its subject.
      final name = 'p' * 500;
      expect(
        () => ZaiSearch.buildArguments({
          'properties': {
            'search_query': const {'type': 'string'},
            name: const {'type': 'string'},
          },
          'required': ['search_query', name],
        }, 'dart', 5),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          allOf(
            // Bounded *and* still there. On the length alone, a message that
            // stopped naming the parameter altogether — the dead end the
            // neighbouring test says this design exists to avoid — is under
            // any cap and passes, and so is an empty echo.
            contains('p' * 20),
            predicate<String>((m) => m.length < 160, 'under 160 characters'),
          ),
        )),
      );
    });

    test('the echoed name is not cut between the halves of an emoji', () {
      // Same fixture shape as the test above, and for the same reason: the
      // name has to reach the message before its cut can be asserted.
      // Swept rather than tuned to one length. The assertion is a negative —
      // no replacement character, no lone surrogate — and a name the clip
      // never reached satisfies it just as well as one it cut safely. A
      // single `'p' * 47` put the pair on the cut only while the message
      // prefix and the 48-unit cap were exactly what they are today, so any
      // edit to either would have slid the emoji clear and left this green
      // for a reason unrelated to its subject. The range straddles the cap
      // from both sides.
      for (var prefix = 32; prefix <= 64; prefix++) {
        final name = '${'p' * prefix}😀tail';
        expect(
          () => ZaiSearch.buildArguments({
            'properties': {
              'search_query': const {'type': 'string'},
              name: const {'type': 'string'},
            },
            'required': ['search_query', name],
          }, 'dart', 5),
          throwsA(isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            // Any lone surrogate, not only one followed by the ellipsis: a
            // cut on raw code units that appended nothing would leave one at
            // the end, and U+FFFD only appears once such a string is encoded.
            predicate<String>(
              (m) =>
                  !m.contains('\uFFFD') &&
                  !m.runes.any((r) => r >= 0xD800 && r <= 0xDFFF),
              'free of replacement characters and unpaired surrogates',
            ),
          )),
          reason: 'name prefix length $prefix',
        );
      }
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
        // Naming the parameter, not merely refusing: the gateway's schema is
        // the only place that says what it wanted, and "Z.AI advertised a
        // tool this build cannot call" with no name is a dead end for
        // whoever reads it.
        throwsA(isA<http.ClientException>()
            .having((e) => e.message, 'message', contains('tenant'))),
      );
    });

    test('a required name wins over an optional twin', () {
      // Both spellings advertised, only one required: taking the optional one
      // would put the query where the server does not read it, and leave the
      // required loop below to fill the real parameter from its default.
      expect(
        ZaiSearch.buildArguments(const {
          'properties': {
            'query': {'type': 'string'},
            'q': {'type': 'string'},
            'count': {'type': 'integer'},
            'limit': {'type': 'integer'},
          },
          'required': ['q', 'limit'],
        }, 'dart', 4),
        {'q': 'dart', 'limit': 4},
      );
    });

    test('a count named the way another schema spells it is still sent', () {
      // The names are the schema's to choose — that is what `pick` is for —
      // and `max_results` is as ordinary as `count` in MCP tool schemas.
      expect(
        ZaiSearch.buildArguments(const {
          'properties': {
            'search_query': {'type': 'string'},
            'max_results': {'type': 'integer'},
          },
        }, 'dart', 3),
        {'search_query': 'dart', 'max_results': 3},
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

    test('a payload nested past the cap is dropped, not crashed', () {
      // Server-controlled, and StackOverflowError is an Error — it would sail
      // past the `on Exception` handling every caller of this class relies on.
      //
      // `returnsNormally` alone could not say which of "walked it" and
      // "stopped at the cap" happened, and the walk caps at 32: the deep link
      // is unreachable, so the honest assertion is that nothing comes back.
      Map<String, Object?> wrap(int depth) {
        var nested = <String, Object?>{'link': 'https://deep.example'};
        for (var i = 0; i < depth; i++) {
          nested = <String, Object?>{'a': nested};
        }
        return nested;
      }

      expect(
        ZaiSearch.parseToolResult({'structuredContent': wrap(100000)}, 5),
        isEmpty,
      );
      // The control that keeps the assertion above from passing for a walk
      // that returns nothing at any depth.
      expect(
        ZaiSearch.parseToolResult({'structuredContent': wrap(20)}, 5)
            .map((r) => r.url),
        ['https://deep.example'],
      );
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
        ZaiSearch.bounded(source(), 1000, const Duration(seconds: 1))
            .toList()
            // Test-side only, like the deadline tests below: a byte cap that
            // stopped being enforced should fail here, not hang.
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<http.ClientException>()),
      );
      await expectLater(
        // 30 s, like the trickle test's, and for the same reason: this is the
        // one expectation here that passes only if *no* guard fires, so a
        // second of event-loop stall on a loaded runner would trip the idle
        // deadline and fail it with the other guard's message. The byte-vs-
        // code-unit distinction is carried by the 1000-cap expectation above,
        // which a stall cannot make pass.
        ZaiSearch.bounded(source(), 5000, const Duration(seconds: 30))
            .toList()
            .timeout(const Duration(seconds: 5)),
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
      addTearDown(controller.close);
      drip = Timer.periodic(const Duration(milliseconds: 5), (_) {
        if (!controller.isClosed) controller.add(utf8.encode('.'));
      });
      // Idempotent, so harmless after `onCancel` ran — and the only thing
      // that stops the timer when the expectation below fails instead.
      addTearDown(drip.cancel);

      await expectLater(
        ZaiSearch.bounded(
          controller.stream,
          1 << 20,
          // Wide enough that only the *total* deadline can fire, which is what
          // this test is about. The drip resets the idle one every 5 ms, so a
          // second is plenty in the ordinary case — but an event-loop stall on
          // a loaded runner would trip it and fail this with the other guard's
          // message, pointing at code the test does not exercise.
          const Duration(seconds: 30),
          total: const Duration(milliseconds: 40),
          totalMessage: 'held open',
        ).toList()
            // Test-side only, and it sat above beside `total:` and
            // `totalMessage:` — two production arguments, one of which this
            // test asserts the message of. It guards the line it is now on:
            // a deadline that stopped being enforced would hang this until
            // the runner's own timeout.
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          'held open',
        )),
      );
      expect(cancelled, isTrue);
    });

    test('a stream that never sends anything is cut off too', () async {
      // The stall test below delivers a byte first, so both it and the trickle
      // test only reach the idle guard once data has flowed. `bytes.timeout`
      // arms at subscription, which is what makes a server that accepts the
      // connection and then says nothing — a hung handshake — fail rather
      // than hang; nothing pinned that.
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      addTearDown(controller.close);

      await expectLater(
        ZaiSearch.bounded(
          controller.stream,
          1024,
          const Duration(milliseconds: 20),
        ).toList().timeout(const Duration(seconds: 5)),
        throwsA(isA<http.ClientException>()
            .having((e) => e.message, 'message', contains('stopped sending'))),
      );
      expect(cancelled, isTrue);
    });

    test('a stream that stalls is cut off rather than held open', () async {
      // The deadline lives here so ending the loop cancels the subscription;
      // as a `.timeout` on the awaited future it would free the caller and
      // leave the socket listening.
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      // Registered rather than closed at the end of the body: a failing
      // expectation would otherwise leave the controller open.
      addTearDown(controller.close);
      controller.add(utf8.encode('first'));

      await expectLater(
        ZaiSearch.bounded(
          controller.stream,
          1024,
          const Duration(milliseconds: 20),
        ).toList()
            // Test-side only, like the trickle test's: an idle deadline that
            // stopped being enforced would hang here on a controller that
            // never closes, rather than failing the expectation.
            .timeout(const Duration(seconds: 5)),
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
    });
  });

  group('readSseRpcMessage', () {
    Stream<List<int>> sse(List<String> events) =>
        Stream.fromIterable(events.map(utf8.encode));

    test('a comment frame inside an event neither ends it nor joins it',
        () async {
      // `: ping` is the standard SSE keep-alive, and this endpoint sits
      // behind gateways that send them while holding a connection open.
      // Placed *between* two data lines of one event, because that is the
      // only position that discriminates: a reader that ends the event on
      // any non-`data:` line decodes half a payload and then strands the
      // rest, and one that appends the comment to the payload feeds
      // `: ping` to `jsonDecode`. Both return null instead of the reply.
      // Outside an event the same two bugs are invisible — `finish()` on an
      // empty buffer answers null and the read simply continues. Measured:
      // each of those two regressions fails this test and nothing else.
      //
      // No multi-line-payload test beside it. One was written and deleted:
      // clearing the buffer per data line already fails three tests in this
      // file, so accumulation is pinned — and the join *character* cannot be
      // pinned at all, since every split of a valid JSON payload decodes the
      // same joined with a newline or with nothing.
      final message = await ZaiSearch.readSseRpcMessage(
        sse([
          'data: {"jsonrpc":"2.0",\n',
          ': ping\n',
          'data: "id":7,"result":{"content":[]}}\n',
          '\n',
        ]),
        7,
      ).timeout(const Duration(seconds: 5));

      expect(message, isNotNull);
      expect(message!['id'], 7);
    });

    test('a server request carrying our id is walked past, not answered',
        () async {
      // JSON-RPC ids are scoped per direction: the server's own counter can
      // hand a `sampling/createMessage` — or any request it initiates — the
      // number this request is using. Matched on the id alone, that message
      // ends the read and `readRpcResult` rejects it as an invalid reply,
      // while the answer is still inbound on the same stream.
      final message = await ZaiSearch.readSseRpcMessage(
        sse([
          'data: {"jsonrpc":"2.0","id":7,"method":"sampling/createMessage",'
              '"params":{}}\n',
          '\n',
          'data: {"jsonrpc":"2.0","id":7,"result":{"content":[]}}\n',
          '\n',
        ]),
        7,
      ).timeout(const Duration(seconds: 5));

      expect(message, isNotNull);
      expect(message!['result'], isNotNull);
    });

    test('a gateway rejection with no id ends the read', () async {
      // The gateway's `{"success": false}` envelope is not a JSON-RPC message
      // and carries no id, so an id filter drops it: the read waits out its
      // deadline and the caller is told nothing replied, where the same
      // rejection over plain JSON says which of key, plan and quota is wrong.
      final message = await ZaiSearch.readSseRpcMessage(
        sse([
          'data: {"success":false,"msg":"invalid api key"}\n',
          '\n',
        ]),
        7,
      ).timeout(const Duration(seconds: 5));

      expect(message, isNotNull);
      expect(
        () => ZaiSearch.readRpcResult(message, method: 'tools/call', id: 7),
        throwsA(isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          contains('rejected the search API key'),
        )),
      );
    });

    test('a reply with neither result nor error still ends the read', () async {
      // The narrow reading is deliberate: skipping on "carries no result and
      // no error" would swallow a malformed *response* too, turning the fast
      // "invalid reply" from `readRpcResult` into a wait for the stream to
      // end. A message with no `method` is a response, however broken.
      final message = await ZaiSearch.readSseRpcMessage(
        sse(['data: {"jsonrpc":"2.0","id":7}\n', '\n']),
        7,
      ).timeout(const Duration(seconds: 5));

      expect(message, isNotNull);
      expect(message!.containsKey('result'), isFalse);
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
      // And which copy callers get: a dedup that rewrote result URLs to its
      // normalized form, or kept the last seen, would also leave one.
      expect(results.single.url, 'https://x.example/docs');
    });

    test('a bare query marker is no query at all', () async {
      // Backends emit `…/docs?` after stripping tracking parameters. The key
      // took everything from the first '?', so the bare marker made a second
      // key for one page — two slots, and a real result off the end of the
      // limit.
      final results = await CompositeSearch([
        _Fixed([_hit('https://x.example/docs?')]),
        _Fixed([_hit('https://x.example/docs')]),
      ]).search('q', limit: 5);
      expect(results, hasLength(1));
      // And a query that carries something is still data, untouched.
      final kept = await CompositeSearch([
        _Fixed([_hit('https://x.example/docs?next=/docs/')]),
        _Fixed([_hit('https://x.example/docs')]),
      ]).search('q', limit: 5);
      expect(kept, hasLength(2));
    });

    test('two forms of one page from a single backend are one result',
        () async {
      // Every other dedup case here feeds the variants from *different*
      // backends, so a merge that deduped only across them would pass while
      // still showing the same page twice from one index.
      final results = await CompositeSearch([
        _Fixed([
          _hit('https://x.example/docs', title: 'Docs'),
          _hit('https://x.example/docs/', title: 'Docs, again'),
        ]),
      ]).search('q');
      expect(results.map((r) => r.url), ['https://x.example/docs']);
    });

    test('a trailing slash is the path\'s even when a query follows', () async {
      // The path ends at the first '?', so its trailing slash is the path's
      // wherever it sits. Skipping the trim whenever a query was present was
      // the safe half of that and cost the common case: two backends
      // disagreeing only about `…/docs/?q=1` versus `…/docs?q=1` each spent a
      // slot on the same page, pushing a real result off the end of the limit.
      final results = await CompositeSearch([
        _Fixed([_hit('https://x.example/docs/?q=1', title: 'With slash')]),
        _Fixed([_hit('https://x.example/docs?q=1', title: 'Without')]),
        _Fixed([_hit('https://x.example/other')]),
      ]).search('q', limit: 2);
      // The duplicate must not eat the slot the third backend's page needs.
      expect(results.map((r) => r.url),
          ['https://x.example/docs/?q=1', 'https://x.example/other']);
    });

    test('an unparseable URL drops its fragment too', () async {
      // The fallback is the raw string, and dropping the fragment is the
      // identity rule this key documents — applied only to URLs that parse,
      // `…#a` and `…#b` were two results for one malformed page. `http://[`
      // is an invalid IPv6 literal, which `Uri.tryParse` refuses outright.
      final results = await CompositeSearch([
        _Fixed([_hit('http://[#section-one', title: 'One')]),
        _Fixed([_hit('http://[#section-two', title: 'Two')]),
      ]).search('q', limit: 5);
      expect(results, hasLength(1));
      // And two genuinely different malformed URLs still count separately,
      // so the fallback has not collapsed onto one key.
      final distinct = await CompositeSearch([
        _Fixed([_hit('http://[one')]),
        _Fixed([_hit('http://[two')]),
      ]).search('q', limit: 5);
      expect(distinct, hasLength(2));
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

      // Rank 0 from each backend, then rank 1 — where the *first* backend's
      // "b" is the duplicate (the second backend's rank-0 hit was already
      // emitted) and is skipped, so the second backend's "d" takes that slot.
      expect(
        results.map((r) => r.url),
        ['https://a', 'https://b', 'https://d', 'https://c'],
      );
    });

    test('one backend failing does not take the search with it', () async {
      final results = await CompositeSearch([
        _Broken(),
        // Answers after the failure, so "a failure with no success yet in
        // hand is still contained" is the property under test rather than an
        // accident of how two immediate fakes interleave.
        _Fixed([_hit('https://a')], delay: const Duration(milliseconds: 25)),
      ]).search('q');
      expect(results.map((r) => r.url), ['https://a']);

    });

    test('a parse failure is contained like a transport one', () async {
      // Any backend error, not only the transport ones: reported under its
      // own name so a regression names the property that broke.
      expect(
        (await CompositeSearch([
          _Broken(const FormatException('bad payload')),
          _Fixed([_hit('https://a')]),
        ]).search('q'))
            .map((r) => r.url),
        ['https://a'],
      );
    });

    test('the caller\'s limit reaches the backends', () async {
      // Asserted on what the backend was handed, not on the merged list: the
      // merge caps at the caller's limit either way, so a composite that
      // dropped the argument would return the same two results.
      final backend =
          _Fixed([_hit('https://a'), _hit('https://b'), _hit('https://c')]);
      final second = _Fixed([_hit('https://x'), _hit('https://y')]);
      final results =
          await CompositeSearch([backend, second]).search('q', limit: 2);
      // Each backend is asked for the whole limit, not a share of it: the
      // union after dedup is usually smaller than the sum, and a short answer
      // from one is exactly when the other's results are wanted.
      expect(backend.lastLimit, 2);
      expect(second.lastLimit, 2);
      expect(results.map((r) => r.url), ['https://a', 'https://x']);
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
      // The backend's own error object, not a wrapper or a stand-in: one
      // instance in both backends, so it holds whichever failure escapes.
      final boom = StateError('bad api key');
      await expectLater(
        CompositeSearch([_Broken(boom), _Broken(boom)]).search('q'),
        throwsA(same(boom)),
      );
    });

    test('a backend that failed does not make an empty answer an error',
        () async {
      // The middle case between the two tests above, and the one a user hits
      // with a wrong key on one backend and no matches on the other: not
      // every backend failed, so "nothing found" is the honest answer even
      // with an error in hand. Two readings pass both neighbours — throw
      // whenever the merged list is empty and something failed, or throw only
      // when every backend failed — and only this tells them apart.
      expect(
        await CompositeSearch([_Broken(), _Fixed(const [])]).search('q'),
        isEmpty,
      );
    });

    test('no backends at all is simply nothing to search', () async {
      expect(await const CompositeSearch([]).search('q'), isEmpty);
    });
  });
}

SearchResult _hit(String url, {String? title}) =>
    SearchResult(title: title ?? url, url: url, snippet: 'body');

class _Fixed implements SearchProvider {
  final List<SearchResult> results;

  /// How long this backend takes to answer. A test that needs the failure to
  /// land before any success exists sets it, rather than relying on the
  /// microtask order of two fakes that both complete immediately.
  final Duration delay;

  _Fixed(this.results, {this.delay = Duration.zero});

  /// The limit this backend was asked for, which is not observable from the
  /// merged list: the merge caps at the caller's limit either way, so a
  /// composite that dropped the argument would return the same results.
  int? lastLimit;

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    lastLimit = limit;
    return results.take(limit).toList();
  }
}

class _Broken implements SearchProvider {
  /// Non-nullable with a default, so `_Broken(null)` is a compile error
  /// rather than a silent fall back to the generic failure — a test handing
  /// this a nullable variable would otherwise assert against an exception it
  /// did not choose.
  final Object error;
  _Broken([this.error = const _DefaultBackendFailure()]);

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async =>
      throw error;
}

/// The stand-in failure `_Broken` throws when a test does not name one.
class _DefaultBackendFailure implements Exception {
  const _DefaultBackendFailure();
  @override
  String toString() => 'unnamed backend failure';
}
