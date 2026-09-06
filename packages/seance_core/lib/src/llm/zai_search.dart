import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'search.dart';

/// Search via Z.AI's Web Search Prime server, which speaks MCP over Streamable
/// HTTP rather than a plain REST endpoint.
///
/// The transport is the awkward part and the reason this is not another
/// twenty-line [SearchProvider]: one POST endpoint carrying JSON-RPC 2.0, a
/// three-step handshake before the first search, a session id handed back in a
/// response *header* that every later request must echo, and replies that
/// arrive either as JSON or as a `text/event-stream` at the server's
/// discretion. All of that is done once, lazily, and cached for the life of
/// the instance.
///
/// The search tool's arguments are built from the schema the server advertises
/// rather than hard-coded (see [buildArguments]). Z.AI names the query
/// `search_query` and requires a `search_engine` today; asking the server what
/// it wants costs one round trip already spent on the handshake and means a
/// renamed or newly-required parameter is not a silent empty result set.
class ZaiSearch implements SearchProvider {
  /// The published Streamable-HTTP endpoint. Overridable for tests.
  static const String defaultEndpoint =
      'https://api.z.ai/api/mcp/web_search_prime/mcp';

  /// The MCP revision this client implements. The server may answer
  /// [initialize] with a different one, and that answer is what gets echoed
  /// back in the `MCP-Protocol-Version` header from then on.
  static const String protocolVersion = '2025-03-26';

  /// Names the search tool has shipped under. Checked in order.
  static const List<String> toolNames = ['web_search_prime', 'webSearchPrime'];

  /// A reply larger than this is refused rather than buffered. Search results
  /// are kilobytes; anything at this scale is a misrouted response or a
  /// gateway error page, and neither is worth the memory.
  static const int maxResponseBytes = 2 * 1024 * 1024;

  /// How many pages of `tools/list` to walk. MCP paginates, and a server that
  /// keeps handing back a cursor should stop the handshake rather than spin
  /// it. Z.AI advertises a handful of tools; this is slack, not a budget.
  static const int maxToolPages = 20;

  final String apiKey;
  final String endpoint;
  final Duration timeout;
  final http.Client _client;

  /// Headers the session has accumulated: the negotiated protocol version and,
  /// once the server issues one, its session id. Replaced wholesale by a
  /// completed handshake, never edited by one in progress.
  Map<String, String> _session = const {};

  /// The handshake, and through it the advertised search tool.
  ///
  /// The tool is the future's *value* rather than a field beside it: with a
  /// field, a concurrent reset could null it between the handshake completing
  /// and the caller reading it, and the read was a `!`. There is no window to
  /// lose here.
  Future<Map<String, dynamic>>? _handshake;
  int _nextId = 0;

