import 'dart:convert';

import 'package:http/http.dart' as http;

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
  void _reset() {
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
        (tool['inputSchema'] as Map?)?.cast<String, dynamic>() ?? const {},
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
    staged['mcp-protocol-version'] =
        initialized['protocolVersion'] as String? ?? protocolVersion;
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
      tools.addAll(((listing['tools'] as List?) ?? const []).whereType<Map>());
      cursor = listing['nextCursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
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
    final issued = response.headers['mcp-session-id'];
    // Only a staged (in-handshake) map is written to; the published one is
    // replaced wholesale when the handshake completes.
    if (issued != null && session != null) session['mcp-session-id'] = issued;

    if (response.statusCode == 404 && headers.containsKey('mcp-session-id')) {
      await response.stream.drain<void>();
      throw const _SessionExpired();
    }
    if (response.statusCode >= 400) {
      await response.stream.drain<void>();
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
      final message =
          await readSseRpcMessage(response.stream, id).timeout(timeout);
      if (message == null && id != null) {
        throw http.ClientException(
          'Z.AI closed the search stream before answering.',
        );
      }
      return message;
    }

    final body = await _readBounded(response.stream).timeout(timeout);
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
    await for (final chunk in bytes) {
      buffer.addAll(chunk);
      if (buffer.length > maxResponseBytes) {
        throw http.ClientException('Z.AI search reply was too large.');
      }
    }
    return utf8.decode(buffer, allowMalformed: true);
  }

  /// Read a `text/event-stream` reply and return the JSON-RPC message whose
  /// `id` is [id] (or the first message at all when [id] is null).
  ///
  /// Not [parseSseJson]: that yields every `data:` line as its own object,
  /// which is right for a token stream and wrong here. An SSE event's `data`
  /// field may be split across several lines that only mean anything joined,
  /// and one reply can be preceded by unrelated events that have to be walked
  /// past rather than mistaken for the answer.
  static Future<Map<String, dynamic>?> readSseRpcMessage(
    Stream<List<int>> bytes,
    int? id, {
    int maxBytes = maxResponseBytes,
  }) async {
    final data = <String>[];
    var read = 0;
    final lines = utf8.decoder
        .bind(bytes)
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
      if (id != null && decoded['id'] != id) return null;
      return decoded;
    }

    await for (final line in lines) {
      read += line.length + 1;
      if (read > maxBytes) {
        throw http.ClientException('Z.AI search reply was too large.');
      }
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
      if (text.contains('auth') ||
          text.contains('api key') ||
          text.contains('token')) {
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
        (schema['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
    final required =
        ((schema['required'] as List?) ?? const []).whereType<String>();

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
      final property = (properties[name] as Map?)?.cast<String, dynamic>();
      final fallback =
          property?['default'] ?? (property?['enum'] as List?)?.firstOrNull;
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

  static void _collect(Object? value, List<SearchResult> out, Set<String> seen) {
    if (value is List) {
      for (final item in value) {
        _collect(item, out, seen);
      }
      return;
    }
    if (value is String) {
      // A text block's payload is itself JSON when the tool has results to
      // report; plain prose simply doesn't decode and is left to the caller.
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map || decoded is List) _collect(decoded, out, seen);
      } on FormatException {
        // Not JSON. Nothing to collect from it here.
      }
      return;
    }
    if (value is! Map) return;

    final url = value['link'] ?? value['url'];
    if (url is String && url.isNotEmpty && seen.add(url)) {
      out.add(SearchResult(
        title: '${value['title'] ?? value['media'] ?? url}',
        url: url,
        snippet:
            '${value['content'] ?? value['snippet'] ?? value['description'] ?? ''}',
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
      _collect(entry.value, out, seen);
    }
  }
}

/// The server retired our session id (MCP answers 404). Internal: [ZaiSearch]
/// handles it by handshaking again, and it never reaches a caller.
class _SessionExpired implements Exception {
  const _SessionExpired();
}
