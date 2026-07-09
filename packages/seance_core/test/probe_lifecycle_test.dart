import 'dart:async';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

class _OkProber implements Prober {
  @override
  Future<ProbeStatus> probe(String host, int port,
      {Duration timeout = const Duration(seconds: 5)}) async {
    return ProbeStatus.online;
  }
}

ServerConfig _server(String id) => ServerConfig(
      id: id,
      label: id,
      host: 'h',
      port: 22,
      username: 'u',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  test('pause halts probing; resume re-triggers an immediate sweep', () async {
    final prober = _OkProber();
    // A long interval means only the immediate sweeps (from start/resume) run
    // during the test — the periodic timer never fires.
    final probe =
        ProbeService(prober: prober, interval: const Duration(seconds: 30));
    final events = <Map<String, ProbeStatus>>[];
    final sub = probe.statuses.listen(events.add);

    probe.start([_server('a')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events, isNotEmpty, reason: 'start does an immediate sweep');
    expect(probe.isPaused, isFalse);

    probe.pause();
    expect(probe.isPaused, isTrue);
    final beforeResume = events.length;

    probe.resume();
    expect(probe.isPaused, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events.length, greaterThan(beforeResume),
        reason: 'resume re-triggers an immediate sweep');

    await sub.cancel();
    await probe.dispose();
  });
}
