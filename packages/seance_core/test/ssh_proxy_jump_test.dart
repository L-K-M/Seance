import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// A completion-only wire fixture tests routing and ownership, not SSH auth.
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_userauth.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

const _packetLengthBytes = 4;
const _paddingLengthBytes = 1;
const _minimumPaddingBytes = 4;
const _packetBlockBytes = 8;

ServerConfig _server({
  required String id,
  required String host,
  required int port,
  String? jumpHostId,
}) => ServerConfig(
  id: id,
  label: id,
  host: host,
  port: port,
  username: 'user-$id',
  authMethod: AuthMethod.password,
  jumpHostId: jumpHostId,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  group('openAuthenticatedClient ProxyJump', () {
    test('a direct target uses only its physical connector', () async {
      final target = _server(id: 'target', host: 'target.invalid', port: 2201);
      final physical = _CompletionSocket();
      final connected = <String>[];
      final resolved = <String>[];
      final forwarded = <String>[];

      Future<ResolvedSshHost?> resolveJumpHost(String id) async {
        resolved.add(id);
        return null;
      }

      Future<SSHSocket> forward(
        SSHClient client,
        String host,
        int port,
        Duration timeout,
      ) async {
        forwarded.add('$host:$port');
        throw StateError('a direct connection must not forward');
      }

      final (client, _) = await openAuthenticatedClient(
        config: target,
        credentials: const SshCredentials.password('target-password'),
        tofu: TofuVerifier(InMemoryHostKeyStore()),
        onHostKey: (_) async => true,
        connect: (host, port, timeout) async {
          connected.add('$host:$port');
          return physical;
        },
        resolveJumpHost: resolveJumpHost,
        forward: forward,
        keepAliveInterval: null,
      );

      expect(connected, ['target.invalid:2201']);
      expect(resolved, isEmpty);
      expect(forwarded, isEmpty);

      await client.close();
      expect(physical.closeCalls, 1);
    });

    test('one hop connects to the jump and forwards the target', () async {
      final jump = _server(id: 'jump', host: 'jump.invalid', port: 2202);
      final target = _server(
        id: 'target',
        host: 'target.internal',
        port: 2203,
        jumpHostId: jump.id,
      );
      final physical = _CompletionSocket();
      final targetSocket = _CompletionSocket();
      final connected = <String>[];
      final resolved = <String>[];
      final forwarded = <String>[];

      Future<ResolvedSshHost?> resolveJumpHost(String id) async {
        resolved.add(id);
        if (id != jump.id) return null;
        return ResolvedSshHost(
          jump,
          const SshCredentials.password('jump-password'),
        );
      }

      Future<SSHSocket> forward(
        SSHClient client,
        String host,
        int port,
        Duration timeout,
      ) async {
        forwarded.add('$host:$port');
        return targetSocket;
      }

      final (client, _) = await openAuthenticatedClient(
        config: target,
        // The root credential is supplied by its caller, never re-resolved.
        credentials: const SshCredentials.password('target-password'),
        tofu: TofuVerifier(InMemoryHostKeyStore()),
        onHostKey: (_) async => true,
        connect: (host, port, timeout) async {
          connected.add('$host:$port');
          return physical;
        },
        resolveJumpHost: resolveJumpHost,
        forward: forward,
        keepAliveInterval: null,
      );

      expect(resolved, [jump.id]);
      expect(connected, ['jump.invalid:2202']);
      expect(forwarded, ['target.internal:2203']);

      await client.close();
      expect(targetSocket.closeCalls, 1);
      expect(physical.closeCalls, 1);
    });

    test(
      'multiple hops open inside-out and close the whole chain once',
      () async {
        final inner = _server(id: 'inner', host: 'inner.invalid', port: 2204);
        final outer = _server(
          id: 'outer',
          host: 'outer.internal',
          port: 2205,
          jumpHostId: inner.id,
        );
        final target = _server(
          id: 'target',
          host: 'target.internal',
          port: 2206,
          jumpHostId: outer.id,
        );
        final physical = _CompletionSocket();
        final outerSocket = _CompletionSocket();
        final targetSocket = _CompletionSocket();
        final connected = <String>[];
        final resolved = <String>[];
        final forwarded = <String>[];
        final forwardClients = <SSHClient>[];

        final hosts = <String, ResolvedSshHost>{
          inner.id: ResolvedSshHost(
            inner,
            const SshCredentials.password('inner-password'),
          ),
          outer.id: ResolvedSshHost(
            outer,
            const SshCredentials.password('outer-password'),
          ),
        };
        Future<ResolvedSshHost?> resolveJumpHost(String id) async {
          resolved.add(id);
          return hosts[id];
        }

        final forwardedSockets = <_CompletionSocket>[
          outerSocket,
          targetSocket,
        ].iterator;
        Future<SSHSocket> forward(
          SSHClient client,
          String host,
          int port,
          Duration timeout,
        ) async {
          forwardClients.add(client);
          forwarded.add('$host:$port');
          expect(forwardedSockets.moveNext(), isTrue);
          return forwardedSockets.current;
        }

        final (client, _) = await openAuthenticatedClient(
          config: target,
          credentials: const SshCredentials.password('target-password'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => true,
          connect: (host, port, timeout) async {
            connected.add('$host:$port');
            return physical;
          },
          resolveJumpHost: resolveJumpHost,
          forward: forward,
          keepAliveInterval: null,
        );

        expect(resolved, [outer.id, inner.id]);
        expect(connected, ['inner.invalid:2204']);
        expect(forwarded, ['outer.internal:2205', 'target.internal:2206']);
        expect(forwardClients, hasLength(2));
        expect(identical(forwardClients.first, forwardClients.last), isFalse);
        expect(
          forwardClients.any(
            (forwardClient) => identical(forwardClient, client),
          ),
          isFalse,
        );
        expect(forwardedSockets.moveNext(), isFalse);

        await client.close();
        expect(targetSocket.closeCalls, 1);
        expect(outerSocket.closeCalls, 1);
        expect(physical.closeCalls, 1);
      },
    );

    test('a missing jump host fails before network activity', () async {
      final target = _server(
        id: 'target',
        host: 'target.internal',
        port: 2207,
        jumpHostId: 'missing',
      );
      var connections = 0;
      var forwards = 0;

      await expectLater(
        openAuthenticatedClient(
          config: target,
          credentials: const SshCredentials.password('target-password'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => true,
          connect: (host, port, timeout) async {
            connections++;
            return _CompletionSocket();
          },
          resolveJumpHost: (id) async => null,
          forward: (client, host, port, timeout) async {
            forwards++;
            return _CompletionSocket();
          },
          keepAliveInterval: null,
        ),
        throwsA(
          isA<SshConnectException>().having(
            (error) => error.message,
            'message',
            contains('missing'),
          ),
        ),
      );

      expect(connections, 0);
      expect(forwards, 0);
    });

    test(
      'a self-referencing jump host fails before network activity',
      () async {
        final target = _server(
          id: 'target',
          host: 'target.internal',
          port: 2208,
          jumpHostId: 'target',
        );
        var connections = 0;
        var forwards = 0;

        await expectLater(
          openAuthenticatedClient(
            config: target,
            credentials: const SshCredentials.password('target-password'),
            tofu: TofuVerifier(InMemoryHostKeyStore()),
            onHostKey: (_) async => true,
            connect: (host, port, timeout) async {
              connections++;
              return _CompletionSocket();
            },
            resolveJumpHost: (id) async => ResolvedSshHost(
              target,
              const SshCredentials.password('target-password'),
            ),
            forward: (client, host, port, timeout) async {
              forwards++;
              return _CompletionSocket();
            },
            keepAliveInterval: null,
          ),
          throwsA(_cycleFailure),
        );

        expect(connections, 0);
        expect(forwards, 0);
      },
    );

    test('an indirect jump cycle fails before network activity', () async {
      final first = _server(
        id: 'first',
        host: 'first.internal',
        port: 2209,
        jumpHostId: 'second',
      );
      final second = _server(
        id: 'second',
        host: 'second.internal',
        port: 2210,
        jumpHostId: first.id,
      );
      var connections = 0;
      var forwards = 0;

      await expectLater(
        openAuthenticatedClient(
          config: first,
          credentials: const SshCredentials.password('first-password'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => true,
          connect: (host, port, timeout) async {
            connections++;
            return _CompletionSocket();
          },
          resolveJumpHost: (id) async {
            if (id == second.id) {
              return ResolvedSshHost(
                second,
                const SshCredentials.password('second-password'),
              );
            }
            if (id == first.id) {
              return ResolvedSshHost(
                first,
                const SshCredentials.password('first-password'),
              );
            }
            return null;
          },
          forward: (client, host, port, timeout) async {
            forwards++;
            return _CompletionSocket();
          },
          keepAliveInterval: null,
        ),
        throwsA(_cycleFailure),
      );

      expect(connections, 0);
      expect(forwards, 0);
    });

    test('a forward failure closes the authenticated parent', () async {
      final jump = _server(id: 'jump', host: 'jump.invalid', port: 2211);
      final target = _server(
        id: 'target',
        host: 'target.internal',
        port: 2212,
        jumpHostId: jump.id,
      );
      final physical = _CompletionSocket();

      await expectLater(
        openAuthenticatedClient(
          config: target,
          credentials: const SshCredentials.password('target-password'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => true,
          connect: (host, port, timeout) async => physical,
          resolveJumpHost: (id) async => ResolvedSshHost(
            jump,
            const SshCredentials.password('jump-password'),
          ),
          forward: (client, host, port, timeout) async =>
              throw StateError('forward refused'),
          keepAliveInterval: null,
        ),
        throwsA(isA<SshConnectException>()),
      );

      expect(physical.closeCalls, 1);
    });

    test('an SSH constructor failure closes the forwarded chain', () async {
      final jump = _server(id: 'jump', host: 'jump.invalid', port: 2213);
      final target = _server(
        id: 'target',
        host: 'target.internal',
        port: 2214,
        jumpHostId: jump.id,
      );
      final physical = _CompletionSocket();
      final forwarded = _BrokenSinkSocket();

      await expectLater(
        openAuthenticatedClient(
          config: target,
          credentials: const SshCredentials.password('target-password'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => true,
          connect: (host, port, timeout) async => physical,
          resolveJumpHost: (id) async => ResolvedSshHost(
            jump,
            const SshCredentials.password('jump-password'),
          ),
          forward: (client, host, port, timeout) async => forwarded,
          keepAliveInterval: null,
        ),
        throwsA(isA<SshConnectException>()),
      );

      expect(forwarded.closeCalls, 1);
      expect(physical.closeCalls, 1);
    });

    test('a later-hop auth failure closes the whole chain', () async {
      final jump = _server(id: 'jump', host: 'jump.invalid', port: 2215);
      final target = _server(
        id: 'target',
        host: 'target.internal',
        port: 2216,
        jumpHostId: jump.id,
      );
      final physical = _CompletionSocket();
      final rejected = _CompletionSocket(_AuthenticationResult.failure);

      await expectLater(
        openAuthenticatedClient(
          config: target,
          credentials: const SshCredentials.password('target-password'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => true,
          connect: (host, port, timeout) async => physical,
          resolveJumpHost: (id) async => ResolvedSshHost(
            jump,
            const SshCredentials.password('jump-password'),
          ),
          forward: (client, host, port, timeout) async => rejected,
          keepAliveInterval: null,
        ),
        throwsA(isA<SshConnectException>()),
      );

      expect(rejected.closeCalls, 1);
      expect(physical.closeCalls, 1);
    });

    test(
      'closing destroys a stalled forwarding channel before its parent',
      () async {
        final jump = _server(id: 'jump', host: 'jump.invalid', port: 2217);
        final target = _server(
          id: 'target',
          host: 'target.internal',
          port: 2218,
          jumpHostId: jump.id,
        );
        final physical = _CompletionSocket();
        final forwarded = _StallingCloseSocket();
        final (client, _) = await openAuthenticatedClient(
          config: target,
          credentials: const SshCredentials.password('target-password'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => true,
          connect: (host, port, timeout) async => physical,
          resolveJumpHost: (id) async => ResolvedSshHost(
            jump,
            const SshCredentials.password('jump-password'),
          ),
          forward: (client, host, port, timeout) async => forwarded,
          keepAliveInterval: null,
        );

        final closing = client.close();
        var closedPromptly = true;
        try {
          await closing.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          closedPromptly = false;
        } finally {
          forwarded.releaseClose();
          await closing;
        }

        expect(
          closedPromptly,
          isTrue,
          reason: 'client.close() must destroy a stalled forwarding channel',
        );
        expect(forwarded.destroyCalls, 1);
        expect(physical.closeCalls, 1);
      },
    );
  });
}

final Matcher _cycleFailure = isA<SshConnectException>().having(
  (error) => error.message.toLowerCase(),
  'message',
  contains('cycle'),
);

enum _AuthenticationResult { success, failure }

/// Completes authentication without key exchange; routing is the only subject.
class _CompletionSocket implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();

  int closeCalls = 0;

  _CompletionSocket([
    _AuthenticationResult authentication = _AuthenticationResult.success,
  ]) {
    unawaited(_outgoing.stream.drain<void>());
    _incoming.add(
      Uint8List.fromList(ascii.encode('SSH-2.0-ProxyJumpFixture\r\n')),
    );

    final payload = switch (authentication) {
      _AuthenticationResult.success => SSH_Message_Userauth_Success().encode(),
      _AuthenticationResult.failure => SSH_Message_Userauth_Failure(
        methodsLeft: const [],
      ).encode(),
    };
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
    closeCalls++;
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

final class _BrokenSinkSocket implements SSHSocket {
  final _done = Completer<void>();
  int closeCalls = 0;

  @override
  Stream<Uint8List> get stream => const Stream<Uint8List>.empty();

  @override
  StreamSink<List<int>> get sink => throw StateError('sink unavailable');

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() {
    closeCalls++;
    if (!_done.isCompleted) _done.complete();
    return done;
  }

  @override
  void destroy() => unawaited(close());

  @override
  Future<void> flush() async {}
}

final class _StallingCloseSocket extends _CompletionSocket {
  final _gracefulClose = Completer<void>();
  int destroyCalls = 0;

  @override
  Future<void> close() {
    closeCalls++;
    return _gracefulClose.future;
  }

  void releaseClose() {
    if (_gracefulClose.isCompleted) return;

    _gracefulClose.complete();
    unawaited(super.close());
  }

  @override
  void destroy() {
    destroyCalls++;
    releaseClose();
  }
}
