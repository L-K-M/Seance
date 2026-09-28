import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

import 'atomic_file.dart';

/// What this device knows about one snippet source: the last copy it fetched
/// successfully, and how the latest attempt went.
///
/// Device-local on purpose. The source's configuration syncs; what it serves
/// does not, since every device can fetch it, and a copy relayed through the
/// sync server would be one more place for a private repository's content to
/// live.
@immutable
class SnippetSourceState {
  const SnippetSourceState({
    required this.url,
    this.snippets = const [],
    this.skipped = 0,
    this.fetchedAt,
    this.error,
    this.errorAt,
  });

  /// The URL [snippets] came from. A source whose URL has since changed must
  /// not keep showing the old file's snippets as its own.
  final String url;

  /// The last good copy: kept through failed refreshes, for offline use.
  final List<Snippet> snippets;

  /// Entries of that copy the parser skipped as invalid.
  final int skipped;

  /// When [snippets] was fetched; null when no fetch has succeeded yet.
  final DateTime? fetchedAt;

  /// Why the latest attempt failed, or null when it succeeded. A message from
  /// [SnippetSourceException], which never carries the token.
  final String? error;
  final DateTime? errorAt;

  /// The state after a successful fetch at [at].
  SnippetSourceState fetched(SnippetSourceFile file, DateTime at) =>
      SnippetSourceState(
        url: url,
        snippets: file.snippets,
        skipped: file.skipped,
        fetchedAt: at,
      );

  /// The state after a failed attempt: the last good copy stays.
  SnippetSourceState failed(String message, DateTime at) => SnippetSourceState(
    url: url,
    snippets: snippets,
    skipped: skipped,
    fetchedAt: fetchedAt,
    error: message,
    errorAt: at,
  );

  factory SnippetSourceState.fromJson(Map<String, dynamic> json) {
    DateTime? time(String key) => json[key] is int
        ? DateTime.fromMillisecondsSinceEpoch(json[key] as int)
        : null;
    return SnippetSourceState(
      url: json['url'] as String,
      snippets: [
        for (final s in json['snippets'] as List? ?? const [])
          Snippet.fromJson((s as Map).cast<String, dynamic>()),
      ],
      skipped: json['skipped'] as int? ?? 0,
      fetchedAt: time('fetchedAt'),
      error: json['error'] as String?,
      errorAt: time('errorAt'),
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'snippets': [
      for (final s in snippets) {'id': s.id, 'title': s.title, 'body': s.body},
    ],
    if (skipped != 0) 'skipped': skipped,
    if (fetchedAt != null) 'fetchedAt': fetchedAt!.millisecondsSinceEpoch,
    if (error != null) 'error': error,
    if (errorAt != null) 'errorAt': errorAt!.millisecondsSinceEpoch,
  };
}

/// Persists [SnippetSourceState]s keyed by source id, so snippets fetched
/// once stay usable offline and across restarts.
///
/// Owner-only on disk: the file holds a private repository's content. A cache
/// is disposable, so an unreadable file is quarantined and read as empty; the
/// next refresh fills it again.
class SnippetSourceCache {
  SnippetSourceCache(this.file);

  final File file;

  Future<Map<String, SnippetSourceState>> load() async {
    if (!await file.exists()) return {};
    try {
      final json = (jsonDecode(await file.readAsString()) as Map)
          .cast<String, dynamic>();
      return {
        for (final e in json.entries)
          e.key: SnippetSourceState.fromJson(
            (e.value as Map).cast<String, dynamic>(),
          ),
      };
    } catch (_) {
      await quarantineCorruptFile(file);
      return {};
    }
  }

  Future<void> save(Map<String, SnippetSourceState> states) =>
      writeStringAtomically(
        file,
        jsonEncode({for (final e in states.entries) e.key: e.value.toJson()}),
        privacy: AtomicFilePrivacy.ownerOnly,
      );
}
