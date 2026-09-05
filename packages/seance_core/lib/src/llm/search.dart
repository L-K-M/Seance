import 'dart:convert';

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

/// Query several backends at once and merge what comes back.
///
/// Configured means used: a priority chain would quietly ignore the second key
/// someone took the trouble to enter, and "use Z.AI as well as my SearXNG" is
/// a reasonable thing to want. Clearing the other field is how you get "instead
/// of" — so one control shape covers both, with no mode to keep in step.
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
        } catch (error) {
          // One backend being down, rate-limited or misconfigured should not
          // take the search with it. If *every* one failed, the error is
          // re-raised below rather than reported as "nothing found".
          return error;
        }
      }),
    );
    final lists = answers.whereType<List<SearchResult>>().toList();
    if (lists.isEmpty) {
      // Every backend failed. Re-raise the first failure rather than reporting
      // "nothing found", which is a different answer and a misleading one for
      // what is a configuration or outage problem. With no backends at all
      // there is nothing to raise and nothing to find.
      final failure = answers.firstOrNull;
      if (failure != null) throw failure;
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
        if (result.url.isNotEmpty && !seen.add(result.url)) continue;
        merged.add(result);
        if (merged.length == limit) break;
      }
      if (exhausted) break;
    }
    return merged;
  }
}
