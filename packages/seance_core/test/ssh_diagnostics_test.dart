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
}
