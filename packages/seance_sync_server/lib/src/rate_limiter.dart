/// A fixed-window rate limiter, used to blunt online guessing against the login
/// endpoint. Keyed by whatever the caller chooses (username, client IP, or
/// both). The clock is injectable so it can be tested deterministically.
class RateLimiter {
  static const _sweepInterval = 64;

  final int maxAttempts;
  final Duration window;
  final DateTime Function() _now;

  final Map<String, _Bucket> _buckets = {};
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
    _callsUntilSweep--;
    if (_callsUntilSweep == 0) {
      _buckets.removeWhere((_, bucket) => _isExpired(bucket, now));
      _callsUntilSweep = _sweepInterval;
    }

    var bucket = _buckets[key];
    if (bucket != null && _isExpired(bucket, now)) {
      _buckets.remove(key);
      bucket = null;
    }
    if (bucket != null) {
      if (bucket.attempts >= maxAttempts) return false;
      bucket.attempts++;
      return true;
    }

    _buckets[key] = _Bucket(now);
    return true;
  }

  void reset(String key) => _buckets.remove(key);

  bool _isExpired(_Bucket bucket, DateTime now) =>
      !now.isBefore(bucket.startedAt.add(window));
}

class _Bucket {
  final DateTime startedAt;
  int attempts = 1;

  _Bucket(this.startedAt);
}
