import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_core/src/ssh/ssh_agent.dart';
import 'package:test/test.dart';

const _frameLengthBytes = 4;
const _agentFailure = 5;
const _requestIdentities = 11;
const _identitiesAnswer = 12;
const _signRequest = 13;
const _signResponse = 14;
const _rsaSha256Flag = 2;

const _ed25519 = 'ssh-ed25519';
const _rsa = 'ssh-rsa';
const _rsaSha256 = 'rsa-sha2-256';
const _maxAgentIdentities = 2048;

void main() {
  test(
    'loads an Ed25519 identity and delegates signing to the agent',
    () async {
      final keyBlob = _publicKeyBlob(
        _ed25519,
        List<int>.generate(32, (index) => index),
      );
      final signatureBlob = _signatureBlob(_ed25519, List<int>.filled(64, 7));
      final challenge = Uint8List.fromList([3, 1, 4, 1, 5]);
      var exchanges = 0;

      final client = SshAgentClient.withExchange((request) async {
        final payload = _unframe(request);
        exchanges++;

        if (exchanges == 1) {
          expect(payload, [_requestIdentities]);
          return _identitiesResponse(keyBlob, 'work key');
        }

        final reader = _Reader(payload);
        expect(reader.readByte(), _signRequest);
        expect(reader.readString(), keyBlob);
        expect(reader.readString(), challenge);
        expect(reader.readUint32(), 0);
        expect(reader.isDone, isTrue);
        return _signingResponse(signatureBlob);
      });

      final identities = await client.identities();

      expect(identities, hasLength(1));
      final identity = identities.single;
      expect(identity.type, _ed25519);
      expect(identity.comment, 'work key');
      expect(identity.shouldProbe, isTrue);
      expect(identity.toPublicKey().encode(), keyBlob);

      final signature = await identity.sign(challenge);
      expect(signature.encode(), signatureBlob);
      expect(exchanges, 2);
    },
  );

  test(
    'requests RSA SHA-256 signatures with the agent protocol flag',
    () async {
      final keyBlob = _rsaPublicKeyBlob();
      final signatureBlob = _signatureBlob(_rsaSha256, List<int>.filled(32, 9));
      final challenge = Uint8List.fromList([2, 7, 1, 8]);
      var exchanges = 0;

      final client = SshAgentClient.withExchange((request) async {
        final payload = _unframe(request);
        exchanges++;

        if (exchanges == 1) {
          expect(payload, [_requestIdentities]);
          return _identitiesResponse(keyBlob, 'legacy RSA key');
        }

        final reader = _Reader(payload);
        expect(reader.readByte(), _signRequest);
        expect(reader.readString(), keyBlob);
        expect(reader.readString(), challenge);
        expect(reader.readUint32(), _rsaSha256Flag);
        expect(reader.isDone, isTrue);
        return _signingResponse(signatureBlob);
      });

      final identity = (await client.identities()).single;
      expect(identity.type, _rsaSha256);
      expect(identity.shouldProbe, isTrue);
      expect(identity.toPublicKey().encode(), keyBlob);

      final signature = await identity.sign(challenge);
      expect(signature.encode(), signatureBlob);
      expect(exchanges, 2);
    },
  );

  test('rejects a downgraded RSA signature from the agent', () async {
    final keyBlob = _rsaPublicKeyBlob();
    var exchanges = 0;
    final client = SshAgentClient.withExchange((request) async {
      exchanges++;
      if (exchanges == 1) {
        return _identitiesResponse(keyBlob, 'legacy RSA key');
      }

      return _signingResponse(_signatureBlob(_rsa, List<int>.filled(32, 9)));
    });
    final identity = (await client.identities()).single;

    await expectLater(
      identity.sign(Uint8List.fromList([1, 2, 3])),
      throwsA(
        isA<SshAgentException>().having(
          (error) => error.message,
          'message',
          allOf(contains(_rsa), contains(_rsaSha256)),
        ),
      ),
    );
  });

  test('rejects malformed signing responses', () async {
    final keyBlob = _publicKeyBlob(
      _ed25519,
      List<int>.generate(32, (index) => index),
    );
    var exchanges = 0;
    final client = SshAgentClient.withExchange((request) async {
      exchanges++;
      if (exchanges == 1) return _identitiesResponse(keyBlob, 'work key');

      return _frame([
        _signResponse,
        ..._string([1, 2, 3]),
        99,
      ]);
    });
    final identity = (await client.identities()).single;

    await expectLater(
      identity.sign(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<SshAgentException>()),
    );
  });

  group('rejects unusable agent replies', () {
    final keyBlob = _publicKeyBlob(
      _ed25519,
      List<int>.generate(32, (index) => index),
    );
    final cases = <String, Uint8List>{
      'an empty response': Uint8List(0),
      'an empty identity list': _frame([_identitiesAnswer, ..._uint32(0)]),
      'an explicit failure': _frame([_agentFailure]),
      'a truncated identity answer': _frame([_identitiesAnswer, 0, 0]),
      'too many identities': _frame([
        _identitiesAnswer,
        ..._uint32(_maxAgentIdentities + 1),
      ]),
      'an oversized frame': Uint8List.fromList(_uint32(0x7fffffff)),
      'trailing identity data': _frame([
        _identitiesAnswer,
        ..._uint32(1),
        ..._string(keyBlob),
        ..._string(utf8.encode('work key')),
        99,
      ]),
      'bytes after the frame': Uint8List.fromList([
        ..._frame([_identitiesAnswer, ..._uint32(0)]),
        99,
      ]),
    };

    for (final entry in cases.entries) {
      test(entry.key, () async {
        final client = SshAgentClient.withExchange((request) async {
          expect(_unframe(request), [_requestIdentities]);
          return entry.value;
        });

        await expectLater(
          client.identities(),
          throwsA(isA<SshAgentException>()),
        );
      });
    }
  });
}

