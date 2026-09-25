// A refused host key as the app meets it: through dartssh2's real key
// exchange, not a hand-built error. dartssh2 does not surface the error it
// raises when the verify callback says no; it closes the transport with it,
// and the client reports that as an authentication abort carrying it as the
// reason. A test that constructs the inner error directly passes whether or
// not that unwrapping happens, which is how the blocked state shipped without
// ever being reachable.
//
// The fixture plays the server's half of curve25519-sha256 with an ed25519
// host key, using dartssh2's own KEX helpers so the exchange hash and the
// signature are the ones a real client checks. The imports below are the
// dependency's internals, kept to this file for the same reason as in
// ssh_diagnostics_dartssh2_shape_test.dart: an internal move in a dartssh2
// release breaks exactly the tests that rely on it.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/kex/kex_x25519.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_kex_utils.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_message.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

const _host = 'fixture.invalid';
const _port = 2222;
const _serverVersion = 'SSH-2.0-HostKeyFixture';

/// A throwaway ed25519 key generated for this test only: the 32-byte seed
/// followed by the 32-byte public key, as ed25519 stores a secret key.
const _hostKeyHex =
    '62fd7247fdfd5524ee73f8a9adfd84c8bdc35e00027fa9ec897d5fcd70192c30'
    '59862a89d989588adabb872dab2a427e114bdea3034229bb4db225a3227044e3';

/// What `ssh-keygen -l` prints for [_hostKeyHex]'s public half.
const _hostKeyFingerprint =
    'SHA256:yXktaTZ+5AUfTOKd8EWiZBz73KUK8hSCWBHdG2aoefk';

const _kexInitId = 20;
const _newKeysId = 21;
const _kexEcdhInitId = 30;
const _kexEcdhReplyId = 31;

final _config = ServerConfig(
  id: 'fixture',
  label: 'fixture',
  host: _host,
  port: _port,
  username: 'me',
  authMethod: AuthMethod.password,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  group('a host key refused during the real key exchange', () {
    test('a changed key the user declines is a host-key refusal', () async {
      final store = InMemoryHostKeyStore();
      await store.put(
        const HostKey(
          host: _host,
          port: _port,
          type: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:the-key-this-host-had-before',
          pinnedAt: 0,
        ),
      );
      final verdicts = <HostKeyVerdict>[];

      final failure = await _connectExpectingFailure(
        store,
        onHostKey: (decision) async {
          verdicts.add(decision.verdict);
          return false;
        },
      );

      expect(
        verdicts,
        [HostKeyVerdict.changed],
        reason:
            'the fixture must reach the TOFU prompt, or this test '
            'proves nothing about declining a changed key',
      );
      expect(failure.isHostKeyRefusal, isTrue);
    });

    test('a first-use key the user declines is a host-key refusal', () async {
      final verdicts = <HostKeyVerdict>[];

      final failure = await _connectExpectingFailure(
        InMemoryHostKeyStore(),
        onHostKey: (decision) async {
          verdicts.add(decision.verdict);
          return false;
        },
      );

      expect(verdicts, [HostKeyVerdict.firstUse]);
      expect(failure.isHostKeyRefusal, isTrue);
    });

    test(
      'a drop after the key was accepted is not a host-key refusal',
      () async {
        final store = InMemoryHostKeyStore();

        final failure = await _connectExpectingFailure(
          store,
          onHostKey: (_) async => true,
        );

        // The pin is the fixture's own check: the key exchange it serves is
        // genuine, so the refusals above are about the key and nothing else.
        final pinned = await store.get(_host, _port);
        expect(pinned?.fingerprintSha256, _hostKeyFingerprint);
        expect(failure.isHostKeyRefusal, isFalse);
      },
    );
  });
}

Future<SshConnectException> _connectExpectingFailure(
  HostKeyStore store, {
  required HostKeyPrompter onHostKey,
}) async {
  final socket = _KexFixtureSocket();
  try {
    await openAuthenticatedClient(
      config: _config,
      credentials: const SshCredentials.password('unused'),
      tofu: TofuVerifier(store),
      onHostKey: onHostKey,
      connect: (_, _, _) async => socket,
      keepAliveInterval: null,
    );
  } on SshConnectException catch (e) {
    return e;
  } finally {
    await socket.close();
  }
  fail('the connection was expected to fail');
}

