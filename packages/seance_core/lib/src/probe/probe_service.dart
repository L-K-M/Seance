import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:seance_protocol/seance_protocol.dart';

/// Reachability of a configured server.
///
/// [unknown] is deliberately distinct from [offline]: a host behind a jump
/// host, VPN, or Tailscale may be perfectly alive yet unreachable by a direct
/// probe. Reporting that as "offline" would be a lie, so the UI shows a third,
/// muted state instead.
enum ProbeStatus { online, offline, unknown }

/// Probes a single endpoint. Injected so the periodic service can be tested
/// without real sockets.
abstract class Prober {
  Future<ProbeStatus> probe(String host, int port,
      {Duration timeout = const Duration(seconds: 5)});
}

/// Real prober: opens a TCP connection and reads the SSH identification banner.
/// A refused connection is [offline]; a timeout or network error is [unknown]
/// (could be firewalled or reachable only via a bastion); a banner starting
/// with `SSH-` confirms [online].
class TcpBannerProber implements Prober {
  const TcpBannerProber();

  @override
  Future<ProbeStatus> probe(String host, int port,
      {Duration timeout = const Duration(seconds: 5)}) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      // Read the banner if one arrives promptly — purely to confirm the port
      // is a live service and not a half-open middlebox. Either way, a
      // completed connection means the host is up.
      await socket
          .cast<List<int>>()
          .transform(const _FirstChunk())
          .first
          .timeout(timeout, onTimeout: () => const <int>[]);
      return ProbeStatus.online;
    } on SocketException {
      // Connection refused / host unreachable / DNS failure.
      return ProbeStatus.offline;
    } on TimeoutException {
      // Filtered port or reachable only via a bastion — not a definite "down".
      return ProbeStatus.unknown;
    } catch (_) {
      return ProbeStatus.unknown;
    } finally {
      socket?.destroy();
    }
  }
}

/// Periodically probes a set of servers and reports status changes. Probing is
/// jittered and pauses when the app is not visible, to keep sshd logs quiet and
/// avoid tripping fail2ban-style tooling. Servers with an active session are
/// reported [online] for free via keepalives and are excluded from probing —
/// see [connectedServerIds].
class ProbeService {
  final Prober prober;
  final Duration interval;
  final Duration timeout;

  /// How many probes may be in flight at once. A sweep over an imported
  /// `~/.ssh/config` can cover dozens of hosts; opening a socket to all of
  /// them at once bursts the network — badly so on a mobile radio, and in
  /// competition with the live session the user is actually typing into.
  final int maxConcurrentProbes;

  /// Ids of servers that already hold a live SSH session, supplied by the app.
  ///
  /// Those hosts are demonstrably reachable and dartssh2 is already keeping
  /// the transport warm, so probing them adds nothing but a TCP connect and an
  /// `sshd` log line every sweep — for a machine you are looking at.
  Set<String> Function()? connectedServerIds;

  final Random _random;
  static const _minimumJitterFactor = 0.7;
  static const _jitterRange = 0.6;

  Timer? _timer;
  bool _paused = false;
  bool _started = false;
  bool _sweepInFlight = false;
  bool _immediateSweepPending = false;
  int _generation = 0;
  List<ServerConfig> _servers = const [];
  final _controller = StreamController<Map<String, ProbeStatus>>.broadcast();

  ProbeService({
    this.prober = const TcpBannerProber(),
    this.interval = const Duration(seconds: 45),
    this.timeout = const Duration(seconds: 5),
    this.maxConcurrentProbes = 6,
    this.connectedServerIds,
    Random? random,
  })  : assert(maxConcurrentProbes > 0),
        _random = random ?? Random();

  /// Latest status per server id, pushed on every sweep.
  Stream<Map<String, ProbeStatus>> get statuses => _controller.stream;

  /// Probe every server once, at most [maxConcurrentProbes] at a time.
  ///
  /// Servers in [alreadyConnected] are reported [ProbeStatus.online] without a
  /// probe. Servers whose reachability is unknown still get a status; the map
  /// is keyed by server id.
  Future<Map<String, ProbeStatus>> probeAll(
    List<ServerConfig> servers, {
    Set<String> alreadyConnected = const {},
  }) => _probeAll(servers, alreadyConnected: alreadyConnected);