Uint8List _identitiesResponse(Uint8List keyBlob, String comment) => _frame([
  _identitiesAnswer,
  ..._uint32(1),
  ..._string(keyBlob),
  ..._string(utf8.encode(comment)),
]);

Uint8List _signingResponse(Uint8List signatureBlob) =>
    _frame([_signResponse, ..._string(signatureBlob)]);

Uint8List _publicKeyBlob(String type, List<int> key) =>
    Uint8List.fromList([..._string(utf8.encode(type)), ..._string(key)]);

Uint8List _rsaPublicKeyBlob() => Uint8List.fromList([
  ..._string(utf8.encode(_rsa)),
  ..._string([1, 0, 1]),
  ..._string([0, 0x80, 1, 2, 3, 4, 5, 6]),
]);

Uint8List _signatureBlob(String type, List<int> signature) =>
    Uint8List.fromList([..._string(utf8.encode(type)), ..._string(signature)]);

Uint8List _frame(List<int> payload) =>
    Uint8List.fromList([..._uint32(payload.length), ...payload]);

Uint8List _unframe(Uint8List frame) {
  expect(frame.length, greaterThanOrEqualTo(_frameLengthBytes + 1));
  final length = ByteData.sublistView(frame).getUint32(0);
  expect(frame.length, _frameLengthBytes + length);

  return Uint8List.sublistView(frame, _frameLengthBytes);
}

List<int> _string(List<int> value) => [..._uint32(value.length), ...value];

List<int> _uint32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value);
  return bytes;
}

class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  bool get isDone => _offset == _bytes.length;

  int readByte() => _bytes[_offset++];

  int readUint32() {
    final value = ByteData.sublistView(_bytes).getUint32(_offset);
    _offset += 4;
    return value;
  }

  Uint8List readString() {
    final length = readUint32();
    final value = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return value;
  }
}
