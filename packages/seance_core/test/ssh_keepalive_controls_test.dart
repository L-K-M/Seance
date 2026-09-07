import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// A completion-only wire fixture tests configuration, not SSH authentication.
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_userauth.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

const _defaultInterval = Duration(seconds: 10);
const _customInterval = Duration(seconds: 30);
const _packetLengthBytes = 4;
const _paddingLengthBytes = 1;
const _minimumPaddingBytes = 4;
const _packetBlockBytes = 8;

final _config = ServerConfig(
  id: 'test',
  label: 'test',
  host: 'unused.invalid',
  username: 'user',
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  test('omitting keepalive preserves the existing ten-second timer', () async {
    await _checkTimer(
      (socket) => openAuthenticatedClient(
        config: _config,
        credentials: const SshCredentials.password('test'),
        tofu: TofuVerifier(InMemoryHostKeyStore()),
        onHostKey: (_) async => false,
        connect: (_, _, _) async => socket,
      ),
      _defaultInterval,
    );
  });

  for (final interval in [_customInterval, null]) {
    test('forwards keepalive interval $interval to the client timer', () async {
      await _checkTimer(
        (socket) => openAuthenticatedClient(
          config: _config,
          credentials: const SshCredentials.password('test'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => false,
          connect: (_, _, _) async => socket,
          keepAliveInterval: interval,
        ),
        interval,
      );
    });
  }

  for (final interval in [Duration.zero, -_defaultInterval]) {
    test('rejects $interval before connecting', () async {
      var connections = 0;
      await expectLater(
        openAuthenticatedClient(
          config: _config,
          credentials: const SshCredentials.password('test'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => false,
          connect: (_, _, _) async {
            connections++;
            throw StateError('must not connect');
          },
          keepAliveInterval: interval,
        ),
        throwsArgumentError,
      );
      expect(connections, 0);
    });
  }
}

Future<void> _checkTimer(
  Future<(SSHClient, AuthKind)> Function(SSHSocket) open,
  Duration? expectedInterval,
) async {
  final socket = _CompletionSocket();
  final intervals = <Duration>[];
  final timers = <Timer>[];
  SSHClient? client;
  try {
    await runZoned(
      () async {
        final (opened, _) = await open(socket);
        client = opened;
        expect(opened.keepAliveInterval, expectedInterval);
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          intervals.add(duration);
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          timers.add(timer);
          return timer;
        },
      ),
    );
    expect(intervals, expectedInterval == null ? isEmpty : [expectedInterval]);
  } finally {
    await client?.close();
    await socket.close();
    expect(timers.every((timer) => !timer.isActive), isTrue);
  }
}

/// Injects only USERAUTH_SUCCESS to reach the real client's timer setup.
/// Deliberately skips key exchange: trust/auth correctness is not under test.
class _CompletionSocket implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();

  _CompletionSocket() {
    unawaited(_outgoing.stream.drain<void>());
    _incoming.add(Uint8List.fromList(ascii.encode('SSH-2.0-TimerFixture\r\n')));

    final payload = SSH_Message_Userauth_Success().encode();
    final headerBytes = _packetLengthBytes + _paddingLengthBytes;
    var padding =
        _packetBlockBytes - (headerBytes + payload.length) % _packetBlockBytes;
    if (padding < _minimumPaddingBytes) padding += _packetBlockBytes;
    final packet = Uint8List(headerBytes + payload.length + padding);
    ByteData.sublistView(
      packet,
    ).setUint32(0, packet.length - _packetLengthBytes);
    packet[_packetLengthBytes] = padding;
    packet.setRange(headerBytes, headerBytes + payload.length, payload);
    _incoming.add(packet);
  }

  @override
  Stream<Uint8List> get stream => _incoming.stream;
  @override
  StreamSink<List<int>> get sink => _outgoing.sink;
  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() {
    if (_done.isCompleted) return done;
    _done.complete();
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
    return done;
  }

  @override
  void destroy() => unawaited(close());
  @override
  Future<void> flush() async {}
}
