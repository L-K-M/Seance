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
  final http.Client _client;

  SearxngSearch({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    final uri = Uri.parse('$baseUrl/search').replace(queryParameters: {
      'q': query,
      'format': 'json',
    });
    final res = await _client.get(uri);
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
  final http.Client _client;

  BraveSearch({
    required this.apiKey,
    this.baseUrl = 'https://api.search.brave.com',
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    final uri = Uri.parse('$baseUrl/res/v1/web/search')
        .replace(queryParameters: {'q': query, 'count': '$limit'});
    final res = await _client.get(uri, headers: {
      'accept': 'application/json',
      'x-subscription-token': apiKey,
    });
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
