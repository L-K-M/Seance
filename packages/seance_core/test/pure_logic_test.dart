import 'package:seance_core/src/hostkey/tofu.dart';
import 'package:seance_core/src/llm/danger_linter.dart';
import 'package:seance_core/src/llm/redaction.dart';
import 'package:seance_core/src/ssh_config/ssh_config_import.dart';
import 'package:seance_core/src/terminal/paste_sanitizer.dart';
import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

class _MemHostKeyStore implements HostKeyStore {
  final _map = <String, HostKey>{};
  @override
  Future<List<HostKey>> all() async => _map.values.toList();
  @override
  Future<HostKey?> get(String host, int port) async => _map['$host:$port'];
  @override
  Future<void> put(HostKey key) async => _map[key.locator] = key;
}

void main() {
  group('SshConfigImporter', () {
    test('parses hosts, ignores wildcard-only defaults and comments', () {
      const text = '''
# global defaults
Host *
  ServerAliveInterval 60

Host prod
  HostName prod.example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/prod_ed25519

Host bastion db
  HostName 10.0.0.5
  ProxyJump prod
''';
      final hosts = SshConfigImporter.parse(text);
      expect(hosts.map((h) => h.alias), ['prod', 'bastion']);

      final prod = hosts.first;
      expect(prod.hostName, 'prod.example.com');
      expect(prod.port, 2222);
      expect(prod.user, 'deploy');
      expect(prod.identityFile, '~/.ssh/prod_ed25519');

      final bastion = hosts[1];
      expect(bastion.effectiveHost, '10.0.0.5');
      expect(bastion.proxyJump, 'prod');
    });

    test('supports Key=value form and quoted values', () {
      const text = 'Host x\n  HostName=x.example.com\n  User="root"\n';
      final h = SshConfigImporter.parse(text).single;
      expect(h.hostName, 'x.example.com');
      expect(h.user, 'root');
    });

    test('converts to a ServerConfig with reference-not-store key auth', () {
      final h = SshConfigImporter.parse(
        'Host x\n HostName h\n IdentityFile ~/.ssh/id\n',
      ).single;
      final cfg = h.toServerConfig(id: 'id1', now: 5);
      expect(cfg.authMethod, AuthMethod.privateKey);
      expect(cfg.identityFilePath, '~/.ssh/id');
      // A keyless host defaults to password, not the (unsupported) ssh-agent,
      // so an imported host can actually be connected to after adding a secret.
      final keylessCfg = SshConfigImporter.parse(
        'Host y\n HostName h\n',
      ).single.toServerConfig(id: 'id2', now: 5);
      expect(keylessCfg.authMethod, AuthMethod.password);
    });
  });

  group('TofuVerifier', () {
    // The SSH library hands us a SHA-256 fingerprint at connect time, so keys
    // are identified by fingerprint here.
    HostKey key(String fp) => HostKey(
      host: 'h',
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:$fp',
      pinnedAt: 0,
    );

    test('first use, then trusted, then changed', () async {
      final v = TofuVerifier(_MemHostKeyStore());
      final first = await v.check(key('AAAA'));
      expect(first.verdict, HostKeyVerdict.firstUse);

      await v.pin(key('AAAA'));
      final second = await v.check(key('AAAA'));
      expect(second.verdict, HostKeyVerdict.trusted);

      final changed = await v.check(key('BBBB'));
      expect(changed.verdict, HostKeyVerdict.changed);
      expect(changed.pinned!.fingerprintSha256, 'SHA256:AAAA');
      expect(changed.presented.fingerprintSha256, 'SHA256:BBBB');
    });

    test('never auto-updates a changed key', () async {
      final store = _MemHostKeyStore();
      final v = TofuVerifier(store);
      await v.pin(key('AAAA'));
      await v.check(key('EVIL'));
      expect((await store.get('h', 22))!.fingerprintSha256, 'SHA256:AAAA');
    });
  });

  group('DangerLinter', () {
    test('flags critical destructive commands', () {
      expect(DangerLinter.worst('rm -rf /'), DangerSeverity.critical);
      expect(DangerLinter.worst('sudo rm -rf ~/'), DangerSeverity.critical);
      expect(
        DangerLinter.worst('dd if=/dev/zero of=/dev/sda'),
        DangerSeverity.critical,
      );
      expect(
        DangerLinter.worst('mkfs.ext4 /dev/sdb1'),
        DangerSeverity.critical,
      );
      expect(DangerLinter.worst(':(){ :|:& };:'), DangerSeverity.critical);
    });

    test('flags recursive delete of a specific system directory', () {
      // These slipped through the old rule (which only matched a bare /, ~, *).
      expect(DangerLinter.worst('rm -rf /etc'), DangerSeverity.critical);
      expect(DangerLinter.worst('sudo rm -rf /var/lib'), DangerSeverity.critical);
      expect(DangerLinter.worst('rm -fr /usr/local'), DangerSeverity.critical);
      expect(DangerLinter.worst('rm -rf *'), DangerSeverity.critical);
      expect(DangerLinter.worst('wipefs -a /dev/sdb'), DangerSeverity.critical);
    });

    test('warns on risky-but-common patterns', () {
      expect(
        DangerLinter.worst('curl https://x.sh | sudo bash'),
        DangerSeverity.warning,
      );
      expect(
        DangerLinter.worst('chmod -R 777 /var/www'),
        DangerSeverity.warning,
      );
      expect(DangerLinter.worst('sudo reboot'), DangerSeverity.warning);
      expect(DangerLinter.worst('shred -u secret.key'), DangerSeverity.warning);
      expect(
        DangerLinter.worst('find . -name "*.log" -delete'),
        DangerSeverity.warning,
      );
      expect(DangerLinter.worst('truncate -s 0 app.log'), DangerSeverity.warning);
      expect(DangerLinter.worst('git clean -fdx'), DangerSeverity.warning);
    });

    test('leaves benign commands alone', () {
      expect(DangerLinter.worst('ls -la'), isNull);
      expect(DangerLinter.worst('git status'), isNull);
      expect(DangerLinter.worst('rm build/output.o'), isNull);
      // A recursive delete of a RELATIVE path is not flagged (no leading /,~,*).
      expect(DangerLinter.worst('rm -rf ./build'), isNull);
      expect(DangerLinter.worst('rm -rf node_modules'), isNull);
      // git clean dry-run and non-forced finds are fine.
      expect(DangerLinter.worst('git clean -n'), isNull);
      expect(DangerLinter.worst('find . -name "*.log"'), isNull);
    });
  });

  group('PasteSanitizer', () {
    test('rejects multi-line paste (a newline would execute)', () {
      expect(
        () => PasteSanitizer.sanitize('echo hi\nrm -rf /'),
        throwsA(isA<UnsafePasteException>()),
      );
      expect(
        () => PasteSanitizer.sanitize('echo hi\n'),
        throwsA(isA<UnsafePasteException>()),
      );
    });

    test('strips control characters but keeps tabs and text', () {
      expect(PasteSanitizer.sanitize('echo hi\tthere'), 'echo hi\tthere');
    });

    test('sanitizeFirstLine collapses a block to its first command', () {
      expect(PasteSanitizer.sanitizeFirstLine('cd /tmp\nrm x\n'), 'cd /tmp');
    });

    test('sanitizeFirstLine treats a bare carriage return as a line break', () {
      expect(PasteSanitizer.sanitizeFirstLine('cd /tmp\rrm x'), 'cd /tmp');
    });
  });

  group('SecretRedactor', () {
    final r = SecretRedactor();

    test('masks API keys, tokens, and JWTs', () {
      expect(
        r.redact('export KEY=sk-ant-abcdefghij0123456789XYZ'),
        isNot(contains('sk-ant-abcdefghij0123456789XYZ')),
      );
      expect(
        r.redact('ghp_0123456789abcdef0123456789abcdef0123'),
        contains('«redacted»'),
      );
      expect(
        r.redact('OPENAI_API_KEY=sk-proj-abc_def-0123456789abcdefXYZ'),
        isNot(contains('sk-proj-abc_def-0123456789abcdefXYZ')),
      );
      expect(
        r.redact('github_pat_0123456789abcdef_0123456789abcdef'),
        contains('«redacted»'),
      );
      expect(r.redact('glpat-0123456789abcdefXYZ12'), contains('«redacted»'));
      final jwt = 'eyJhbGciOiJI.eyJzdWIiOiIxMjM0NTY3ODkw.SflKxwRJSMeKKF2QT4';
      expect(r.redact('token $jwt'), isNot(contains(jwt)));
    });

    test('masks private key blocks entirely', () {
      const key =
          '-----BEGIN OPENSSH PRIVATE KEY-----\nabc123secretkeymaterial\n-----END OPENSSH PRIVATE KEY-----';
      final out = r.redact('here is my key: $key done');
      expect(out, isNot(contains('secretkeymaterial')));
      expect(out, contains('here is my key'));
      expect(out, contains('done'));
    });

    test('masks inline password assignments but keeps the key name', () {
      final out = r.redact('DB_PASSWORD=sup3rSecretValue');
      expect(out, contains('DB_PASSWORD'));
      expect(out, isNot(contains('sup3rSecretValue')));
    });

    test('wouldRedact reports cleanly on benign text', () {
      expect(r.wouldRedact('just a normal sentence'), isFalse);
    });
  });
}
