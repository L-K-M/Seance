import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/src/ssh/ssh_agent.dart';
import 'package:test/test.dart';

const _authSocketVariable = 'SSH_AUTH_SOCK';
const _requestIdentities = 11;
const _identitiesAnswer = 12;
const _frameHeaderBytes = 4;
const _keyType = 'ssh-ed25519';
const _comment = 'fixture@example';

void main() {
  final supportsUnixSockets = Platform.isLinux || Platform.isMacOS;

  group('Unix ssh-agent transport', () {
    test('reads a fragmented framed identity response', () async {
      final directory = await Directory.systemTemp.createTemp('seance-agent-');
      final socketPath = '${directory.path}/agent.sock';
      final address = InternetAddress(
        socketPath,
        type: InternetAddressType.unix,
      );
      final server = await ServerSocket.bind(address, 0);
      final keyBlob = _publicKeyBlob();
      final response = _frame(_identitiesResponse(keyBlob));
      final served = server.first.then((socket) async {
        final request = await _readFrame(socket);
        expect(request, [_requestIdentities]);

        // Split both the frame header and payload to exercise stream framing.
        socket.add(response.sublist(0, 2));
        await socket.flush();
        socket.add(response.sublist(2, 7));
        await socket.flush();
        socket.add(response.sublist(7));
        await socket.flush();
        await socket.close();
      });

      try {
        final client = SshAgentClient(
          environment: {_authSocketVariable: socketPath},
        );
        final identities = await client.identities();

        expect(identities, hasLength(1));
        expect(identities.single.type, _keyType);
        expect(identities.single.comment, _comment);
        expect(identities.single.shouldProbe, isTrue);
        expect(identities.single.toPublicKey().encode(), keyBlob);
        await served;
      } finally {
        await server.close();
        await directory.delete(recursive: true);
      }
    });

    test('times out and closes an unresponsive agent socket', () async {
      final directory = await Directory.systemTemp.createTemp('seance-agent-');
      final socketPath = '${directory.path}/agent.sock';
      final server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      final accepted = server.first;

      try {
        final client = SshAgentClient(
          environment: {_authSocketVariable: socketPath},
          requestTimeout: const Duration(milliseconds: 50),
        );

        await expectLater(
          client.identities(),
          throwsA(
            isA<SshAgentException>().having(
              (error) => error.message.toLowerCase(),
              'message',
              contains('timed out'),
            ),
          ),
        );

        final socket = await accepted.timeout(const Duration(seconds: 5));
        await expectLater(socket.drain<void>(), completes);
        await socket.close();
      } finally {
        await server.close();
        await directory.delete(recursive: true);
      }
    });

    for (final environment in <Map<String, String>>[
      const {},
      const {_authSocketVariable: ''},
    ]) {
      test('reports a missing agent socket for $environment', () async {
        final client = SshAgentClient(environment: environment);

        await expectLater(
          client.identities(),
          throwsA(
            predicate<Object>((error) {
              final message = error.toString();
              return message.contains(_authSocketVariable) &&
                  message.toLowerCase().contains('ssh-agent');
            }, 'an actionable SSH_AUTH_SOCK error'),
          ),
        );
      });
    }
  }, skip: supportsUnixSockets ? false : 'requires Unix-domain sockets');
}

Uint8List _publicKeyBlob() {
  final bytes = BytesBuilder(copy: false)
    ..add(_string(utf8.encode(_keyType)))
    ..add(_string(List<int>.generate(32, (index) => index)));
  return bytes.takeBytes();
}

Uint8List _identitiesResponse(Uint8List keyBlob) {
  final bytes = BytesBuilder(copy: false)
    ..addByte(_identitiesAnswer)
    ..add(_uint32(1))
    ..add(_string(keyBlob))
    ..add(_string(utf8.encode(_comment)));
  return bytes.takeBytes();
}

Uint8List _frame(Uint8List payload) {
  final bytes = BytesBuilder(copy: false)
    ..add(_uint32(payload.length))
    ..add(payload);
  return bytes.takeBytes();
}

Uint8List _string(List<int> value) {
  final bytes = BytesBuilder(copy: false)
    ..add(_uint32(value.length))
    ..add(value);
  return bytes.takeBytes();
}

Uint8List _uint32(int value) {
  final bytes = Uint8List(_frameHeaderBytes);
  ByteData.sublistView(bytes).setUint32(0, value);
  return bytes;
}

Future<Uint8List> _readFrame(Socket socket) {
  final completer = Completer<Uint8List>();
  final bytes = <int>[];

  socket.listen(
    (chunk) {
      if (completer.isCompleted) return;
      bytes.addAll(chunk);
      if (bytes.length < _frameHeaderBytes) return;

      final header = Uint8List.fromList(bytes.take(_frameHeaderBytes).toList());
      final payloadLength = ByteData.sublistView(header).getUint32(0);
      final frameLength = _frameHeaderBytes + payloadLength;
      if (bytes.length < frameLength) return;

      completer.complete(Uint8List.fromList(bytes.sublist(_frameHeaderBytes)));
    },
    onError: completer.completeError,
    onDone: () {
      if (completer.isCompleted) return;
      completer.completeError(StateError('agent request ended mid-frame'));
    },
  );

  return completer.future;
}