  // Only periodic sweeps carry a generation; standalone calls always finish.
  Future<Map<String, ProbeStatus>> _probeAll(
    List<ServerConfig> servers, {
    required Set<String> alreadyConnected,
    int? generation,
  }) async {
    bool isCurrent() => generation == null || _isCurrentSweep(generation);

    final results = <String, ProbeStatus>{};
    final pending = <ServerConfig>[];
    for (final server in servers) {
      if (alreadyConnected.contains(server.id)) {
        results[server.id] = ProbeStatus.online;
      } else {
        pending.add(server);
      }
    }

    var next = 0;
    Future<void> worker() async {
      while (isCurrent()) {
        final index = next++;
        if (index >= pending.length) return;
        final server = pending[index];
        try {
          final status = await prober.probe(
            server.host,
            server.port,
            timeout: timeout,
          );
          if (!isCurrent()) return;
          results[server.id] = status;
        } catch (_) {
          if (!isCurrent()) return;
          // One misbehaving host must not take the rest of the sweep with it.
          // [unknown], not [offline]: an unexpected error is not evidence that
          // the host is down, and claiming otherwise would be the lie this
          // enum's third state exists to avoid.
          results[server.id] = ProbeStatus.unknown;
        }
      }
    }

    // max(1, …) as well as the assert: the assert is compiled out of release
    // builds, where a zero would otherwise start no workers at all and skip
    // every pending host in silence.
    final workers = min(max(1, maxConcurrentProbes), pending.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return results;
  }

  void start(List<ServerConfig> servers) {
    if (_controller.isClosed) return;
    updateServers(servers);
    _started = true;
    _immediateSweepPending = true;
    _scheduleNext();
  }

  /// Replace targets without accelerating the periodic schedule.
  void updateServers(List<ServerConfig> servers) {
    if (_controller.isClosed) return;
    _servers = List.unmodifiable(servers);
    _generation++;
  }

  /// Whether probing is currently paused (e.g. the app is backgrounded).
  bool get isPaused => _paused;

  void pause() {
    _paused = true;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _immediateSweepPending = false;
  }

  void resume() {
    if (!_paused || _controller.isClosed) return;
    _paused = false;
    _immediateSweepPending = true;
    _scheduleNext();
  }

  bool _isCurrentSweep(int generation) =>
      generation == _generation && !_paused && !_controller.isClosed;

  void _scheduleNext() {
    if (!_started || _paused || _controller.isClosed || _sweepInFlight) return;
    _timer?.cancel();
    // Jitter ±30% so many servers aren't probed in lockstep.
    final jitterMs =
        (interval.inMilliseconds *
                (_minimumJitterFactor + _random.nextDouble() * _jitterRange))
            .round();
    final delay = _immediateSweepPending
        ? Duration.zero
        : Duration(milliseconds: jitterMs);
    _timer = Timer(delay, _runSweep);
  }

  Future<void> _runSweep() async {
    _timer = null;
    if (_paused || _controller.isClosed) return;
    _sweepInFlight = true;
    _immediateSweepPending = false;
    final generation = _generation;
    final servers = _servers;

    try {
      if (servers.isNotEmpty) {
        final statuses = await _probeAll(
          servers,
          alreadyConnected: connectedServerIds?.call() ?? const <String>{},
          generation: generation,
        );
        if (_isCurrentSweep(generation)) _controller.add(statuses);
      }
    } catch (error, stack) {
      // A caller-supplied connectedServerIds callback can fail. Report it and
      // keep the next sweep scheduled so statuses can recover.
      developer.log(
        'probe sweep failed',
        name: 'seance.probe',
        error: error,
        stackTrace: stack,
      );
    } finally {
      // Restarts wait for every existing probe to drain. Only this owner
      // rearms the timer, preserving the concurrency cap across generations.
      _sweepInFlight = false;
      _scheduleNext();
    }
  }

  Future<void> dispose() async {
    _generation++;
    _timer?.cancel();
    _timer = null;
    await _controller.close();
  }
}

/// Emits only the first non-empty chunk of a byte stream, then stops.
class _FirstChunk extends StreamTransformerBase<List<int>, List<int>> {
  const _FirstChunk();
  @override
  Stream<List<int>> bind(Stream<List<int>> stream) async* {
    await for (final chunk in stream) {
      if (chunk.isNotEmpty) {
        yield chunk;
        return;
      }
    }
  }
}
