import 'dart:async';
import 'dart:developer' as developer;

import 'package:seance_core/seance_core.dart';

import 'secure_master_key.dart';
import 'snippet_source_cache.dart';

/// Keeps each snippet source's fetched snippets, and the outcome of the last
/// attempt, for the Snippets tab.
///
/// Owns the fetch-and-cache half of the feature; the source list itself is
/// owned by `AppState`, which hands every new version of it to
/// [updateSources]. Nothing here writes a store other than the cache, so it
/// needs no place on the app's mutation queue: a refresh can run while a sync
/// round holds it, and a source edited or removed mid-fetch simply has the
/// result thrown away.
class SnippetSourceRefresher {
  SnippetSourceRefresher({
    required this.cache,
    required this.fetcher,
    required this.readToken,
    required this.onChanged,
  });

  final SnippetSourceCache cache;

  /// Read per fetch, so a test can swap the fetcher on its services.
  final SnippetSourceFetcher Function() fetcher;

  /// The token stored under a source's `tokenRef`, or null when this device
  /// does not hold one. Throws when the vault cannot be read.
  final Future<String?> Function(String tokenRef) readToken;

  /// Called whenever anything [stateOf] or [isRefreshing] reports changed.
  final void Function() onChanged;

  List<SnippetSource> _sources = const [];
  Map<String, SnippetSourceState> _states = {};

  /// The refresh running for each source, which a second request joins.
  final Map<String, Future<void>> _inFlight = {};

  /// Refreshes asked for while one for the same source was running. The
  /// running one may be using the old URL or token, so it runs again after.
  final Set<String> _again = {};

  /// Read the cached copies. A cache that cannot be read costs the offline
  /// copies, never startup: the next refresh rebuilds it.
  Future<void> load() async {
    try {
      _states = await cache.load();
    } catch (error, stackTrace) {
      _log('Could not read the snippet source cache', error, stackTrace);
    }
  }

  /// What [source] last fetched, or null before its first attempt. A copy
  /// fetched from a URL the source no longer has is not its copy.
  SnippetSourceState? stateOf(SnippetSource source) {
    final state = _states[source.id];
    return state != null && state.url == source.url ? state : null;
  }

  bool isRefreshing(String id) => _inFlight.containsKey(id);

  bool get anyRefreshing => _inFlight.isNotEmpty;

  /// Adopt the current source list: forget what removed sources fetched, and
  /// fetch every source that has never succeeded at its current URL (added
  /// here, arrived by sync, or re-pointed), unless [fetchNew] is false.
  void updateSources(List<SnippetSource> sources, {bool fetchNew = true}) {
    _sources = List.unmodifiable(sources);
    final ids = {for (final s in sources) s.id};
    final before = _states.length;
    _states.removeWhere((id, _) => !ids.contains(id));
    if (_states.length != before) unawaited(_save());
    if (!fetchNew) return;
    for (final source in sources) {
      if (stateOf(source)?.fetchedAt == null) unawaited(refresh(source.id));
    }
  }

  Future<void> refreshAll() =>
      Future.wait([for (final s in _sources) refresh(s.id)]);

  /// Fetch one source now, completing when its state is up to date. A
  /// request made while one is running joins it, and makes it run once more
  /// afterwards. Failures are recorded on the state, never thrown: the caller
  /// is a button or a background refresh, and both show the state.
  Future<void> refresh(String id) {
    final running = _inFlight[id];
    if (running != null) {
      _again.add(id);
      return running;
    }
    final run = _run(id);
    _inFlight[id] = run;
    onChanged();
    return run;
  }

  Future<void> _run(String id) async {
    // Yield first, so [refresh] has registered this run before it can end.
    await Future<void>.value();
    try {
      await _refreshOnce(id);
      while (_again.remove(id)) {
        await _refreshOnce(id);
      }
    } finally {
      _inFlight.remove(id);
      onChanged();
    }
  }

  Future<void> _refreshOnce(String id) async {
    final source = _find(id);
    if (source == null) return;
    final base = stateOf(source) ?? SnippetSourceState(url: source.url);
    SnippetSourceState next;
    try {
      final ref = source.tokenRef;
      final token = ref == null ? null : await readToken(ref);
      if (ref != null && token == null) {
        throw const SnippetSourceException(
          'The access token for this source is not stored on this device. '
          'Enter it in Settings > Snippets, or turn on credential sync on the '
          'device that has it.',
        );
      }
      final file = await fetcher().fetch(source.url, token: token);
      next = base.fetched(file, DateTime.now());
    } on SnippetSourceException catch (e) {
      next = base.failed(e.message, DateTime.now());
    } on VaultLockedException {
      next = base.failed(
        'The access token cannot be read while the vault is locked. Unlock '
        'the OS keyring and refresh.',
        DateTime.now(),
      );
    } catch (error, stackTrace) {
      // Not a message to show: an unexpected error's text is not known to be
      // free of the token or the URL. Only its type goes to the log.
      _log(
        'Snippet source refresh failed (${error.runtimeType})',
        null,
        stackTrace,
      );
      next = base.failed('Could not refresh this source.', DateTime.now());
    }
    // Edited or removed while the request was out: this result answers a
    // question nobody is asking any more. A changed token is caught by the
    // re-run [refresh] schedules; a changed URL or a removal, here.
    final current = _find(id);
    if (current == null || current.url != source.url) return;
    _states[id] = next;
    await _save();
  }

  SnippetSource? _find(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> _save() async {
    try {
      await cache.save(Map.of(_states));
    } catch (error, stackTrace) {
      _log('Could not write the snippet source cache', error, stackTrace);
    }
  }

  static void _log(String message, Object? error, StackTrace stackTrace) =>
      developer.log(
        message,
        name: 'seance.snippet_sources',
        level: 900,
        error: error,
        stackTrace: stackTrace,
      );
}
