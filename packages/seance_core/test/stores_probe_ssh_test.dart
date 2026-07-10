import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

class _FakeProber implements Prober {
  final Map<String, ProbeStatus> byHost;
  _FakeProber(this.byHost);
  @override
  Future<ProbeStatus> probe(String host, int port,
          {Duration timeout = const Duration(seconds: 5)}) async =>
      byHost[host] ?? ProbeStatus.unknown;
}

ServerConfig server(String id, String host) => ServerConfig(
      id: id,
      label: id,
      host: host,
      username: 'u',
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  group('SecretVault', () {
    test('round-trips a secret and stores only an opaque blob', () async {
      final vaultKey = secureRandomBytes(32);
      final store = InMemoryVaultStore();
      final vault = SecretVault(store, vaultKey);

      final secret = Secret(
          id: 's1', kind: SecretKind.password, value: 'hunter2-very-secret');
      await vault.putSecret(secret);

      final blob = await store.getSecretBlob('s1');
      expect(String.fromCharCodes(blob!), isNot(contains('hunter2')));

      final loaded = await vault.getSecret('s1');
      expect(loaded!.value, 'hunter2-very-secret');
      expect(loaded.kind, SecretKind.password);
    });

    test('cannot open a secret with the wrong vault key', () async {
      final store = InMemoryVaultStore();
      await SecretVault(store, secureRandomBytes(32))
          .putSecret(Secret(id: 's', kind: SecretKind.password, value: 'x'));
      final wrong = SecretVault(store, secureRandomBytes(32));
      expect(() => wrong.getSecret('s'), throwsA(anything));
    });
  });

  group('InMemoryConfigStore', () {
    test('CRUD and alphabetical listing', () async {
      final store = InMemoryConfigStore();
      await store.putServer(server('b', 'b.example.com'));
      await store.putServer(server('a', 'a.example.com'));
      expect((await store.listServers()).map((s) => s.id), ['a', 'b']);
      await store.deleteServer('a');
      expect((await store.listServers()).map((s) => s.id), ['b']);
    });
  });

  group('ProbeService.probeAll', () {
    test('maps each server id to a tri-state status', () async {
      final svc = ProbeService(prober: _FakeProber({
        'up.example.com': ProbeStatus.online,
        'down.example.com': ProbeStatus.offline,
        // bastion.example.com omitted -> unknown
      }));
      final result = await svc.probeAll([
        server('1', 'up.example.com'),
        server('2', 'down.example.com'),
        server('3', 'bastion.example.com'),
      ]);
      expect(result['1'], ProbeStatus.online);
      expect(result['2'], ProbeStatus.offline);
      expect(result['3'], ProbeStatus.unknown);
      await svc.dispose();
    });
  });

  group('SshSessionManager.verifyHostKey (TOFU)', () {
    Uint8List fp(String s) => Uint8List.fromList(utf8.encode('SHA256:$s'));

    test('first use prompts, pins on approval, then trusts silently', () async {
      final store = InMemoryHostKeyStore();
      var prompts = 0;
      final mgr = SshSessionManager(
        tofu: TofuVerifier(store),
        onHostKey: (decision) async {
          prompts++;
          expect(decision.verdict, HostKeyVerdict.firstUse);
          return true; // approve
        },
      );

      final ok = await mgr.verifyHostKey(
          host: 'h', port: 22, type: 'ssh-ed25519', fingerprintBytes: fp('AAA'));
      expect(ok, isTrue);
      expect(prompts, 1);

      // Second connection with the same key: trusted, no prompt.
      final ok2 = await mgr.verifyHostKey(
          host: 'h', port: 22, type: 'ssh-ed25519', fingerprintBytes: fp('AAA'));
      expect(ok2, isTrue);
      expect(prompts, 1);
    });

    test('a changed key surfaces as "changed" and is refused if not approved',
        () async {
      final store = InMemoryHostKeyStore();
      HostKeyDecision? seen;
      final mgr = SshSessionManager(
        tofu: TofuVerifier(store),
        onHostKey: (decision) async {
          seen = decision;
          return decision.verdict == HostKeyVerdict.firstUse; // reject changes
        },
      );

      await mgr.verifyHostKey(
          host: 'h', port: 22, type: 'ssh-ed25519', fingerprintBytes: fp('AAA'));
      final ok = await mgr.verifyHostKey(
          host: 'h', port: 22, type: 'ssh-ed25519', fingerprintBytes: fp('EVIL'));

      expect(seen!.verdict, HostKeyVerdict.changed);
      expect(ok, isFalse);
      // The pinned key is unchanged despite the rejected attempt.
      expect((await store.get('h', 22))!.fingerprintSha256, 'SHA256:AAA');
    });
  });

  group('HeadlessTerminalEngine', () {
    test('accumulates fed bytes and emits typed input', () async {
      final engine = HeadlessTerminalEngine();
      final got = <int>[];
      final sub = engine.userInput.listen(got.addAll);
      engine.feed(Uint8List.fromList('hello '.codeUnits));
      engine.feed(Uint8List.fromList('world'.codeUnits));
      engine.type('ls\n'.substring(0, 2)); // "ls"
      await Future<void>.delayed(Duration.zero);
      expect(engine.receivedText, 'hello world');
      expect(String.fromCharCodes(got), 'ls');
      await sub.cancel();
      await engine.dispose();
    });

    test('decodes received bytes and encodes typed text as UTF-8', () async {
      final engine = HeadlessTerminalEngine();
      final got = <int>[];
      final sub = engine.userInput.listen(got.addAll);

      engine.feed(Uint8List.fromList([...utf8.encode('hé😀'), 0xff]));
      engine.type('λ😀');
      await Future<void>.delayed(Duration.zero);

      expect(engine.receivedText, 'hé😀\uFFFD');
      expect(got, utf8.encode('λ😀'));
      await sub.cancel();
      await engine.dispose();
    });
  });
}
