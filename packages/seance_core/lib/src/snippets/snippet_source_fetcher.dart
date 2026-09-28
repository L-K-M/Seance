import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, SocketException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'snippet_source_file.dart';

/// Why [validateSnippetSourceUrl] refused a URL, or null when it is usable.
///
/// HTTPS only, because the request carries an access token. Plain HTTP is
/// allowed for loopback addresses alone, which is what a local test server
/// needs and cannot leak a token onto a network. Credentials embedded in the
/// URL are refused so they cannot end up in the plaintext, synced source
/// config: the token field, which goes to the vault, is the place for them.
String? validateSnippetSourceUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'Enter a full URL, e.g. https://example.com/snippets.json';
  }
  if (uri.userInfo.isNotEmpty) {
    return 'Put the access token in the token field, not in the URL.';
  }
  switch (uri.scheme) {
    case 'https':
      return null;
    case 'http' when _isLoopback(uri.host):
      return null;
    default:
      return 'Use an https:// URL (plain http is only allowed for localhost).';
  }
}

bool _isLoopback(String host) =>
    host == 'localhost' ||
    host == '127.0.0.1' ||
    host == '::1' ||
    host == '[::1]';

/// Fetches and parses a snippet source file.
///
/// Every failure surfaces as a [SnippetSourceException] whose message is safe
/// to show and to log: it never includes the token, the URL or the response
/// body.
class SnippetSourceFetcher {
  /// For the whole fetch, redirects and body included.
  final Duration timeout;

  /// Largest body accepted. A snippets file is a few kilobytes; anything near
  /// this is not one, and reading it all into memory first would let a
  /// misconfigured URL (a release asset, a log) cost the app its memory.
  final int maxBytes;

  static const Duration defaultTimeout = Duration(seconds: 20);
  static const int defaultMaxBytes = 1024 * 1024;
  static const int _maxRedirects = 5;

  final http.Client _client;

  SnippetSourceFetcher({
    http.Client? client,
    this.timeout = defaultTimeout,
    this.maxBytes = defaultMaxBytes,
  }) : _client = client ?? http.Client();

  void close() => _client.close();

  /// Fetch [url], sending `Authorization: Bearer <token>` when [token] is
  /// non-empty.
  ///
  /// Redirects are followed by hand rather than by the HTTP client, so the
  /// token goes only to the origin the user entered: a redirect to another
  /// host (a CDN, or a hostile server) is followed without it. Each hop must
  /// pass [validateSnippetSourceUrl] too, so a redirect cannot downgrade the
  /// request to plain HTTP.
  Future<SnippetSourceFile> fetch(String url, {String? token}) async {
    final invalid = validateSnippetSourceUrl(url);
    if (invalid != null) throw SnippetSourceException(invalid);
    final deadline = Stopwatch()..start();
    Duration remaining() {
      final left = timeout - deadline.elapsed;
      return left.isNegative ? Duration.zero : left;
    }

    final start = Uri.parse(url.trim());
    final bearer = token?.trim() ?? '';
    var uri = start;
    for (var hop = 0; ; hop++) {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Accept'] = 'application/json'
        ..headers['User-Agent'] = 'Seance-snippet-source';
      if (bearer.isNotEmpty && _sameOrigin(uri, start)) {
        request.headers['Authorization'] = 'Bearer $bearer';
      }

      final http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(remaining());
      } on TimeoutException {
        throw _timedOut();
      } on HandshakeException {
        throw SnippetSourceException(
          'Could not establish a secure connection to ${uri.host}.',
        );
      } on SocketException {
        throw SnippetSourceException('Could not reach ${uri.host}.');
      } on http.ClientException {
        throw SnippetSourceException('Could not reach ${uri.host}.');
      }

      final status = response.statusCode;
      if (status >= 300 && status < 400 && status != 304) {
        _discard(response);
        final location = response.headers['location'];
        if (location == null || hop >= _maxRedirects) {
          throw SnippetSourceException(
            location == null
                ? 'The server answered HTTP $status without a location.'
                : 'Too many redirects.',
          );
        }
        final next = uri.resolve(location);
        final refused = validateSnippetSourceUrl(next.toString());
        if (refused != null) {
          throw const SnippetSourceException(
            'The server redirected to an address Séance will not fetch '
            '(plain http or embedded credentials).',
          );
        }
        uri = next;
        continue;
      }
      if (status != 200) {
        _discard(response);
        throw SnippetSourceException(_describeStatus(status, bearer.isEmpty));
      }
      // A private file fetched without access is often not an error status
      // at all: Forgejo, for one, redirects to its sign-in page, which then
      // answers 200. "Not valid JSON" would be true and useless.
      final type = response.headers['content-type'] ?? '';
      if (type.toLowerCase().startsWith('text/html')) {
        _discard(response);
        throw SnippetSourceException(
          'Got a web page instead of the snippets file, usually a sign-in '
          'page. Check that the URL points at the raw file'
          '${bearer.isEmpty ? ' and that this source does not need an access '
                    'token.' : ' and that the access token is valid.'}',
        );
      }
      final length = response.contentLength;
      if (length != null && length > maxBytes) {
        _discard(response);
        throw _tooLarge();
      }

      final bytes = await _readCapped(response.stream, remaining());
      final String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        throw const SnippetSourceException('The file is not UTF-8 text.');
      }
      return SnippetSourceFile.parse(text);
    }
  }

  /// Collect the body, giving up as soon as it passes [maxBytes] or the time
  /// runs out — cancelling the subscription either way, so an oversized or
  /// stalled body stops downloading rather than finishing unobserved.
  Future<Uint8List> _readCapped(Stream<List<int>> stream, Duration left) {
    final done = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    late final StreamSubscription<List<int>> subscription;
    void fail(SnippetSourceException error) {
      if (done.isCompleted) return;
      unawaited(subscription.cancel());
      done.completeError(error);
    }

    final timer = Timer(left, () => fail(_timedOut()));
    subscription = stream.listen(
      (chunk) {
        builder.add(chunk);
        if (builder.length > maxBytes) fail(_tooLarge());
      },
      onError: (Object _) =>
          fail(const SnippetSourceException('The download was interrupted.')),
      onDone: () {
        if (!done.isCompleted) done.complete(builder.takeBytes());
      },
      cancelOnError: true,
    );
    return done.future.whenComplete(timer.cancel);
  }

  void _discard(http.StreamedResponse response) =>
      unawaited(response.stream.listen(null).cancel());

  SnippetSourceException _timedOut() =>
      SnippetSourceException('Timed out after ${timeout.inSeconds} s.');

  SnippetSourceException _tooLarge() => SnippetSourceException(
    'The file is larger than ${maxBytes ~/ 1024} KB, which is more than '
    'a snippets file should be.',
  );

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  static String _describeStatus(int status, bool withoutToken) =>
      switch (status) {
        401 || 403 =>
          withoutToken
              ? 'Access denied (HTTP $status). This source needs an access '
                    'token.'
              : 'Access denied (HTTP $status). Check the access token.',
        // Forgejo, GitHub and GitLab all answer a private file fetched
        // without access with 404 rather than 401, so say both.
        404 =>
          'Not found (HTTP 404). Check the URL, and the access token if '
              'the repository is private.',
        _ => 'The server answered HTTP $status.',
      };
}
