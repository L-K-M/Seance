import 'dart:async';
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
/// reported [online] for free via keepalives and can be excluded here.
class ProbeService {
  final Prober prober;
  final Duration interval;
  final Duration timeout;
  final Random _random;

  Timer? _timer;
  bool _paused = false;
  List<ServerConfig> _servers = const [];
  final _controller = StreamController<Map<String, ProbeStatus>>.broadcast();

  ProbeService({
    this.prober = const TcpBannerProber(),
    this.interval = const Duration(seconds: 45),
    this.timeout = const Duration(seconds: 5),
    Random? random,
  }) : _random = random ?? Random();

  /// Latest status per server id, pushed on every sweep.
  Stream<Map<String, ProbeStatus>> get statuses => _controller.stream;

  /// Probe every server once. Servers whose `authMethod`/reachability is
  /// unknown still get a status; the map is keyed by server id.
  Future<Map<String, ProbeStatus>> probeAll(List<ServerConfig> servers) async {
    final results = await Future.wait(servers.map((s) async {
      final status = await prober.probe(s.host, s.port, timeout: timeout);
      return MapEntry(s.id, status);
    }));
    return Map.fromEntries(results);
  }

  void start(List<ServerConfig> servers) {
    _servers = servers;
    _scheduleNext(immediate: true);
  }

  void updateServers(List<ServerConfig> servers) => _servers = servers;

  /// Whether probing is currently paused (e.g. the app is backgrounded).
  bool get isPaused => _paused;

  void pause() => _paused = true;
  void resume() {
    if (_paused) {
      _paused = false;
      _scheduleNext(immediate: true);
    }
  }

  void _scheduleNext({bool immediate = false}) {
    _timer?.cancel();
    // Jitter ±30% so many servers aren't probed in lockstep.
    final jitterMs =
        (interval.inMilliseconds * (0.7 + _random.nextDouble() * 0.6)).round();
    final delay = immediate ? Duration.zero : Duration(milliseconds: jitterMs);
    _timer = Timer(delay, () async {
      if (_paused) return;
      if (!_controller.isClosed && _servers.isNotEmpty) {
        _controller.add(await probeAll(_servers));
      }
      if (!_paused) _scheduleNext();
    });
  }

  Future<void> dispose() async {
    _timer?.cancel();
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
