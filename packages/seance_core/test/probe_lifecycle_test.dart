import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

const _interval = Duration(seconds: 30);
const _longPause = Duration(minutes: 5);

/// Completers keep sockets in flight while lifecycle changes race the sweep.
class _GatedProber implements Prober {
  final _hosts = <String>[];
  final _ports = <int>[];
  final _pending = <Completer<ProbeStatus>>[];
  int _inFlight = 0;
  int _peakInFlight = 0;

  @override
  Future<ProbeStatus> probe(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _hosts.add(host);
    _ports.add(port);
    final pending = Completer<ProbeStatus>();
    _pending.add(pending);
    _inFlight++;
    _peakInFlight = max(_peakInFlight, _inFlight);

    try {
      return await pending.future;
    } finally {
      _inFlight--;
    }
  }

  void _complete(int index) => _pending[index].complete(ProbeStatus.online);

  void _fail(int index) => _pending[index].completeError(StateError('probe'));
}

class _FixedRandom implements Random {
  @override
  double nextDouble() => 0.5;

  @override
  bool nextBool() => throw UnsupportedError('Only jitter is expected');

  @override
  int nextInt(int max) => throw UnsupportedError('Only jitter is expected');
}

ServerConfig _server(String id) => ServerConfig(
  id: id,
  label: id,
  host: id,
  username: 'u',
  createdAt: 0,
  updatedAt: 0,
);

ProbeService _service(_GatedProber prober) => ProbeService(
  prober: prober,
  interval: _interval,
  maxConcurrentProbes: 2,
  random: _FixedRandom(),
);

