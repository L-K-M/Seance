import 'dart:async';

typedef CleanupAction = FutureOr<void> Function();

enum CleanupFailureMode { preserveFirst, ignore }

final class SingleFlightCleanup {
  Future<void>? _result;

  Future<void> run(CleanupAction action) {
    final running = _result;
    if (running != null) return running;

    final completer = Completer<void>();
    _result = completer.future;
    Future<void>.sync(action).then(
      completer.complete,
      onError: (Object error, StackTrace stackTrace) {
        _result = Future<void>.value();
        completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }
}

/// Runs teardown in dependency order and still attempts later resources.
Future<void> runSequentialCleanup(
  Iterable<CleanupAction> actions, {
  required Duration actionTimeout,
  CleanupFailureMode failureMode = CleanupFailureMode.preserveFirst,
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;

  for (final action in actions) {
    try {
      await Future<void>.sync(action).timeout(actionTimeout);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }

  if (firstError == null || failureMode == CleanupFailureMode.ignore) return;
  Error.throwWithStackTrace(firstError, firstStackTrace!);
}
