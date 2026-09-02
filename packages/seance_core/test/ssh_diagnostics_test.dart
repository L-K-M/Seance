import 'dart:convert';

import 'package:dartssh2/dartssh2.dart' show SSHAuthFailError;
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

ServerConfig _server() => ServerConfig(
      id: 's',
      label: 's',
      host: 'unreachable.example.com',
      port: 2222,
      username: 'me',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  group('SshConnectionLog', () {
    test('accumulates lines, joins on toString, and notifies onUpdate', () {
      var updates = 0;
      final log = SshConnectionLog(onUpdate: () => updates++);
      log.add('one');
      log.add('two');
      expect(log.lines, ['one', 'two']);
      expect(log.toString(), 'one\ntwo');
      expect(updates, 2);
    });

    test('freeze stops recording and notifying (no per-packet rebuild storm)',
        () {
      var updates = 0;
      final log = SshConnectionLog(onUpdate: () => updates++);
      log.add('connecting');
      log.freeze();
      log.add('trace after connect'); // dartssh2 keeps calling printTrace
      expect(log.lines, ['connecting'], reason: 'frozen adds are dropped');
      expect(updates, 1, reason: 'onUpdate must not fire once frozen');
    });

    test('caps the transcript so a busy session cannot grow it without limit',
        () {
      final log = SshConnectionLog();
      for (var i = 0; i < 1000; i++) {
        log.add('line $i');
      }
      expect(log.lines.length, lessThanOrEqualTo(400));
      expect(log.lines.last, 'line 999'); // newest kept
    });
  });

  group('SshSessionManager.connect diagnostics', () {
    test('a TCP failure surfaces a readable SshConnectException with a log',
        () async {
      final mgr = SshSessionManager(
        tofu: TofuVerifier(InMemoryHostKeyStore()),
        onHostKey: (_) async => true,
        connect: (host, port, timeout) async =>
            throw Exception('Connection refused'),
      );
      final log = SshConnectionLog();
      final engine = HeadlessTerminalEngine();

      await expectLater(
        () => mgr.connect(
          config: _server(),
          credentials: const SshCredentials.password('pw'),
          engine: engine,
          log: log,
        ),
        throwsA(isA<SshConnectException>().having(
            (e) => e.message, 'message', contains('Could not reach'))),
      );

      // The transcript records the target and the attempted method, so the UI
      // can show *what happened* rather than a bare error.
      expect(log.toString(), contains('me@unreachable.example.com:2222'));
      expect(log.toString(), contains('Auth method: password'));

      await engine.dispose();
    });

    test('an invalid private key is rejected before opening a socket',
        () async {
      var connectorCalled = false;
      final mgr = SshSessionManager(
        tofu: TofuVerifier(InMemoryHostKeyStore()),
        onHostKey: (_) async => true,
        connect: (host, port, timeout) async {
          connectorCalled = true;
          throw StateError('should not connect');
        },
      );
      final log = SshConnectionLog();
      final engine = HeadlessTerminalEngine();

      await expectLater(
        () => mgr.connect(
          config: _server(),
          credentials: const SshCredentials.privateKey('not a PEM key'),
          engine: engine,
          log: log,
        ),
        throwsA(isA<SshConnectException>().having(
          (e) => e.message,
          'message',
          contains('Could not load the private key'),
        )),
      );

      expect(connectorCalled, isFalse);
      expect(log.toString(), contains('Auth method: public key'));
      expect(log.toString(), contains('Could not load the private key'));
      expect(log.toString(), isNot(contains('Connecting to')));
      await engine.dispose();
    });

    SshConnectionLog logWith(List<String> accepted) => SshConnectionLog()
      ..add('  <- sock: SSH_Message_Userauth_Failure('
          'methodsLeft: [${accepted.join(', ')}], partialSuccess: false)');

    ServerConfig config(String user) => ServerConfig(
          id: 's',
          label: 's',
          host: 'h.example.com',
          port: 22,
          username: user,
          createdAt: 0,
          updatedAt: 0,
        );

    test('auth summary flags root password rejection (prohibit-password)', () {
      final msg = SshSessionManager.summarizeFailureForTest(
        SSHAuthFailError('All authentication methods failed'),
        config('root'),
        const SshCredentials.password('pw'),
        logWith(['publickey', 'password']),
      );
      expect(msg, contains('The server accepts: publickey, password'));
      expect(msg, contains('prohibit-password'));
    });

    test('auth summary tells you to switch method when password is not offered',
        () {
      final msg = SshSessionManager.summarizeFailureForTest(
        SSHAuthFailError('All authentication methods failed'),
        config('me'),
        const SshCredentials.password('pw'),
        logWith(['publickey']),
      );
      expect(msg, contains('The server accepts: publickey'));
      expect(msg, contains('Switch this server to a method the host allows'));
    });

    test('auth summary names the rejected key and points at authorized_keys',
        () {
      final log = SshConnectionLog()
        ..add('Offering key: ssh-ed25519 SHA256:AbCdEf123')
        ..add('  <- sock: SSH_Message_Userauth_Failure('
            'methodsLeft: [publickey, password], partialSuccess: false)');
      final msg = SshSessionManager.summarizeFailureForTest(
        SSHAuthFailError('All authentication methods failed'),
        config('root'),
        const SshCredentials.privateKey('pem'),
        log,
      );
      expect(msg, contains('SHA256:AbCdEf123'));
      expect(msg, contains('authorized_keys'));
      // A rejected key must not be misreported as prohibit-password.
      expect(msg, isNot(contains('prohibit-password')));
    });

    test('auth summary says check-the-credential for a non-root password reject',
        () {
      final msg = SshSessionManager.summarizeFailureForTest(
        SSHAuthFailError('All authentication methods failed'),
        config('deploy'),
        const SshCredentials.password('pw'),
        logWith(['publickey', 'password']),
      );
      expect(msg, contains('Check the credential'));
    });

    test('agent auth is rejected before any network activity', () async {
      final mgr = SshSessionManager(
        tofu: TofuVerifier(InMemoryHostKeyStore()),
        onHostKey: (_) async => true,
        connect: (host, port, timeout) async =>
            throw StateError('should not connect'),
      );
      final engine = HeadlessTerminalEngine();
      await expectLater(
        () => mgr.connect(
          config: _server(),
          credentials: const SshCredentials.agent(),
          engine: engine,
        ),
        throwsA(isA<UnsupportedError>()),
      );
      await engine.dispose();
    });
  });

  group('SshSessionManager.openAuthenticatedClient diagnostics', () {
    test('opens authentication without requiring a terminal engine', () async {
      final log = SshConnectionLog();

      await expectLater(
        () => openAuthenticatedClient(
          config: _server(),
          credentials: const SshCredentials.password('pw'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => true,
          connect: (host, port, timeout) async =>
              throw Exception('Connection refused'),
          log: log,
        ),
        throwsA(isA<SshConnectException>().having(
            (e) => e.message, 'message', contains('Could not reach'))),
      );

      expect(log.toString(), contains('Auth method: password'));
    });
  });

  group('login script keystrokes', () {
    test('the script is one typed line: text plus a single Enter', () {
      final bytes = SshSessionManager.loginScriptKeystrokes('tmux attach');
      expect(bytes, utf8.encode('tmux attach\n'));
    });

    test('interior newlines survive; outer edges do not', () {
      // Each interior line executes in order, like a pasted multi-line
      // command; the trailing newline of the stored form must not become a
      // stray second Enter that runs an empty line.
      final bytes = SshSessionManager.loginScriptKeystrokes(
        ' cd work \n\ntail -f log \n',
      );
      expect(bytes, utf8.encode('cd work \n\ntail -f log\n'));
    });

    test('non-ASCII survives the trip to bytes', () {
      final bytes = SshSessionManager.loginScriptKeystrokes('echo héllo→');
      expect(utf8.decode(bytes), 'echo héllo→\n');
    });

    test('blank input is rejected with a clear error', () {
      expect(() => SshSessionManager.loginScriptKeystrokes('   '),
          throwsArgumentError);
      expect(() => SshSessionManager.loginScriptKeystrokes(''),
          throwsArgumentError);
    });

    ServerConfig configWithScript(String? script) => ServerConfig(
          id: 's1',
          label: 'l',
          host: 'h',
          username: 'u',
          loginScript: script,
          createdAt: 1,
          updatedAt: 2,
        );

    test('a config without a usable script contributes no keystrokes', () {
      // The const constructor does not normalize, so the connect-time seam
      // must decide on its own that whitespace-only means "nothing to run".
      expect(SshSessionManager.loginScriptKeystrokesFor(
          configWithScript(null)), isNull);
      expect(SshSessionManager.loginScriptKeystrokesFor(
          configWithScript('  \r\n ')), isNull);
      final keystrokes = SshSessionManager.loginScriptKeystrokesFor(
          configWithScript('cd work'));
      expect(keystrokes, utf8.encode('cd work\n'));
    });
  });
}
