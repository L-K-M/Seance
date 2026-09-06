import 'dart:convert';

import 'package:dartssh2/dartssh2.dart' show SSHAuthFailError;
// Pinning the exact toString dartssh2 prints is the point: the barrel does not
// export the message, and asserting against a hand-written copy of it would
// prove the pattern against itself rather than against the dependency. The
// lint is not enabled in this workspace, so the directive below is for
// whenever it is, and has to be the line immediately above the import with
// nothing after the code — prose beside it suppresses nothing.
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_userauth.dart';
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
    test('agent auth is rejected before opening a socket', () async {
      final log = SshConnectionLog();

      await expectLater(
        () => openAuthenticatedClient(
          config: _server(),
          credentials: const SshCredentials.agent(),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => true,
          connect: (host, port, timeout) async =>
              throw StateError('should not connect'),
          log: log,
        ),
        throwsA(isA<UnsupportedError>()),
      );

      expect(log.toString(), isNot(contains('Connecting to')));
    });

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

  group('connection-log redaction', () {
    test('a keyboard-interactive answer never reaches the transcript', () {
      // dartssh2 traces every packet through toString.
      // SSH_Message_Userauth_Request deliberately omits its password;
      // SSH_Message_Userauth_InfoResponse prints its `responses` list, and for
      // a host doing password login over keyboard-interactive that list *is*
      // the password. The transcript is shown with a Copy button beside it and
      // is meant for bug reports, so it is neutralised at capture.
      final log = SshConnectionLog();
      log.add('-> sock: SSH_Message_Userauth_InfoResponse'
          '(responses: [hunter2, 123456])');
      log.add('-> sock: SSH_Message_Userauth_Request(user: deploy, '
          'serviceName: ssh-connection, methodName: password)');

      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), isNot(contains('123456')));
      expect(log.toString(), contains('[redacted])'));
      // Everything else about the exchange is still legible — the point of
      // the log is to say what happened.
      expect(log.toString(), contains('methodName: password'));
      expect(log.toString(), contains('user: deploy'));
    });

    test('a password containing a bracket does not leak its tail', () {
      // A Dart list's toString does not escape its elements, so `pas]sword`
      // prints as `responses: [pas]sword])`. A bracket-bounded match would
      // stop after `[pas]` and leave the rest in the transcript.
      final log = SshConnectionLog();
      log.add('-> sock: SSH_Message_Userauth_InfoResponse'
          '(responses: [pas]sword])');
      expect(log.toString(), isNot(contains('sword')));
      expect(log.toString(), contains('[redacted])'));
    });

    test('a password containing a newline does not leak its tail', () {
      // Same escape as the bracket, through a different door: a value pasted
      // from a password manager can carry a line break, and `.` does not match
      // one — so without dotAll the match ends at the break and the rest of
      // the password lands in the transcript verbatim.
      // All four terminators a Dart `.` refuses without dotAll — U+2029
      // included, since this loop is the specification for what the redaction
      // has to span and a later "simplification" that enumerated them would
      // otherwise leave one out.
      for (final breakChar in ['\n', '\r', '\u2028', '\u2029']) {
        final log = SshConnectionLog();
        log.add('-> sock: SSH_Message_Userauth_InfoResponse'
            '(responses: [pas${breakChar}sword])');
        expect(log.toString(), isNot(contains('sword')),
            reason: 'leaked past ${breakChar.codeUnitAt(0)}');
        expect(log.toString(), contains('[redacted])'));
      }
    });

    test('the transcript is a view of the log, not a copy of it', () {
      // Read on every repaint of a live connection, and a copy would also
      // freeze for anything that held on to it.
      final log = SshConnectionLog();
      log.add('first');
      final lines = log.lines;
      log.add('second');
      expect(lines, hasLength(2));
      expect(() => lines.add('third'), throwsUnsupportedError);
    });

    test('the real message dartssh2 sends is the shape this scrubs', () {
      // The one assertion that is not written against my reading of dartssh2:
      // it builds the message the client actually sends and redacts its own
      // toString, so an upgrade that changes the format fails here rather
      // than at the fail-closed branch in production.
      final log = SshConnectionLog();
      log.add('-> sock: '
          '${SSH_Message_Userauth_InfoResponse(responses: const [
            'hunter2',
            'second-answer',
          ])}');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), isNot(contains('second-answer')));
      expect(log.toString(), contains('[redacted])'));
      expect(log.toString(), isNot(contains('does not recognize')));
    });

    test('the real password request never carries the password either', () {
      // The *other* secret-bearing message. dartssh2 omits the password from
      // `SSH_Message_Userauth_Request.toString()` today, so nothing has to
      // scrub it — and until now nothing checked that, so an upgrade that
      // started printing it would put a plaintext password into a transcript
      // this feature shows with a Copy button and invites people to paste
      // into bug reports. Built from the real message for the same reason the
      // InfoResponse one is: a hand-written line would pin my reading of
      // dartssh2 rather than dartssh2.
      final log = SshConnectionLog();
      log.add('-> sock: '
          '${SSH_Message_Userauth_Request.password(
            user: 'deploy',
            password: 'hunter2',
          )}');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), contains('deploy'));
    });

    test('an InfoResponse this build cannot parse is withheld whole', () {
      // Every test above is written against the shape dartssh2 prints today,
      // so they pin the pattern to itself rather than to the dependency. A
      // pub upgrade that changed it would make the pattern miss silently —
      // this is what turns that into over-redaction instead of a leak.
      final log = SshConnectionLog();
      log.add('-> sock: SSH_Message_Userauth_InfoResponse'
          '(numResponses: 1, answers: [hunter2])');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), contains('does not recognize'));
    });

    test('a renamed InfoResponse class is still redacted', () {
      // The fail-closed branch keys off the class name, so a `pub upgrade`
      // that renamed the class would defeat both it and a name-anchored
      // pattern — printing the password with nothing red anywhere. Anchoring
      // on the `(responses: [` shape catches it whatever it is called.
      final log = SshConnectionLog();
      log.add('-> sock: SSHMsgUserauthInfoResponse(responses: [hunter2])');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), contains('SSHMsgUserauthInfoResponse'));
      expect(log.toString(), contains('(responses: [redacted])'));
    });

    test('a tail chunk carrying no class name is redacted too', () {
      // Every producer hands `add` a whole record today. If one ever split a
      // message, the chunk with the credential in it would be the one without
      // the name — the case a name-anchored pattern cannot see.
      final log = SshConnectionLog();
      log.add('(responses: [hunter2])');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), contains('(responses: [redacted])'));
    });

    test('spacing drift around the anchor still redacts', () {
      // A named line whose spacing drifted would at least reach the
      // fail-closed branch, so the cost there is a whole record withheld. A
      // chunk arriving without the name cannot reach that branch at all —
      // this is the case the loose spacing is actually for.
      expect(
        redactConnectionTrace('(responses : [hunter2])'),
        '(responses: [redacted])',
      );
      final log = SshConnectionLog();
      log.add('-> sock: SSHMsgUserauthInfoResponse(responses:[hunter2])');
      expect(log.toString(), isNot(contains('hunter2')));
    });

    test('a renamed field still hits the fail-closed branch', () {
      // Loose spacing must not loosen the shape: `answers:` is a rename, not
      // a spacing tweak, and it has to be withheld whole rather than pass.
      final log = SshConnectionLog();
      log.add('-> sock: SSH_Message_Userauth_InfoResponse'
          '(answers: [hunter2])');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), contains('does not recognize'));
    });

    test('the canonical line still redacts to exactly what it always did', () {
      // Pinned as a whole string, not as a `contains`: making the class name
      // optional must not change the canonical output by a byte, and a field
      // rename must land in the withheld branch rather than quietly here.
      expect(
        redactConnectionTrace(
          '-> sock: SSH_Message_Userauth_InfoResponse(responses: [hunter2])',
        ),
        '-> sock: SSH_Message_Userauth_InfoResponse(responses: [redacted])',
      );
    });

    test('redaction leaves an ordinary trace line untouched', () {
      const line = '  <- sock: SSH_Message_Userauth_Failure('
          'methodsLeft: [publickey], partialSuccess: false)';
      expect(redactConnectionTrace(line), line);
    });
  });
}
