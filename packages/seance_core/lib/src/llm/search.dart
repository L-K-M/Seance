import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

class SearchResult {
  final String title;
  final String url;
  final String snippet;
  const SearchResult(
      {required this.title, required this.url, required this.snippet});

  Map<String, dynamic> toJson() =>
      {'title': title, 'url': url, 'snippet': snippet};
}

/// A client-side web-search backend, used when the LLM provider has no
/// server-side search tool (e.g. local Ollama). Cloud providers can instead use
/// their native search; the chat controller treats both through one interface.
abstract class SearchProvider {
  Future<List<SearchResult>> search(String query, {int limit = 5});
}

/// Search via a self-hosted SearXNG instance (`/search?format=json`). Fits the
/// same "run it in Docker yourself" story as the sync server.
class SearxngSearch implements SearchProvider {
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;

  SearxngSearch({
    required this.baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    final uri = Uri.parse('$baseUrl/search').replace(queryParameters: {
      'q': query,
      'format': 'json',
    });
    final res = await _client.get(uri).timeout(timeout);
    if (res.statusCode >= 400) {
      throw http.ClientException('SearXNG error HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final results = (body['results'] as List?) ?? const [];
    return results
        .cast<Map<String, dynamic>>()
        .take(limit)
        .map((r) => SearchResult(
              title: r['title'] as String? ?? '',
              url: r['url'] as String? ?? '',
              snippet: r['content'] as String? ?? '',
            ))
        .toList();
  }
}

/// Search via the Brave Search API (hosted alternative to self-hosting).
class BraveSearch implements SearchProvider {
  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;

  BraveSearch({
    required this.apiKey,
    this.baseUrl = 'https://api.search.brave.com',
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    final uri = Uri.parse('$baseUrl/res/v1/web/search')
        .replace(queryParameters: {'q': query, 'count': '$limit'});
    final res = await _client.get(uri, headers: {
      'accept': 'application/json',
      'x-subscription-token': apiKey,
    }).timeout(timeout);
    if (res.statusCode >= 400) {
      throw http.ClientException('Brave Search error HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final web = (body['web'] as Map<String, dynamic>?)?['results'] as List?;
    return ((web) ?? const [])
        .cast<Map<String, dynamic>>()
        .take(limit)
        .map((r) => SearchResult(
              title: r['title'] as String? ?? '',
              url: r['url'] as String? ?? '',
              snippet: r['description'] as String? ?? '',
            ))
        .toList();
  }
}

/// [url] reduced to the identity two backends should agree on.
///
/// Falls back to the raw string when it will not parse: an unparseable URL is
/// still a distinct result, and collapsing every one of them onto `''` would
/// let the first swallow the rest.
String _dedupKey(String url) {
  final parsed = Uri.tryParse(url);
  final withoutFragment = parsed == null ? url : parsed.removeFragment().toString();
  return withoutFragment.replaceFirst(RegExp(r'/+$'), '');
}

/// Query several backends at once and merge what comes back.
///
/// Configured means used: a priority chain would quietly ignore a second key
/// someone took the trouble to enter, and "use Z.AI as well as my SearXNG" is
/// a reasonable thing to want. Clearing a field is how you get "instead of" —
/// so one control shape covers every combination, with no mode to keep in
/// step.
///
/// Results are interleaved round-robin rather than concatenated, so a fast
/// backend cannot fill the whole limit before a slower one is heard from, and
/// deduplicated by URL because two web indexes agreeing is one result, not two.
class CompositeSearch implements SearchProvider {
  final List<SearchProvider> providers;

  const CompositeSearch(this.providers);

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    // Each backend is asked for the full limit: after deduplication the union
    // is usually smaller than the sum, and a short answer from one is exactly
    // when the other's results are wanted.
    final answers = await Future.wait(
      providers.map((p) async {
        try {
          return await p.search(query, limit: limit);
        } catch (error, stackTrace) {
          // One backend being down, rate-limited or misconfigured should not
          // take the search with it. If *every* one failed, the error is
          // re-raised below rather than reported as "nothing found".
          //
          // Logged either way: a partial failure is invisible from the
          // outside — an expired key alongside a working backend just looks
          // like worse results — so this is the only record it happened.
          developer.log(
            'Web search backend failed: $error',
            name: _searchLoggerName,
            level: _warningLogLevel,
            error: error,
            stackTrace: stackTrace,
          );
          return _Failure(error, stackTrace);
        }
      }),
    );
    final lists = answers.whereType<List<SearchResult>>().toList();
    if (lists.isEmpty) {
      // Every backend failed. Re-raise the first failure rather than reporting
      // "nothing found", which is a different answer and a misleading one for
      // what is a configuration or outage problem. With no backends at all
      // there is nothing to raise and nothing to find.
      //
      // With its original stack: rethrowing the bare object would point at
      // this loop instead of at the HTTP or parse failure inside the backend,
      // which is exactly the case this branch exists to make legible.
      final failure = answers.whereType<_Failure>().firstOrNull;
      if (failure != null) {
        Error.throwWithStackTrace(failure.error, failure.stackTrace);
      }
      return const [];
    }

    final merged = <SearchResult>[];
    final seen = <String>{};
    for (var rank = 0; merged.length < limit; rank++) {
      var exhausted = true;
      for (final list in lists) {
        if (rank >= list.length) continue;
        exhausted = false;
        final result = list[rank];
        // Normalized before the set, so two indexes reporting one page as
        // `…/docs`, `…/docs/` and `…/docs#section` spend one slot rather than
        // three. Deliberately conservative — the fragment and trailing
        // slashes only. Case and query string stay, because `?id=1` and
        // `?id=2` are genuinely different pages and lowercasing a path can
        // merge two.
        final key = _dedupKey(result.url);
        if (key.isNotEmpty && !seen.add(key)) continue;
        merged.add(result);
        if (merged.length == limit) break;
      }
      if (exhausted) break;
    }
    return merged;
  }
}

const int _warningLogLevel = 900;
const String _searchLoggerName = 'seance.search';

/// One backend's failure, kept with its stack so [CompositeSearch] can re-raise
/// it as it was thrown rather than as it was collected.
class _Failure {
  final Object error;
  final StackTrace stackTrace;
  const _Failure(this.error, this.stackTrace);
}