  ZaiSearch({
    required this.apiKey,
    this.endpoint = defaultEndpoint,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    try {
      return await _attempt(query, limit);
    } on _SessionExpired {
      // MCP answers 404 when a session id has been retired. Start over once —
      // a second 404 is not a stale session, and retrying forever would spend
      // the user's quota on a wall.
      _reset();
      try {
        return await _attempt(query, limit);
      } on _SessionExpired {
        throw http.ClientException(
          'Z.AI kept dropping the search session. Try again in a moment.',
        );
      }
    }
  }

  Future<List<SearchResult>> _attempt(String query, int limit) async {
    return _callSearch(await _ensureHandshake(), query, limit);
  }

  /// Forget the negotiated session so the next search starts a new one.
  ///
  /// No-op when the session is already cleared, which is what keeps a burst of
  /// concurrent expiries to one re-handshake. N callers sharing one session
  /// all see the same 404: without this, the first would clear and install a
  /// fresh attempt, the second would null *that* still-in-flight attempt and
  /// start another, and so on — N handshakes, N abandoned server-side
  /// sessions, and `_session` left to whichever orphan finished last.
  ///
  /// Sound because [_runHandshake] stages its headers locally and publishes
  /// `_session` only on success: while an attempt is in flight the published
  /// session is empty, so an empty one never means "a live session still
  /// needs clearing". It is the same identity reasoning [_ensureHandshake]
  /// already uses when clearing a failed attempt.
  void _reset() {
    if (_session.isEmpty) return;
    _session = const {};
    _handshake = null;
  }

  Future<List<SearchResult>> _callSearch(
    Map<String, dynamic> tool,
    String query,
    int limit,
  ) async {
    final result = await _call('tools/call', {
      'name': tool['name'],
      'arguments': buildArguments(
        _asStringMap(tool['inputSchema']),
        query,
        limit,
      ),
    });
    if (result['isError'] == true) {
      // The tool's own text, unlike a gateway error page: this is written by
      // the search server for a person to read ("quota exceeded"), and it is
      // the only place that says *which* of key, plan and quota is the
      // problem. A transport body still never gets quoted — that one can echo
      // the request, Authorization header included.
      final detail = _textBlocks(result['content']).join(' ').trim();
      throw http.ClientException(
        detail.isEmpty
            ? 'Z.AI search failed. Check the search key, Coding Plan access, '
                'and quota.'
            : 'Z.AI search failed: $detail',
      );
    }
    return parseToolResult(result, limit);
  }

  /// Run the handshake once, and let concurrent callers await the same one.
  Future<Map<String, dynamic>> _ensureHandshake() async {
    final pending = _handshake;
    if (pending != null) return pending;
    final attempt = _runHandshake();
    _handshake = attempt;
    try {
      return await attempt;
    } catch (_) {
      // A failed handshake must never stay cached as "done", or every later
      // search on this instance fails without retrying. Cleared by identity:
      // a [_reset] may already have installed a newer attempt, and clearing
      // that one would undo it.
      if (identical(_handshake, attempt)) _handshake = null;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _runHandshake() async {
    // Staged locally and published only on success. A handshake that edited
    // `_session` as it went could have its freshly negotiated id wiped by a
    // *second* caller's expiry reset arriving mid-flight, and would then send
    // its own next request without one.
    final staged = <String, String>{};
    final initialized = await _call(
      'initialize',
      {
        'protocolVersion': protocolVersion,
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'seance', 'version': '1'},
      },
      session: staged,
    );
    // Read with `is`, not `as`. These values are the gateway's, and a failed
    // cast throws `TypeError` — an `Error`, which sails past the `on
    // Exception` handling every caller of this class relies on and reaches
    // the UI raw, instead of the deliberately body-free message every other
    // malformed-reply path produces. Same reasoning as `_collect`'s depth cap.
    final negotiated = initialized['protocolVersion'];
    staged['mcp-protocol-version'] =
        negotiated is String ? negotiated : protocolVersion;
    // A notification: no id, so no reply to match. The server acknowledges
    // with 202 and an empty body.
    await _send(
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      session: staged,
    );

    final tools = <Map>[];
    String? cursor;
    // MCP paginates tool listings. Bounded so a server that keeps handing
    // back a cursor cannot spin here forever.
    for (var page = 0; page < maxToolPages; page++) {
      final listing = await _call(
        'tools/list',
        cursor == null ? const <String, dynamic>{} : {'cursor': cursor},
        session: staged,
      );
      tools.addAll(_asList(listing['tools']).whereType<Map>());
      final next = listing['nextCursor'];
      cursor = next is String ? next : null;
      if (cursor == null || cursor.isEmpty) break;
    }
    if (cursor != null && cursor.isNotEmpty) {
      // Falling out of the loop still holding a cursor means the listing was
      // truncated. Searching the partial list anyway would report "no search
      // tool… needs a GLM Coding Plan" for what is a pagination anomaly —
      // sending the user to check their plan and key over a transport fault.
      throw http.ClientException(
        'Z.AI kept paginating tools/list; stopped after $maxToolPages pages.',
      );
    }

    for (final name in toolNames) {
      for (final tool in tools) {
        if (tool['name'] == name) {
          _session = Map.unmodifiable(staged);
          return tool.cast<String, dynamic>();
        }
      }
    }
    throw http.ClientException(
      'Z.AI did not advertise a web search tool. Web Search Prime needs a '
      'GLM Coding Plan.',
    );
  }

  /// One JSON-RPC request/response pair, returning the `result` object.
  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> params, {
    Map<String, String>? session,
  }) async {
    final id = ++_nextId;
    final message = await _send({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }, id: id, session: session);
    return readRpcResult(message, method: method, id: id);
  }

  /// POST one JSON-RPC message and return the reply, or null for a
  /// notification the server acknowledged without one.
  Future<Map<String, dynamic>?> _send(
    Map<String, dynamic> payload, {
    int? id,
    Map<String, String>? session,
  }) async {
    final headers = session ?? _session;
    final request = http.Request('POST', Uri.parse(endpoint))
      ..headers.addAll({
        'content-type': 'application/json',
        // The server picks per reply, so both have to be acceptable.
        'accept': 'application/json, text/event-stream',
        'authorization': 'Bearer $apiKey',
        ...headers,
      })
      ..body = jsonEncode(payload);

    final response = await _client.send(request).timeout(timeout);
    // Case-insensitive by contract in package:http, so this is the header the
    // server sent whatever case it used.
    // Read before the write below: `headers` *is* `session` during a
    // handshake, so asking it afterwards answers about the id the reply just
    // issued rather than the one the request carried — and a gateway that
    // answers `initialize` with both a 404 and a session id would be read as
    // an expired session, costing a re-handshake and reporting a dropped
    // session for what is a wrong endpoint.
    final sentSessionId = headers.containsKey('mcp-session-id');
    final issued = response.headers['mcp-session-id'];
    // Only a staged (in-handshake) map is written to; the published one is
    // replaced wholesale when the handshake completes.
    if (issued != null && session != null) session['mcp-session-id'] = issued;

    // Both drains are deadlined like the SSE one: `send` only bounds the wait
    // for headers, so a gateway that answers 4xx and then stalls the body
    // would hang here — turning a fast retry into an unbounded wait, on the
    // one path that exists to fail quickly.
    if (response.statusCode == 404 && sentSessionId) {
      await response.stream.drain<void>().timeout(timeout);
      throw const _SessionExpired();
    }
    if (response.statusCode >= 400) {
      await response.stream.drain<void>().timeout(timeout);
      // Deliberately without the body, unlike the LLM providers': this is a
      // gateway that can echo the request — including its Authorization
      // header — back in an error page, and this string reaches the UI.
      throw http.ClientException(
        'Z.AI search error HTTP ${response.statusCode}.',
      );
    }

    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('text/event-stream')) {
      // The send timeout only covers the headers. Streamable HTTP lets a
      // server hold a stream open, so without a deadline here a proxy that
      // answers 200 and then stalls hangs the caller for good.
      if (id == null) {
        // A notification has no reply, so there is nothing to match and
        // nothing to wait for: reading until "some message" arrives would
        // burn the whole deadline on a stream carrying only heartbeats.
        await response.stream.drain<void>().timeout(timeout);
        return null;
      }
      // Two deadlines, two different failures. `bounded`'s idle one converts
      // its own; this outer one is the overall cap, for a stream that keeps
      // trickling without ever answering — and it was reaching the UI as
      // "Future not completed".
      final Map<String, dynamic>? message;
      try {
        message = await readSseRpcMessage(
          response.stream,
          id,
          idleTimeout: timeout,
        ).timeout(timeout);
      } on TimeoutException {
        throw http.ClientException(
          'Z.AI never finished answering the search stream.',
        );
      }
      if (message == null) {
        throw http.ClientException(
          'Z.AI closed the search stream before answering.',
        );
      }
      return message;
    }

    final String body;
    try {
      body = await _readBounded(response.stream).timeout(timeout);
    } on TimeoutException {
      throw http.ClientException('Z.AI stopped sending the search reply.');
    }
    if (body.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      // A gateway that answers 200 with an HTML error page reaches here. It
      // is the same failure as a reply of the wrong shape, and deserves the
      // same error rather than a raw decode exception the caller cannot
      // classify.
      throw http.ClientException('Z.AI returned an unexpected search reply.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw http.ClientException('Z.AI returned an unexpected search reply.');
    }
    return decoded;
  }

  Future<String> _readBounded(Stream<List<int>> bytes) async {
    final buffer = <int>[];
    await for (final chunk in bounded(bytes, maxResponseBytes, timeout)) {
      buffer.addAll(chunk);
    }
    return utf8.decode(buffer, allowMalformed: true);
  }

  /// [bytes] capped at [maxBytes] and cut off after [idle] without an event.
  ///
  /// The cap is counted here, on the bytes, rather than on decoded lines: one
  /// CJK character is three UTF-8 bytes and a single code unit, so a count
  /// taken after decoding is three times too generous for exactly the results
  /// this endpoint returns — and it only trips once the oversized chunk has
  /// been materialized.
  ///
  /// The deadline is here too, rather than only as a `.timeout` on the future
  /// the caller awaits. That form frees the caller and leaves the subscription
  /// listening, so a proxy that answers 200 and then stalls keeps a socket and
  /// its buffer for as long as it likes. Thrown into the stream, it ends the
  /// `await for` that owns the subscription, which cancels it.
  @visibleForTesting
  static Stream<List<int>> bounded(
    Stream<List<int>> bytes,
    int maxBytes,
    Duration idle,
  ) async* {
    var read = 0;
    try {
      await for (final chunk in bytes.timeout(idle)) {
        read += chunk.length;
        if (read > maxBytes) {
          throw http.ClientException('Z.AI search reply was too large.');
        }
        yield chunk;
      }
    } on TimeoutException {
      // The byte cap already throws something a person can read; the idle
      // deadline was raising a bare `TimeoutException` whose message is
      // "Future not completed". Both guards exist for the same 200-then-stall
      // case, and both reach the UI, so both say what happened. Nothing in
      // this package retries on the type — the two `on TimeoutException`
      // handlers in `seance_core` are SSH's.
      throw http.ClientException('Z.AI stopped sending the search reply.');
    }
  }

  /// Read a `text/event-stream` reply and return the JSON-RPC message whose
  /// `id` is [id].
  ///
  /// [id] is required: with none, every decoded object would end the read, so
  /// the first heartbeat or notification on the stream would be returned as
  /// the answer. A request without an id is a notification and has no reply
  /// to read, which [_send] handles by draining instead.
  ///
  /// Not [parseSseJson]: that yields every `data:` line as its own object,
  /// which is right for a token stream and wrong here. An SSE event's `data`
  /// field may be split across several lines that only mean anything joined,
  /// and one reply can be preceded by unrelated events that have to be walked
  /// past rather than mistaken for the answer.
  static Future<Map<String, dynamic>?> readSseRpcMessage(
    Stream<List<int>> bytes,
    int id, {
    int maxBytes = maxResponseBytes,
    Duration idleTimeout = const Duration(seconds: 30),
  }) async {
    final data = <String>[];
    // Tolerant, like `_readBounded`'s decode: malformed bytes on an SSE
    // stream would otherwise raise a `FormatException` from inside the line
    // pipeline that nothing here converts, so the same bad payload fails two
    // different ways depending on which transport carried it.
    final lines = const Utf8Decoder(allowMalformed: true)
        .bind(bounded(bytes, maxBytes, idleTimeout))
        .transform(const LineSplitter());

    Map<String, dynamic>? finish() {
      if (data.isEmpty) return null;
      final payload = data.join('\n');
      data.clear();
      final Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } on FormatException {
        // Not every data event is a JSON-RPC message: heartbeats, banners and
        // a bare `data:` line are all legal SSE. Skipping is what the walk
        // past unrelated events is for.
        return null;
      }
      if (decoded is! Map<String, dynamic>) return null;
      // A server may interleave other messages (a notification, a ping)
      // before the answer; only the matching id ends the read.
      if (decoded['id'] != id) return null;
      return decoded;
    }

    await for (final line in lines) {
      if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
      } else if (line.isEmpty) {
        final message = finish();
        if (message != null) return message;
      }
      // `event:`, `id:` and comment lines carry nothing this needs.
    }
    // A stream that ends without its blank terminator still has an event in
    // hand; SSE says to discard it, but a truncated reply is worth one try.
    return finish();
  }

  /// Unwrap a JSON-RPC reply into its `result`, or throw a readable error.
  ///
  /// Three failure shapes, not one. Z.AI's gateway sits in front of the MCP
  /// server and answers HTTP 200 with its own `{"success": false}` envelope
  /// when it rejects a request — a bad key never reaches JSON-RPC at all — so
  /// that case is checked first and, when it reads as an auth failure, says so
  /// instead of leaving the user to guess between key, plan and quota. None of
  /// the three ever quote the body back: gateway messages can echo request
  /// data, and these strings reach the UI.
  static Map<String, dynamic> readRpcResult(
    Map<String, dynamic>? message, {
    required String method,
    required int id,
  }) {
    if (message == null) {
      throw http.ClientException('Z.AI sent no reply to $method.');
    }
    if (message['success'] == false) {
      final text = '${message['msg'] ?? ''}'.toLowerCase();
      // Quota first: "insufficient token quota" and "token limit reached"
      // both carry "token", and telling someone with a working key to rotate
      // it is the exact confusion this branch exists to prevent.
      final quota = text.contains('quota') ||
          text.contains('limit') ||
          text.contains('balance') ||
          text.contains('insufficient');
      if (!quota &&
          (text.contains('auth') ||
              text.contains('api key') ||
              text.contains('token'))) {
        throw http.ClientException(
          'Z.AI rejected the search API key. Check the key in Settings.',
        );
      }
      throw http.ClientException(
        'Z.AI rejected $method. Check the search key, Coding Plan access, '
        'and quota.',
      );
    }
    if (message['error'] != null) {
      throw http.ClientException(
        'Z.AI reported an error for $method. Check Coding Plan access and '
        'search configuration.',
      );
    }
    final result = message['result'];
    if (message['id'] != id || result is! Map) {
      throw http.ClientException('Z.AI returned an invalid reply to $method.');
    }
    return result.cast<String, dynamic>();
  }

  /// The `arguments` object for the advertised [schema].
  ///
  /// Split out for testing, and driven by the schema rather than hard-coded:
  /// the query lands on whichever name the server declares, the result count
  /// likewise, and any *other* required parameter is filled from its own
  /// `default` or the first of its `enum` — which is how `search_engine`
  /// ("search-prime") gets supplied without this file needing to know it
  /// exists. A required parameter that offers neither is an error worth saying
  /// out loud, since guessing would spend a search to get an empty answer.
  static Map<String, dynamic> buildArguments(
    Map<String, dynamic> schema,
    String query,
    int limit,
  ) {
    final properties =
        _asStringMap(schema['properties']);
    final required =
        _asList(schema['required']).whereType<String>();

    String? pick(List<String> candidates) {
      for (final name in candidates) {
        if (properties.containsKey(name)) return name;
      }
      return null;
    }

    final queryKey = pick(const ['search_query', 'query', 'q']);
    if (queryKey == null) {
      throw http.ClientException(
        'Z.AI advertised a search tool with no query parameter.',
      );
    }
    final arguments = <String, dynamic>{queryKey: query};
    final countKey = pick(const ['count', 'limit', 'num_results']);
    if (countKey != null) arguments[countKey] = limit;

    for (final name in required) {
      if (arguments.containsKey(name)) continue;
      final property = _asStringMapOrNull(properties[name]);
      final fallback =
          property?['default'] ?? _asList(property?['enum']).firstOrNull;
      if (fallback == null) {
        throw http.ClientException(
          'Z.AI requires a search parameter Séance cannot supply: $name.',
        );
      }
      arguments[name] = fallback;
    }
    return arguments;
  }

  /// Pull search results out of an MCP tool result.
  ///
  /// Split out for testing. MCP returns a list of content blocks; Z.AI puts
  /// its results in a text block holding JSON, so the parse walks whatever it
  /// is handed and collects every object that carries a link — which also
  /// covers `structuredContent`, and survives the results moving a level up or
  /// down inside the envelope.
  ///
  /// When nothing link-shaped is in there but the tool did answer with prose,
  /// that prose is returned as a single result rather than an empty list: the
  /// assistant is being handed this as context, and silently dropping an
  /// answer the search did find is the worse failure.
  static List<SearchResult> parseToolResult(
    Map<String, dynamic> result,
    int limit,
  ) {
    final found = <SearchResult>[];
    final seen = <String>{};
    _collect(result['structuredContent'], found, seen);
    _collect(result['content'], found, seen);
    if (found.isNotEmpty) return found.take(limit).toList();

    final prose = _textBlocks(result['content']).join('\n').trim();
    if (prose.isEmpty) return const [];
    return [SearchResult(title: 'Z.AI web search', url: '', snippet: prose)];
  }

  static Iterable<String> _textBlocks(Object? content) sync* {
    if (content is! List) return;
    for (final block in content.whereType<Map>()) {
      final text = block['text'];
      if (text is String && text.isNotEmpty) yield text;
    }
  }

  /// [depth] caps the walk: the payload is server-controlled, and a
  /// `StackOverflowError` is an `Error`, so it would sail past the
  /// `on Exception` handling every caller of this class relies on. Thirty-two
  /// is far past any real result shape.
  /// Server-supplied JSON read without a cast that can throw.
  ///
  /// `as Map?` on a value the gateway chose raises `TypeError`, which is an
  /// `Error`: it escapes the `on Exception` handling around this class and
  /// reaches the UI as "type 'String' is not a subtype of type 'Map?'"
  /// instead of the readable, body-free `ClientException` every other
  /// malformed-reply path here produces.
  static Map<String, dynamic> _asStringMap(Object? value) =>
      value is Map ? value.cast<String, dynamic>() : const {};

  static Map<String, dynamic>? _asStringMapOrNull(Object? value) =>
      value is Map ? value.cast<String, dynamic>() : null;

  static List<Object?> _asList(Object? value) =>
      value is List ? value : const [];

  /// A URL a search result may legitimately carry: a web page, with a host.
  ///
  /// Parsed rather than prefix-matched, so `https:evil` and a bare
  /// `https://` do not pass for want of a host.
  static bool _isWebUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static void _collect(Object? value, List<SearchResult> out, Set<String> seen,
      [int depth = 0]) {
    if (depth > 32) return;
    if (value is List) {
      for (final item in value) {
        _collect(item, out, seen, depth + 1);
      }
      return;
    }
    if (value is String) {
      // A text block's payload is itself JSON when the tool has results to
      // report; plain prose simply doesn't decode and is left to the caller.
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map || decoded is List) {
          _collect(decoded, out, seen, depth + 1);
        }
      } on FormatException {
        // Not JSON. Nothing to collect from it here.
      }
      return;
    }
    if (value is! Map) return;

    // `??` alone would keep an empty `link` and hide a usable `url` beside
    // it, dropping the result — the opposite of the shape-tolerance the rest
    // of this walk is written for.
    final link = value['link'];
    final url = link is String && link.isNotEmpty ? link : value['url'];
    // http(s) only. These strings are chosen by the search gateway, and a
    // result is a web page by definition — so anything else is either not a
    // result or an attempt to hand the app a scheme to launch.
    if (url is String && _isWebUrl(url) && seen.add(url)) {
      // Interpolating whatever is there would put `{lang: en, text: …}` or
      // `[a, b]` into the UI verbatim: some search APIs return `content` as a
      // list of paragraphs or `title` as a localized object. The rest of this
      // function goes out of its way to survive a shape it did not expect,
      // and these two fields are read by a person.
      // Empty falls through, like `link` two lines up: `??` only handles
      // null, so an explicitly empty title would keep the empty string and
      // render the raw URL with a perfectly good `media` name beside it.
      final rawTitle = value['title'];
      final title = rawTitle is String && rawTitle.isNotEmpty
          ? rawTitle
          : value['media'];
      final snippet =
          value['content'] ?? value['snippet'] ?? value['description'];
      out.add(SearchResult(
        title: title is String && title.isNotEmpty ? title : url,
        url: url,
        snippet: switch (snippet) {
          final String text => text,
          final List<Object?> parts => parts.whereType<String>().join(' '),
          // The localized-object shape the comment above names — `{lang: en,
          // text: …}`. The list case is already joined, so dropping the map
          // case to '' was an asymmetry rather than a policy: it vanished the
          // whole snippet for exactly the payload this walk is built for.
          final Map<Object?, Object?> fields =>
            fields.values.whereType<String>().join(' '),
          _ => '',
        },
      ));
      return;
    }
    for (final entry in value.entries) {
      // Icons are URLs that are not results; walking into them would fill the
      // list with favicons.
      if (entry.key == 'icon' ||
          entry.key == 'favicon' ||
          entry.key == 'site_icon') {
        continue;
      }
      _collect(entry.value, out, seen, depth + 1);
    }
  }
}

/// The server retired our session id (MCP answers 404). Internal: [ZaiSearch]
/// handles it by handshaking again, and it never reaches a caller.
class _SessionExpired implements Exception {
  const _SessionExpired();
}
