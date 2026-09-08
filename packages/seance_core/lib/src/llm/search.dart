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
/// Hoisted: `_dedupKey` runs once per result from every backend, and Dart
/// compiles a pattern per construction.
final RegExp _trailingSlashes = RegExp(r'/+$');

String _dedupKey(String url) {
  final parsed = Uri.tryParse(url);
  // The fragment goes on both branches: dropping it is the identity rule
  // this function documents, and applying it only to URLs that parse made
  // `…#a` and `…#b` two results for one malformed page.
  final withoutFragment = parsed == null
      ? url.split('#').first
      : parsed.removeFragment().toString();
  // The path ends at the first '?', so its trailing '/' can be dropped
  // without touching a slash that is *data* inside a query value
  // (`?next=/docs/` keeps its own). Skipping the strip whenever a query was
  // present was the safe half of that and cost the common case: two backends
  // that disagree only about `…/docs/?q=1` versus `…/docs?q=1` both spent a
  // slot on the same page, and a real result fell off the end of the limit.
  final queryStart = withoutFragment.indexOf('?');
  final path = queryStart == -1
      ? withoutFragment
      : withoutFragment.substring(0, queryStart);
  final query = queryStart == -1 ? '' : withoutFragment.substring(queryStart);
  return path.replaceFirst(_trailingSlashes, '') + query;
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
            name: searchLoggerName,
            level: searchWarningLogLevel,
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
        // An empty key is no identity: the prose fallback carries one, and
        // two backends' prose are two answers, not one page twice.
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

/// [text] cut to [max] UTF-16 code units and closed with an ellipsis, or
/// returned as it is when it already fits.
///
/// The cut backs off one unit when the cap would fall inside a surrogate
/// pair, so an ellipsis never lands between the halves of an emoji and the
/// result never carries a lone surrogate that serializes as U+FFFD. Shared
/// rather than copied: the snippet cap and the parameter-name echo in
/// `ZaiSearch.buildArguments` apply the same subtle rule, and two copies of
/// it drift.
///
/// [max] bounds the kept content, not the result: a clipped string is one
/// unit longer for the ellipsis. Every cap here is a token budget rather than
/// a length a server enforces, so the extra unit costs nothing — a caller
/// that does have a hard limit has to pass `max - 1`.
///
/// A cap of zero or less yields the empty string. Nothing asks for one today
/// (every caller passes a constant), but this is a shared public helper, and
/// indexing at `max - 1` for the surrogate check turns a nonsensical argument
/// into a `RangeError` from inside a text-clipping utility.
String clipText(String text, int max) {
  if (max <= 0) return '';
  if (text.length <= max) return text;
  final unit = text.codeUnitAt(max - 1);
  final cut = (unit & 0xFC00) == 0xD800 ? max - 1 : max;
  return '${text.substring(0, cut)}…';
}

/// The length past which a URL is not a real one.
///
/// One ceiling rather than one per backend, because the two ends treat the
/// same number differently: `ZaiSearch` refuses a link longer than this
/// outright (a truncated link is a link that lies), and the chat controller
/// clips one it is handed, since by then dropping the result would lose the
/// title and snippet with it. Set apart, a clip threshold below the reject
/// threshold would turn every URL between them into an ellipsis-ended dead
/// link — the exact outcome the refusal exists to avoid.
const int maxSearchUrlChars = 2048;

/// Warning, for every record of a search backend going quiet — the one this
/// file writes when a backend fails mid-search, and the app's when one is
/// dropped before the search starts. Public so the two cannot drift: they are
/// halves of one signal, and a filter set at this level should see both.
const int searchWarningLogLevel = 900;
/// The channel both halves of the search signal write to. Public for the same
/// reason the level is: the app records a backend dropped before the search
/// starts, this file records one that fails during it, and a filter set on
/// this name should see both.
const String searchLoggerName = 'seance.search';

/// One backend's failure, kept with its stack so [CompositeSearch] can re-raise
/// it as it was thrown rather than as it was collected.
class _Failure {
  final Object error;
  final StackTrace stackTrace;
  const _Failure(this.error, this.stackTrace);
}