/// The server's half of one curve25519-sha256 key exchange, then a hang-up
/// once the client sends NEWKEYS (it has accepted the key by then).
class _KexFixtureSocket implements SSHSocket {
  _KexFixtureSocket() {
    _outgoing.stream.listen(_onClientBytes);
    _incoming.add(ascii.encode('$_serverVersion\r\n'));
    _incoming.add(_packet(_serverKexInit));
  }

  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();
  final _received = BytesBuilder();

  final _hostKey = OpenSSHEd25519KeyPair(
    _hex(_hostKeyHex).sublist(32),
    _hex(_hostKeyHex),
    '',
  );

  late final Uint8List _serverKexInit = _kexInit();
  String? _clientVersion;
  Uint8List? _clientKexInit;

  void _onClientBytes(List<int> bytes) {
    _received.add(bytes);
    var buffer = _received.takeBytes();

    if (_clientVersion == null) {
      final end = latin1.decode(buffer).indexOf('\r\n');
      if (end < 0) {
        _received.add(buffer);
        return;
      }
      _clientVersion = latin1.decode(buffer.sublist(0, end));
      buffer = buffer.sublist(end + 2);
    }

    // Everything the client sends before NEWKEYS is a clear-text packet:
    // length, padding length, payload, padding, and no MAC.
    while (buffer.length >= 4) {
      final length = ByteData.sublistView(buffer).getUint32(0);
      if (buffer.length < 4 + length) break;
      final padding = buffer[4];
      _onClientPayload(Uint8List.sublistView(buffer, 5, 4 + length - padding));
      buffer = buffer.sublist(4 + length);
    }
    _received.add(buffer);
  }

  void _onClientPayload(Uint8List payload) {
    switch (payload[0]) {
      case _kexInitId:
        _clientKexInit = Uint8List.fromList(payload);
      case _kexEcdhInitId:
        _incoming.add(_packet(_kexReply(SSHMessageReader(payload)..skip(1))));
      case _newKeysId:
        unawaited(close());
    }
  }

  Uint8List _kexReply(SSHMessageReader init) {
    final clientPublicKey = init.readString();
    final kex = SSHKexX25519();
    final hostKeyBlob = _hostKey.toPublicKey().encode();
    final exchangeHash = SSHKexUtils.computeExchangeHash(
      digest: SSHKexType.x25519Rfc.createDigest(),
      clientVersion: _clientVersion!,
      serverVersion: _serverVersion,
      clientKexInit: _clientKexInit!,
      serverKexInit: _serverKexInit,
      hostKey: hostKeyBlob,
      clientPublicKey: clientPublicKey,
      serverPublicKey: kex.publicKey,
      sharedSecret: kex.computeSecret(clientPublicKey),
    );
    final signature = _hostKey.sign(exchangeHash).encode();

    // Written by hand: dartssh2's own reply message encodes its first two
    // fields in the wrong order, which only matters to a server.
    final writer = SSHMessageWriter()
      ..writeUint8(_kexEcdhReplyId)
      ..writeString(hostKeyBlob)
      ..writeString(kex.publicKey)
      ..writeString(signature);
    return writer.takeBytes();
  }

  static Uint8List _kexInit() {
    final writer = SSHMessageWriter()
      ..writeUint8(_kexInitId)
      ..writeBytes(Uint8List(16)) // cookie
      ..writeNameList([SSHKexType.x25519Rfc.name])
      ..writeNameList([SSHHostkeyType.ed25519.name])
      ..writeNameList([SSHCipherType.aes128ctr.name])
      ..writeNameList([SSHCipherType.aes128ctr.name])
      ..writeNameList([SSHMacType.hmacSha256.name])
      ..writeNameList([SSHMacType.hmacSha256.name])
      ..writeNameList(['none'])
      ..writeNameList(['none'])
      ..writeNameList([])
      ..writeNameList([])
      ..writeBool(false) // first_kex_packet_follows
      ..writeUint32(0); // reserved
    return writer.takeBytes();
  }

  static Uint8List _packet(Uint8List payload) {
    const header = 5;
    const align = 8;
    const minimumPadding = 4;
    var padding = align - (header + payload.length) % align;
    if (padding < minimumPadding) padding += align;
    final packet = Uint8List(header + payload.length + padding);
    ByteData.sublistView(packet).setUint32(0, packet.length - 4);
    packet[4] = padding;
    packet.setRange(header, header + payload.length, payload);
    return packet;
  }

  static Uint8List _hex(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);

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
