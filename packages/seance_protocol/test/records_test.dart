import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('model JSON round-trips', () {
    test('ServerConfig', () {
      final c = ServerConfig(
        id: uuidV4(),
        label: 'prod web',
        host: 'web.example.com',
        port: 2222,
        username: 'deploy',
        authMethod: AuthMethod.privateKey,
        secretRef: 'secret-1',
        syncSecret: true,
        createdAt: 100,
        updatedAt: 200,
      );
      final back = ServerConfig.fromJson(c.toJson());
      expect(back.toJson(), equals(c.toJson()));
      expect(back.authMethod, AuthMethod.privateKey);
    });

    test('Secret does not leak its value in toString', () {
      final s = Secret(id: 's1', kind: SecretKind.password, value: 'hunter2');
      expect(s.toString(), isNot(contains('hunter2')));
      expect(Secret.fromJson(s.toJson()).value, 'hunter2');
    });

    test('HostKey fingerprint + known_hosts line', () {
      final k = HostKey.fromPublicKey(
        host: 'h.example.com',
        port: 22,
        type: 'ssh-ed25519',
        publicKeyBase64: 'AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyBytesHere0000',
        pinnedAt: 1,
      );
      expect(k.fingerprintSha256, startsWith('SHA256:'));
      expect(k.toKnownHostsLine(),
          'h.example.com ssh-ed25519 ${k.publicKeyBase64}');

      // A fingerprint-only key (the shape the SSH library gives us at connect
      // time) has a different fingerprint and no expandable known_hosts line.
      final k2 = HostKey(
          host: 'h.example.com',
          port: 22,
          type: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:completelyDifferentFingerprint',
          pinnedAt: 2);
      expect(k.conflictsWith(k2), isTrue);
      expect(k2.toKnownHostsLine(), isNull);
    });
  });

  group('RecordCodec', () {
    test('encrypts a server config and decrypts it back', () async {
      final vaultKey = secureRandomBytes(32);
      final codec = RecordCodec(vaultKey);
      final rec = DecryptedRecord(
        id: 'r1',
        kind: RecordKind.serverConfig,
        updatedAt: 42,
        deviceId: 'device-a',
        data: {'host': 'example.com', 'port': 22},
      );
      final enc = await codec.encrypt(rec);
      expect(enc.blob, isNotEmpty);
      expect(enc.seq, isNull);

      final dec = await codec.decrypt(enc);
      expect(dec.kind, RecordKind.serverConfig);
      expect(dec.data['host'], 'example.com');
      expect(dec.deleted, isFalse);
    });

    test('tombstone carries no payload', () async {
      final codec = RecordCodec(secureRandomBytes(32));
      final rec = DecryptedRecord(
        id: 'r1',
        kind: RecordKind.secret,
        updatedAt: 42,
        deviceId: 'device-a',
        deleted: true,
      );
      final enc = await codec.encrypt(rec);
      expect(enc.blob, isEmpty);
      expect(enc.deleted, isTrue);
      final dec = await codec.decrypt(enc);
      expect(dec.deleted, isTrue);
    });

    test('a server holding the blob cannot read it without the vault key',
        () async {
      final codec = RecordCodec(secureRandomBytes(32));
      final enc = await codec.encrypt(DecryptedRecord(
        id: 'r1',
        kind: RecordKind.secret,
        updatedAt: 1,
        deviceId: 'd',
        data: {'value': 'top-secret'},
      ));
      // The wire form is just base64 of the sealed blob — no plaintext leaks.
      expect(enc.toJson()['blob'], isNot(contains('top-secret')));
    });
  });

  group('Lww', () {
    EncryptedRecord rec(String id, int updatedAt, String device, {int? seq}) =>
        EncryptedRecord(
          id: id,
          updatedAt: updatedAt,
          deviceId: device,
          deleted: false,
          seq: seq,
          blob: secureRandomBytes(8),
        );

    test('higher updatedAt wins', () {
      final a = rec('x', 10, 'a');
      final b = rec('x', 20, 'b');
      expect(Lww.resolve(a, b).updatedAt, 20);
      expect(Lww.resolve(b, a).updatedAt, 20);
    });

    test('deviceId breaks an exact tie deterministically', () {
      final a = rec('x', 10, 'aaa');
      final b = rec('x', 10, 'bbb');
      expect(Lww.resolve(a, b).deviceId, 'bbb');
      expect(Lww.resolve(b, a).deviceId, 'bbb');
    });

    test('merge resolves per id across two sets', () {
      final local = [rec('1', 5, 'a'), rec('2', 5, 'a')];
      final remote = [rec('1', 9, 'b'), rec('3', 1, 'b')];
      final merged = Lww.merge(local, remote);
      expect(merged.keys.toSet(), {'1', '2', '3'});
      expect(merged['1']!.updatedAt, 9); // remote newer
      expect(merged['2']!.deviceId, 'a'); // only local
    });

    test('a later delete beats an earlier edit', () {
      final edit = rec('x', 10, 'a');
      final del = EncryptedRecord(
          id: 'x',
          updatedAt: 11,
          deviceId: 'b',
          deleted: true,
          seq: null,
          blob: secureRandomBytes(0));
      expect(Lww.resolve(edit, del).deleted, isTrue);
    });
  });

  group('DTO round-trips', () {
    test('RegisterRequest', () {
      final r = RegisterRequest(
        username: 'me',
        authVerifier: 'dmVyaWZpZXI=',
        argonSalt: 'c2FsdA==',
        argonParams: const Argon2Params(),
      );
      final back = RegisterRequest.fromJson(r.toJson());
      expect(back.username, 'me');
      expect(back.protocolVersion, kProtocolVersion);
      expect(back.argonParams.memory, 19456);
    });

    test('PushResponse', () {
      final r = PushResponse(
        results: const [
          PushResult(id: 'a', seq: 5, accepted: true),
          PushResult(id: 'b', seq: 6, accepted: false),
        ],
        latestSeq: 6,
      );
      final back = PushResponse.fromJson(r.toJson());
      expect(back.results.length, 2);
      expect(back.results[1].accepted, isFalse);
      expect(back.latestSeq, 6);
    });
  });
}
