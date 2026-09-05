import 'package:logging/logging.dart';
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

    test('ServerConfig presentation fields', () {
      final c = ServerConfig(
        id: 's1',
        label: 'prod web',
        host: 'web.example.com',
        username: 'deploy',
        group: 'Production',
        color: ServerColor.red,
        icon: ServerIcon.rocket,
        createdAt: 1,
        updatedAt: 2,
      );
      final back = ServerConfig.fromJson(c.toJson());
      expect(back.toJson(), equals(c.toJson()));
      expect(back.group, 'Production');
      expect(back.color, ServerColor.red);
      expect(back.icon, ServerIcon.rocket);
    });

    test('ServerConfig carries excludeFromSync explicitly', () {
      final c = ServerConfig(
        id: 's1',
        label: 'laptop',
        host: 'localhost',
        username: 'me',
        excludeFromSync: true,
        createdAt: 1,
        updatedAt: 2,
      );
      final back = ServerConfig.fromJson(c.toJson());
      expect(back.toJson(), equals(c.toJson()));
      expect(back.excludeFromSync, isTrue);
      // Both answers are written, so a record can say "sync me" rather than
      // only ever being silent about it.
      expect(c.toJson()['excludeFromSync'], isTrue);
      expect(
        ServerConfig.fromJson({...c.toJson(), 'excludeFromSync': false})
            .toJson()['excludeFromSync'],
        isFalse,
      );
      // A config written before the field existed reads as "syncs", which is
      // what it did.
      final legacy = {...c.toJson()}..remove('excludeFromSync');
      expect(ServerConfig.fromJson(legacy).excludeFromSync, isFalse);
      // Including one built here rather than read back: if the field were
      // stored tri-state and only normalized on the way in, a record this app
      // wrote would still be silent about it.
      expect(
        ServerConfig(
          id: 's2',
          label: 'laptop',
          host: 'localhost',
          username: 'me',
          createdAt: 1,
          updatedAt: 2,
        ).toJson()['excludeFromSync'],
        isFalse,
      );
    });

    test('copyWith flips excludeFromSync without touching anything else', () {
      final c = ServerConfig(
        id: 's1',
        label: 'laptop',
        host: 'localhost',
        username: 'me',
        syncSecret: true,
        createdAt: 1,
        updatedAt: 2,
      );
      final excluded = c.copyWith(excludeFromSync: true, updatedAt: 3);
      expect(excluded.excludeFromSync, isTrue);
      // The credential's own opt-in survives the exclusion, so clearing it
      // gives the user back the answer they picked rather than a silent no.
      expect(excluded.syncSecret, isTrue);
      expect(
        excluded
            .copyWith(excludeFromSync: false, updatedAt: 4)
            .excludeFromSync,
        isFalse,
      );
      // The pairing is enforced in every build, not merely documented: a
      // stale tombstone ties with the record already on the sync server and
      // loses to it, and an assert would be stripped from the build users run.
      expect(
        () => excluded.copyWith(excludeFromSync: false),
        throwsA(isA<ArgumentError>()),
      );
      // Re-stating the current timestamp ties, which loses the same way.
      expect(
        () => excluded.copyWith(excludeFromSync: false, updatedAt: 3),
        throwsA(isA<ArgumentError>()),
      );
      // A strictly older timestamp loses outright rather than merely tying.
      expect(
        () => excluded.copyWith(excludeFromSync: false, updatedAt: 2),
        throwsA(isA<ArgumentError>()),
      );
      // And the guard is symmetric: raising the flag without a fresh
      // timestamp ships a tombstone the server's copy already outranks.
      expect(
        () => c.copyWith(excludeFromSync: true),
        throwsA(isA<ArgumentError>()),
      );
      // Omitting it leaves it alone, like every other copyWith field.
      expect(excluded.copyWith(label: 'other').excludeFromSync, isTrue);
    });

    test('ServerConfig omits the presentation fields when they are unset', () {
      final json = ServerConfig(
        id: 's1',
        label: 'plain',
        host: 'h',
        username: 'u',
        createdAt: 1,
        updatedAt: 2,
      ).toJson();
      // A config written before these existed is byte-identical to one that
      // simply doesn't use them, so an upgrade rewrites nothing.
      expect(json.containsKey('group'), isFalse);
      expect(json.containsKey('color'), isFalse);
      expect(json.containsKey('icon'), isFalse);
      expect(json.containsKey('loginScript'), isFalse);
    });

    test('ServerConfig tolerates a group or an accent it does not know', () {
      final base = ServerConfig(
        id: 's1',
        label: 'l',
        host: 'h',
        username: 'u',
        createdAt: 1,
        updatedAt: 2,
      ).toJson();
      // A colour or icon added by a later version decodes as "none" rather
      // than as a wrong one, and a blank group is no group.
      final decoded = ServerConfig.fromJson({
        ...base,
        'group': '   ',
        'color': 'chartreuse',
        'icon': 'toaster',
      });
      expect(decoded.group, isNull);
      expect(decoded.color, isNull);
      expect(decoded.icon, isNull);
    });

    test('group names normalize their edges but not their middle', () {
      expect(normalizeServerGroup('  Home lab  '), 'Home lab');
      expect(normalizeServerGroup('   '), isNull);
      expect(normalizeServerGroup(null), isNull);
      expect(serverGroupKey('Home Lab'), serverGroupKey('home lab'));
    });

    test('copyWith can clear the presentation fields as well as set them', () {
      final tagged = ServerConfig(
        id: 's1',
        label: 'l',
        host: 'h',
        username: 'u',
        group: 'Production',
        color: ServerColor.red,
        icon: ServerIcon.rocket,
        createdAt: 1,
        updatedAt: 2,
      );
      expect(tagged.copyWith(color: ServerColor.teal).color, ServerColor.teal);
      // Null alone means "unchanged" in copyWith, so clearing needs its own
      // flag — the same shape secretRef and jumpHostId already use.
      expect(tagged.copyWith(color: null).color, ServerColor.red);
      final cleared = tagged.copyWith(
        clearGroup: true,
        clearColor: true,
        clearIcon: true,
      );
      expect(cleared.group, isNull);
      expect(cleared.color, isNull);
      expect(cleared.icon, isNull);
    });

    test('copyWith normalizes a group the same way fromJson does', () {
      final base = ServerConfig(
        id: 's1',
        label: 'l',
        host: 'h',
        username: 'u',
        createdAt: 1,
        updatedAt: 2,
      );
      // Otherwise the same name reaching the model by two routes could file
      // two servers into two near-identical sections.
      expect(base.copyWith(group: '  Production  ').group, 'Production');
      expect(base.copyWith(group: '   ').group, isNull);
      expect(
        base.copyWith(group: '  Production  ').toJson()['group'],
        ServerConfig.fromJson({
          ...base.toJson(),
          'group': '  Production  ',
        }).toJson()['group'],
      );
    });

    test('ServerConfig round-trips a multi-line login script', () {
      final script = 'cd /srv/app\ndocker compose ps\ntmux attach -t work';
      final c = ServerConfig(
        id: 's1',
        label: 'l',
        host: 'h',
        username: 'u',
        loginScript: script,
        createdAt: 1,
        updatedAt: 2,
      );
      final back = ServerConfig.fromJson(c.toJson());
      expect(back.loginScript, script);
      expect(back.toJson(), equals(c.toJson()));
    });

    test('login scripts normalize their edges but keep interior newlines', () {
      final base = ServerConfig(
        id: 's1',
        label: 'l',
        host: 'h',
        username: 'u',
        createdAt: 1,
        updatedAt: 2,
      );
      // A trailing newline must not survive as a stray Enter keystroke, while
      // the interior lines are the point of a multi-line script.
      final normalized = ServerConfig.fromJson({
        ...base.toJson(),
        'loginScript': '  cd work \n\ntail -f log  ',
      });
      expect(normalized.loginScript, 'cd work \n\ntail -f log');
      // Blank means none, by either route in.
      expect(normalized.copyWith(loginScript: '   ').loginScript, isNull);
      expect(base.copyWith(loginScript: '').loginScript, isNull);
      expect(base.copyWith(clearLoginScript: true).loginScript, isNull);
      expect(base.copyWith(loginScript: null).loginScript, isNull);
    });

    test('login scripts canonicalize CR line endings to LF', () {
      final base = ServerConfig(
        id: 's1',
        label: 'l',
        host: 'h',
        username: 'u',
        createdAt: 1,
        updatedAt: 2,
      );
      // A \r inside a line reaches a PTY's line discipline as an Enter of its
      // own — one pasted-from-Windows line would otherwise run twice.
      final crlf = ServerConfig.fromJson({
        ...base.toJson(),
        'loginScript': 'cd work\r\ntail -f log\r\n',
      });
      expect(crlf.loginScript, 'cd work\ntail -f log');
      final crOnly = base.copyWith(loginScript: 'cd work\rtail -f log\r');
      expect(crOnly.loginScript, 'cd work\ntail -f log');
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
    test('unknown kind fallback emits a fine-level diagnostic', () async {
      final previousLevel = Logger.root.level;
      final records = <LogRecord>[];
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);

      try {
        expect(recordKindFromName('flurb'), RecordKind.unknown);
        await pumpEventQueue();
        expect(records, hasLength(1));
        expect(records.single.level, Level.FINE);
        expect(records.single.message, contains('flurb'));
      } finally {
        await subscription.cancel();
        Logger.root.level = previousLevel;
      }
    });

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
      expect(dec.kind, RecordKind.unknown);
    });

    test('serialized envelope has no separate kind field', () async {
      final codec = RecordCodec(secureRandomBytes(32));
      final enc = await codec.encrypt(
        DecryptedRecord(
          id: 'bookmark:b1',
          kind: RecordKind.bookmark,
          updatedAt: 42,
          deviceId: 'device-a',
          data: const {'id': 'b1'},
        ),
      );

      final wire = enc.toJson();
      expect(wire.containsKey('kind'), isFalse);
      expect(wire['id'], 'bookmark:b1');
      expect(
        wire.keys,
        unorderedEquals(['id', 'updatedAt', 'deviceId', 'deleted', 'blob']),
      );
    });

    test('unknown kinds decode as unknown and cannot be encrypted', () async {
      final vaultKey = secureRandomBytes(32);
      final codec = RecordCodec(vaultKey);
      // Unknown kinds cannot pass encrypt, so mirror its plaintext shape.
      final blob = await VaultCrypto.sealJson(vaultKey, const {
        'kind': 'flurb',
        'data': {'value': 1},
      });
      final decoded = await codec.decrypt(
        EncryptedRecord(
          id: 'flurb:r1',
          updatedAt: 42,
          deviceId: 'device-a',
          deleted: false,
          seq: 1,
          blob: blob,
        ),
      );

      expect(decoded.kind, RecordKind.unknown);
      expect(decoded.data, {'value': 1});
      await expectLater(
        () async => codec.encrypt(
          const DecryptedRecord(
            id: 'flurb:r1',
            kind: RecordKind.unknown,
            updatedAt: 42,
            deviceId: 'device-a',
          ),
        ),
        throwsArgumentError,
      );
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
