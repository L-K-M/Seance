import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:test/test.dart';

void main() {
  group('RateLimiter', () {
    late DateTime now;

    setUp(() {
      now = DateTime.utc(2026, 1, 1);
    });

    test('globally removes stale unrelated buckets after the sweep cadence', () {
      const sweepInterval = 64;
      final startedAt = now;
      final limiter = RateLimiter(
        maxAttempts: 1,
        window: const Duration(minutes: 1),
        now: () => now,
      );

      expect(limiter.allow('stale'), isTrue);
      now = now.add(const Duration(minutes: 1));
      for (var i = 0; i < sweepInterval - 1; i++) {
        expect(limiter.allow('unrelated-$i'), isTrue);
      }

      // Rewinding makes removal observable without exposing limiter internals.
      now = startedAt;
      expect(limiter.allow('stale'), isTrue);
    });

    test('does not perform a global sweep on every call', () {
      final startedAt = now;
      final limiter = RateLimiter(
        maxAttempts: 1,
        window: const Duration(minutes: 1),
        now: () => now,
      );

      expect(limiter.allow('stale'), isTrue);
      now = now.add(const Duration(minutes: 1));
      expect(limiter.allow('unrelated'), isTrue);

      // The stale bucket remains before the cadence, so at its original clock
      // value its consumed attempt is still enforced.
      now = startedAt;
      expect(limiter.allow('stale'), isFalse);
    });

    test('expires the requested key without waiting for a sweep', () {
      final limiter = RateLimiter(
        maxAttempts: 1,
        window: const Duration(minutes: 1),
        now: () => now,
      );

      expect(limiter.allow('alice'), isTrue);
      expect(limiter.allow('alice'), isFalse);
      now = now.add(const Duration(minutes: 1));
      expect(limiter.allow('alice'), isTrue);
    });

    test('never blocks new keys because other keys are active', () {
      final limiter = RateLimiter(maxAttempts: 1, now: () => now);

      expect(limiter.allow('known'), isTrue);
      expect(limiter.allow('known'), isFalse);
      for (var i = 0; i < 10001; i++) {
        expect(limiter.allow('new-$i'), isTrue);
      }
    });

    test('uses a sliding window with an inclusive expiry cutoff', () {
      final limiter = RateLimiter(
        maxAttempts: 2,
        window: const Duration(minutes: 1),
        now: () => now,
      );

      expect(limiter.allow('alice'), isTrue);
      now = now.add(const Duration(seconds: 59));
      expect(limiter.allow('alice'), isTrue);
      expect(limiter.allow('alice'), isFalse);

      // At t=60 the t=0 hit expires, but the t=59 hit still counts.
      now = now.add(const Duration(seconds: 1));
      expect(limiter.allow('alice'), isTrue);
      expect(limiter.allow('alice'), isFalse);
    });

    test('reset removes attempts', () {
      final limiter = RateLimiter(maxAttempts: 1, now: () => now);

      expect(limiter.allow('alice'), isTrue);
      expect(limiter.allow('alice'), isFalse);
      limiter.reset('alice');
      expect(limiter.allow('alice'), isTrue);
    });

    test('rejects invalid maxAttempts', () {
      expect(() => RateLimiter(maxAttempts: 0), throwsArgumentError);
      expect(() => RateLimiter(maxAttempts: -1), throwsArgumentError);
    });

    test('rejects invalid window', () {
      expect(() => RateLimiter(window: Duration.zero), throwsArgumentError);
      expect(
        () => RateLimiter(window: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });
}
