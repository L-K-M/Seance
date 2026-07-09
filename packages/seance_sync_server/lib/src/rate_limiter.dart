/// A sliding-window rate limiter, used to blunt online guessing against the
/// login endpoint. Keyed by whatever the caller chooses (username, client IP,
/// or both). The clock is injectable so it can be tested deterministically.
///
/// Each key retains at most [maxAttempts] timestamps. The requested key is
/// pruned on every call, while all keys are swept every 64 calls so stale
/// one-off keys are eventually removed without scanning the map per request.
/// A hit at exactly `now - window` is expired.
class RateLimiter {
  static const _sweepInterval = 64;

  final int maxAttempts;
  final Duration window;
  final DateTime Function() _now;

  final Map<String, List<DateTime>> _hits = {};
  int _callsUntilSweep = _sweepInterval;

  RateLimiter({
    this.maxAttempts = 10,
    this.window = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (maxAttempts <= 0) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        'must be greater than zero',
      );
    }
    if (window <= Duration.zero) {
      throw ArgumentError.value(window, 'window', 'must be greater than zero');
    }
  }

  /// Records an attempt for [key] and returns true if it is within the limit,
  /// false if the caller should be throttled.
  bool allow(String key) {
    final now = _now();
    final cutoff = now.subtract(window);
    _callsUntilSweep--;
    if (_callsUntilSweep == 0) {
      _hits.removeWhere((_, hits) {
        _removeExpired(hits, cutoff);
        return hits.isEmpty;
      });
      _callsUntilSweep = _sweepInterval;
    }

    var hits = _hits[key];
    if (hits != null) {
      _removeExpired(hits, cutoff);
      if (hits.isEmpty) {
        _hits.remove(key);
        hits = null;
      }
    }
    if (hits == null) {
      hits = [];
      _hits[key] = hits;
    }

    if (hits.length >= maxAttempts) return false;
    hits.add(now);
    return true;
  }

  void reset(String key) => _hits.remove(key);

  void _removeExpired(List<DateTime> hits, DateTime cutoff) {
    hits.removeWhere((hit) => !hit.isAfter(cutoff));
  }
}
