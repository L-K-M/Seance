/// A fixed-window rate limiter, used to blunt online guessing against the login
/// endpoint. Keyed by whatever the caller chooses (username, client IP, or
/// both). The clock is injectable so it can be tested deterministically.
class RateLimiter {
  final int maxAttempts;
  final Duration window;
  final DateTime Function() _now;

  final Map<String, List<DateTime>> _hits = {};

  RateLimiter({
    this.maxAttempts = 10,
    this.window = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Records an attempt for [key] and returns true if it is within the limit,
  /// false if the caller should be throttled.
  bool allow(String key) {
    final now = _now();
    final cutoff = now.subtract(window);
    final hits = (_hits[key] ??= [])
      ..removeWhere((t) => t.isBefore(cutoff));
    if (hits.length >= maxAttempts) return false;
    hits.add(now);
    return true;
  }

  void reset(String key) => _hits.remove(key);
}
