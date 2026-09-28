import 'dart:convert';

import 'package:seance_protocol/seance_protocol.dart';

/// A snippet source could not be fetched or read. [message] is written for the
/// user and never carries the access token, the response body or the URL
/// (which may hold credentials of its own in its query).
class SnippetSourceException implements Exception {
  final String message;
  const SnippetSourceException(this.message);

  @override
  String toString() => message;
}

/// The one file format version this build reads.
const int snippetSourceFormatVersion = 1;

/// The parsed contents of a snippet source file:
///
/// ```json
/// {"version": 1, "snippets": [
///   {"id": "stable-kebab-id", "title": "What it does", "body": "the command"}
/// ]}
/// ```
///
/// Unknown fields are ignored at both levels, so the format can grow without a
/// version bump. A wrong version or a malformed file fails as a whole; an
/// individual entry that is not usable (not an object, a missing or blank id,
/// title or body, an id already seen) is skipped and counted in [skipped], so
/// one bad entry does not take the rest of the file with it.
///
/// The content is untrusted. Nothing here runs it: the snippets are inserted
/// through the same placeholder and paste-sanitizing path as local ones, which
/// refuses line breaks and strips control characters.
class SnippetSourceFile {
  final List<Snippet> snippets;
  final int skipped;

  const SnippetSourceFile({required this.snippets, this.skipped = 0});

  factory SnippetSourceFile.parse(String text) {
    final Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException {
      throw const SnippetSourceException('The file is not valid JSON.');
    }
    if (root is! Map) {
      throw const SnippetSourceException(
        'Expected a JSON object with "version" and "snippets".',
      );
    }
    final version = root['version'];
    if (version != snippetSourceFormatVersion) {
      throw SnippetSourceException(
        version == null
            ? 'The file has no "version"; expected $snippetSourceFormatVersion.'
            : 'Unsupported format version ${jsonEncode(version)}; this '
                  'Séance reads version $snippetSourceFormatVersion.',
      );
    }
    final entries = root['snippets'];
    if (entries is! List) {
      throw const SnippetSourceException('"snippets" must be a list.');
    }

    final snippets = <Snippet>[];
    final seen = <String>{};
    var skipped = 0;
    for (final entry in entries) {
      final snippet = _entry(entry);
      if (snippet == null || !seen.add(snippet.id)) {
        skipped++;
        continue;
      }
      snippets.add(snippet);
    }
    return SnippetSourceFile(snippets: snippets, skipped: skipped);
  }

  static Snippet? _entry(Object? entry) {
    if (entry is! Map) return null;
    final id = entry['id'];
    final title = entry['title'];
    final body = entry['body'];
    if (id is! String || title is! String || body is! String) return null;
    if (id.trim().isEmpty || title.trim().isEmpty || body.trim().isEmpty) {
      return null;
    }
    // Timestamps are meaningless for a snippet nobody edits here; zero keeps
    // them out of any comparison.
    return Snippet(
      id: id.trim(),
      title: title.trim(),
      body: body,
      createdAt: 0,
      updatedAt: 0,
    );
  }
}