void main() {
  test(
    'equivalent target updates preserve the active sweep and latest order',
    () {
      fakeAsync((clock) {
        final prober = _GatedProber();
        final service = _service(prober);
        final events = <Map<String, ProbeStatus>>[];
        service.statuses.listen(events.add);
        final initial = [_server('a'), _server('b'), _server('queued')];
        service.start(initial);
        clock.elapse(Duration.zero);
        service.updateServers(initial);
        final rebuilt = [
          for (final server in initial.reversed)
            server.copyWith(
              label: 'Renamed',
              username: 'other-user',
              authMethod: AuthMethod.privateKey,
              updatedAt: 1,
            ),
        ];
        service.updateServers(rebuilt);
        rebuilt.clear();

        prober._complete(0);
        clock.flushMicrotasks();
        expect(prober._hosts, ['a', 'b', 'queued']);
        prober._complete(1);
        prober._complete(2);
        clock.flushMicrotasks();
        expect(events.single.keys, unorderedEquals(['a', 'b', 'queued']));
        clock.elapse(_interval);
        expect(prober._hosts, ['a', 'b', 'queued', 'queued', 'b']);
        unawaited(service.dispose());
        prober._complete(3);
        prober._complete(4);
        clock.flushMicrotasks();
      });
    },
  );

  test('explicit same-target start invalidates and restarts after drain', () {
    fakeAsync((clock) {
      final prober = _GatedProber();
      final service = _service(prober);
      final events = <Map<String, ProbeStatus>>[];
      service.statuses.listen(events.add);
      final targets = [_server('a'), _server('b'), _server('queued')];
      service.start(targets);
      clock.elapse(Duration.zero);
      service.start(targets);
      prober._complete(0);
      clock.elapse(Duration.zero);
      expect(prober._hosts, ['a', 'b']);
      prober._complete(1);
      clock.elapse(Duration.zero);
      expect(prober._hosts, ['a', 'b', 'a', 'b']);
      expect(events, isEmpty);
      expect(prober._peakInFlight, 2);
      unawaited(service.dispose());
      prober._complete(2);
      prober._complete(3);
      clock.flushMicrotasks();
    });
  });

  for (final (field, replacement) in [
    ('host', _server('a').copyWith(host: 'new-host')),
    ('port', _server('a').copyWith(port: 2222)),
    ('id', _server('new-id').copyWith(host: 'a')),
  ]) {
    test('changing target $field invalidates its in-flight status', () {
      fakeAsync((clock) {
        final prober = _GatedProber();
        final service = _service(prober);
        final events = <Map<String, ProbeStatus>>[];
        service.statuses.listen(events.add);
        service.start([_server('a')]);
        clock.elapse(Duration.zero);
        service.updateServers([replacement]);
        prober._complete(0);
        clock.flushMicrotasks();
        expect(events, isEmpty);
        clock.elapse(_interval);
        expect(prober._hosts.last, replacement.host);
        expect(prober._ports.last, replacement.port);
        prober._complete(1);
        clock.flushMicrotasks();
        expect(events.single, {replacement.id: ProbeStatus.online});
        unawaited(service.dispose());
        clock.flushMicrotasks();
      });
    });
  }

  test('pause drops results and queued hosts; resume probes immediately', () {
    fakeAsync((clock) {
      final prober = _GatedProber();
      final service = _service(prober);
      final events = <Map<String, ProbeStatus>>[];
      service.statuses.listen(events.add);
      service.start([_server('a'), _server('b'), _server('queued')]);
      clock.elapse(Duration.zero);
      expect(prober._hosts, ['a', 'b']);

      service.pause();
      prober._complete(0);
      prober._complete(1);
      clock.flushMicrotasks();
      expect(prober._hosts, ['a', 'b']);
      expect(events, isEmpty);
      expect(service.isPaused, isTrue);
      expect(clock.pendingTimers, isEmpty);
      clock.elapse(_longPause);

      service.resume();
      clock.elapse(Duration.zero);
      expect(service.isPaused, isFalse);
      expect(prober._hosts, ['a', 'b', 'a', 'b']);
      prober._complete(2);
      clock.flushMicrotasks();
      expect(prober._hosts.last, 'queued');
      prober._complete(3);
      prober._complete(4);
      clock.flushMicrotasks();
      expect(events.single.keys, unorderedEquals(['a', 'b', 'queued']));
      expect(prober._peakInFlight, 2);
      unawaited(service.dispose());
      clock.flushMicrotasks();
    });
  });

  test('resume waits for every old probe before starting one fresh sweep', () {
    fakeAsync((clock) {
      final prober = _GatedProber();
      final service = _service(prober);
      final events = <Map<String, ProbeStatus>>[];
      service.statuses.listen(events.add);
      service.start([_server('a'), _server('b'), _server('queued')]);
      clock.elapse(Duration.zero);

      service.pause();
      service.resume();
      service.pause();
      service.resume();
      clock.elapse(_longPause);
      expect(prober._hosts, ['a', 'b']);
      prober._complete(0);
      clock.elapse(Duration.zero);
      expect(prober._hosts, ['a', 'b']);

      prober._complete(1);
      clock.elapse(Duration.zero);
      expect(prober._hosts, ['a', 'b', 'a', 'b']);
      expect(events, isEmpty);
      expect(prober._peakInFlight, 2);
      unawaited(service.dispose());
      prober._complete(2);
      prober._complete(3);
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test(
    'repeated start coalesces to the latest immutable targets after drain',
    () {
      fakeAsync((clock) {
        final prober = _GatedProber();
        final service = _service(prober);
        final events = <Map<String, ProbeStatus>>[];
        service.statuses.listen(events.add);
        service.start([
          _server('old-a'),
          _server('old-b'),
          _server('old-queued'),
        ]);
        clock.elapse(Duration.zero);

        service.start([_server('superseded')]);
        final latest = [_server('latest')];
        service.start(latest);
        latest[0] = _server('caller-mutation');
        clock.elapse(_longPause);
        expect(prober._hosts, ['old-a', 'old-b']);
        prober._complete(0);
        clock.elapse(Duration.zero);
        expect(prober._hosts, ['old-a', 'old-b']);
        prober._complete(1);
        clock.elapse(Duration.zero);
        expect(prober._hosts, ['old-a', 'old-b', 'latest']);
        expect(events, isEmpty);

        prober._complete(2);
        clock.flushMicrotasks();
        expect(events.single, {'latest': ProbeStatus.online});
        expect(prober._peakInFlight, 2);
        expect(clock.pendingTimers, hasLength(1));
        clock.elapse(_interval);
        expect(prober._hosts, ['old-a', 'old-b', 'latest', 'latest']);
        unawaited(service.dispose());
        prober._complete(3);
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'update cancels old targets and preserves cadence after probes drain',
    () {
      fakeAsync((clock) {
        final prober = _GatedProber();
        final service = _service(prober);
        final events = <Map<String, ProbeStatus>>[];
        service.statuses.listen(events.add);
        service.start([
          _server('old-a'),
          _server('old-b'),
          _server('old-queued'),
        ]);
        clock.elapse(Duration.zero);
        service.updateServers([_server('superseded')]);
        final latest = [_server('latest')];
        service.updateServers(latest);
        latest.clear();
        clock.elapse(_longPause);
        expect(prober._hosts, ['old-a', 'old-b']);

        prober._complete(0);
        clock.flushMicrotasks();
        expect(prober._hosts, ['old-a', 'old-b']);
        prober._complete(1);
        clock.elapse(Duration.zero);
        expect(events, isEmpty);
        expect(prober._hosts, ['old-a', 'old-b']);
        clock.elapse(_interval);
        expect(prober._hosts, ['old-a', 'old-b', 'latest']);
        prober._complete(2);
        clock.flushMicrotasks();
        expect(events.single, {'latest': ProbeStatus.online});
        unawaited(service.dispose());
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'updates before start stay inert and start while paused stays paused',
    () {
      fakeAsync((clock) {
        final prober = _GatedProber();
        final service = _service(prober);
        service.updateServers([_server('before-start')]);
        clock.elapse(_longPause);
        expect(clock.pendingTimers, isEmpty);
        expect(prober._hosts, isEmpty);

        service.pause();
        service.start([_server('paused-start')]);
        service.updateServers([_server('paused-update')]);
        clock.elapse(_longPause);
        expect(prober._hosts, isEmpty);
        service.resume();
        clock.elapse(Duration.zero);
        expect(prober._hosts, ['paused-update']);
        unawaited(service.dispose());
        prober._complete(0);
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'updates during the interval retain its deadline; active resume is inert',
    () {
      fakeAsync((clock) {
        final prober = _GatedProber();
        final service = _service(prober);
        service.start([_server('first')]);
        clock.elapse(Duration.zero);
        prober._complete(0);
        clock.flushMicrotasks();
        clock.elapse(_interval ~/ 2);
        service.resume();
        final targets = [_server('second')];
        service.updateServers(targets);
        targets.clear();
        clock.elapse(Duration.zero);
        expect(prober._hosts, ['first']);
        clock.elapse(_interval ~/ 2);
        expect(prober._hosts, ['first', 'second']);
        unawaited(service.dispose());
        prober._complete(1);
        clock.flushMicrotasks();
      });
    },
  );

  test('dispose stops queued hosts and cannot be restarted', () {
    fakeAsync((clock) {
      final prober = _GatedProber();
      final service = _service(prober);
      final events = <Map<String, ProbeStatus>>[];
      service.statuses.listen(events.add);
      service.start([_server('a'), _server('b'), _server('queued')]);
      clock.elapse(Duration.zero);
      unawaited(service.dispose());
      service.pause();
      service.resume();
      service.start([_server('after-dispose')]);
      service.updateServers([_server('after-dispose-update')]);
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);

      prober._complete(0);
      prober._complete(1);
      clock.flushMicrotasks();
      clock.elapse(_longPause);
      expect(prober._hosts, ['a', 'b']);
      expect(events, isEmpty);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('pause cancels a pending restart even when an old probe fails', () {
    fakeAsync((clock) {
      final prober = _GatedProber();
      final service = _service(prober);
      final events = <Map<String, ProbeStatus>>[];
      service.statuses.listen(events.add);
      service.start([_server('a'), _server('b'), _server('queued')]);
      clock.elapse(Duration.zero);
      service.start([_server('replacement')]);
      service.pause();
      prober._fail(0);
      prober._complete(1);
      clock.elapse(_longPause);
      expect(prober._hosts, ['a', 'b']);
      expect(events, isEmpty);
      expect(clock.pendingTimers, isEmpty);

      service.resume();
      clock.elapse(Duration.zero);
      expect(prober._hosts, ['a', 'b', 'replacement']);
      prober._fail(2);
      clock.flushMicrotasks();
      expect(events.single, {'replacement': ProbeStatus.unknown});
      unawaited(service.dispose());
      clock.flushMicrotasks();
    });
  });

  test('removing all targets drops an in-flight snapshot', () {
    fakeAsync((clock) {
      final prober = _GatedProber();
      final service = _service(prober);
      final events = <Map<String, ProbeStatus>>[];
      service.statuses.listen(events.add);
      service.start([_server('removed')]);
      clock.elapse(Duration.zero);
      service.updateServers([]);
      prober._complete(0);
      clock.elapse(_longPause);
      expect(events, isEmpty);
      expect(prober._hosts, ['removed']);
      unawaited(service.dispose());
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('a failed connected-server lookup recovers on the next interval', () {
    fakeAsync((clock) {
      final prober = _GatedProber();
      final service = _service(prober);
      final events = <Map<String, ProbeStatus>>[];
      service.statuses.listen(events.add);
      service.connectedServerIds = () => throw StateError('lookup');
      service.start([_server('live'), _server('idle')]);
      clock.elapse(Duration.zero);
      expect(events, isEmpty);
      expect(prober._hosts, isEmpty);
      expect(clock.pendingTimers, hasLength(1));

      service.connectedServerIds = () => {'live'};
      clock.elapse(_interval);
      expect(prober._hosts, ['idle']);
      prober._complete(0);
      clock.flushMicrotasks();
      expect(events.single, {
        'live': ProbeStatus.online,
        'idle': ProbeStatus.online,
      });
      unawaited(service.dispose());
      clock.flushMicrotasks();
    });
  });

  test('standalone probeAll completes despite periodic lifecycle changes', () {
    fakeAsync((clock) {
      final prober = _GatedProber();
      final service = _service(prober);
      Map<String, ProbeStatus>? result;
      service
          .probeAll(
            [_server('live'), _server('a'), _server('b'), _server('queued')],
            alreadyConnected: {'live'},
          )
          .then((statuses) => result = statuses);
      service.pause();
      service.updateServers([]);
      unawaited(service.dispose());
      prober._complete(0);
      clock.flushMicrotasks();
      expect(prober._hosts, ['a', 'b', 'queued']);
      prober._complete(1);
      prober._complete(2);
      clock.flushMicrotasks();
      expect(result, {
        'live': ProbeStatus.online,
        'a': ProbeStatus.online,
        'b': ProbeStatus.online,
        'queued': ProbeStatus.online,
      });
      expect(prober._peakInFlight, 2);
    });
  });
}
