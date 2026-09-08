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
      // `lines` is what the transcript view reads on every repaint; pinned to
      // the same redaction so a scrub moved to render time could not pass
      // this suite while handing the view the raw answer.
      expect(log.lines.join('\n'), isNot(contains('hunter2')));
      expect(log.lines.join('\n'), isNot(contains('123456')));
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
      // The case that tells a greedy match from a lazy one: here the
      // password *contains* the terminator, so a pattern stopping at the
      // first `])` would leave `tail])` in the transcript verbatim while
      // every other case in this group still passed.
      log.add('-> sock: SSH_Message_Userauth_InfoResponse'
          '(responses: [secret])tail])');
      expect(log.toString(), isNot(contains('tail')));
      expect(log.toString(), isNot(contains('sword')));
      // And the head of the first answer, which every other assertion here
      // leaves to the second line: a match anchored after a `]` would redact
      // `sword])` and leave `pas` standing.
      expect(log.toString(), isNot(contains('pas]')));
      // The head of the second answer too: every other assertion here targets
      // what follows the bracket, so a match that started at the wrong `]`
      // would leave the front of a credential standing.
      expect(log.toString(), isNot(contains('secret')));
      // And on the view the transcript widget reads, not only on the render:
      // a scrub that moved to render time would hand this the raw answer.
      expect(log.lines.join('\n'), isNot(contains('tail')));
      expect(log.lines.join('\n'), isNot(contains('sword')));
      // The heads too, which the view assertions above left to `toString`:
      // if the two ever diverge, the front of a credential is as much of a
      // leak on the widget's side as the tail is.
      expect(log.lines.join('\n'), isNot(contains('pas]')));
      expect(log.lines.join('\n'), isNot(contains('secret')));
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
        final at =
            'U+${breakChar.runes.first.toRadixString(16).padLeft(4, '0')}';
        expect(log.toString(), isNot(contains('sword')),
            reason: 'leaked past $at');
        // And the half *before* the break, which the bracket test pins for
        // its own case: a match anchored after the terminator would redact
        // the tail and leave `responses: [pas` standing, satisfying every
        // assertion about `sword`.
        expect(log.toString(), isNot(contains('pas')),
            reason: 'head leaked before $at');
        expect(log.lines.join('\n'), isNot(contains('sword')),
            reason: 'view leaked past $at');
        expect(log.lines.join('\n'), isNot(contains('pas')),
            reason: 'view head leaked before $at');
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
      // Two layers, and the cast is what makes the second one assertable.
      // `lines` is typed `Iterable<String>`, so `lines.add('third')` is a
      // compile error and no call site can reach the runtime guard by
      // accident. Cast past that and the view still refuses, because nothing
      // may append past the redaction in `add`.
      expect(() => (lines as List<String>).add('third'),
          throwsUnsupportedError);
      // And left it alone: a view that mutated before throwing would satisfy
      // the expectation above while appending past the redaction anyway.
      expect(lines, hasLength(2));
    });

    test('a renamed class and a renamed field together still never leak', () {
      // The one cell of the rename matrix the tests above left open: neither
      // the shape anchor nor the exact class name matches this line, so the
      // fail-closed branch has to trigger on the part of the name a rename is
      // least likely to touch.
      final log = SshConnectionLog();
      log.add('-> sock: SSHMsgUserauthInfoResponse(answers: [hunter2])');
      expect(log.toString(), isNot(contains('hunter2')));
      // Which branch, not just the outcome: the shape anchor cannot match
      // `answers:`, so only the withhold can have produced this.
      expect(log.toString(), contains('does not recognize'));
      // And on the view, which the group's opening comment requires of
      // every case: a scrub moved to render time would leave the
      // transcript widget reading the raw record on each repaint.
      expect(log.lines.join('\n'), isNot(contains('hunter2')));
      // And a request line, which shares everything but that part, stays.
      final request = SshConnectionLog();
      request.add('-> sock: SSHMsgUserauthInfoRequest(prompts: [Password:])');
      // Pinned whole, like the canonical-line test: `contains` would pass
      // just as well if the fail-closed branch had swallowed the record and
      // echoed the prompt inside its own sentence.
      expect(
        request.toString(),
        '-> sock: SSHMsgUserauthInfoRequest(prompts: [Password:])',
      );
    });

    test('a drifted record is withheld even with a later responses list', () {
      // The fail-closed branch asked only whether the pattern matched
      // *somewhere*. A record whose own field had drifted, followed by an
      // unrelated `responses: [`, matched on the later one, skipped the
      // withhold, and had only that occurrence replaced — leaving the
      // credential ahead of it in the transcript verbatim.
      final log = SshConnectionLog();
      log.add('-> sock: SSH_Message_Userauth_InfoResponse(answers: [hunter2])'
          ' … then (responses: [ok])');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), contains('does not recognize'));
      // And on the view, which the group's opening comment requires of
      // every case: a scrub moved to render time would leave the
      // transcript widget reading the raw record on each repaint.
      expect(log.lines.join('\n'), isNot(contains('hunter2')));
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
      // And on the view, which the group's opening comment requires of
      // every case: a scrub moved to render time would leave the
      // transcript widget reading the raw record on each repaint.
      expect(log.lines.join('\n'), isNot(contains('hunter2')));
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
      // And the view the transcript widget reads, like the sibling cases:
      // a scrub moved to render time would hand it the raw answer.
      expect(log.lines.join('\n'), isNot(contains('hunter2')));
    });

    test('a tail chunk carrying no class name is redacted too', () {
      // Every producer hands `add` a whole record today. If one ever split a
      // message, the chunk with the credential in it would be the one without
      // the name — the case a name-anchored pattern cannot see.
      final log = SshConnectionLog();
      log.add('(responses: [hunter2])');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), contains('(responses: [redacted])'));
      // And the view — this shape carries no class name, so it never reaches
      // the fail-closed branch and capture-time redaction is its only guard.
      expect(log.lines.join('\n'), isNot(contains('hunter2')));
    });

    test('a tail chunk cut before its terminator is redacted too', () {
      // The other half of the split-message case: a chunk boundary can fall
      // before the `])` as easily as after the class name. Neither guard can
      // see this line — there is no class name for the fail-closed branch,
      // and no terminator for a bracket-bounded pattern — so what protects it
      // is that the shape runs to end of line rather than to `])`. Nothing
      // pinned that: every other case here happens to carry a terminator, so
      // an implementation anchored on one passed the whole group.
      final log = SshConnectionLog();
      log.add('(responses: [hunter2');
      expect(log.toString(), isNot(contains('hunter2')));
      // Redacted in place rather than dropped, like every other case in this
      // group pins: a scrubber that discarded a line it could not parse
      // would satisfy the absence checks while quietly deleting transcript.
      expect(log.toString(), contains('[redacted]'));
      expect(log.lines.join('\n'), isNot(contains('hunter2')));
      // In place on the view as well as in `toString`: a view that dropped
      // the unterminated chunk rather than scrubbing it would satisfy the
      // absence above while silently losing transcript from the widget.
      expect(log.lines.join('\n'), contains('[redacted]'));
    });

    test('an unrelated field ahead of the credential does not shelter it', () {
      // Two messages joined into one chunk, in the order the positional
      // withhold does *not* cover: an unrelated `responses:` first, then a
      // named message whose own field has drifted. The leftmost match starts
      // before the token, so the withhold is skipped by design — and the
      // credential behind it is still safe, because the shape runs to end of
      // line and swallows everything after the first `responses:`.
      //
      // Pinned because that is a composition, not a property of either half:
      // a pattern anchored on `])` would redact only the first list and leave
      // the password of the second standing, with the withhold already
      // declined and nothing else looking.
      expect(
        redactConnectionTrace(
          'A(responses: [x]) SSH_Message_Userauth_InfoResponse(replies: [pw])',
        ),
        // Which branch, not only the absence: the comment above says the
        // withhold is skipped here and the leftmost match swallows the rest,
        // so the output is the in-place redaction. Asserted, because
        // over-redacting to a withhold satisfies an absence check while the
        // composition this case is named for stopped happening.
        allOf(isNot(contains('pw')), contains('A(responses: [redacted])')),
      );
      // And the same two messages the other way round, where the withhold is
      // what covers it: the token comes first, so the later match cannot
      // vouch for it and the whole record is held back.
      expect(
        redactConnectionTrace(
          'SSH_Message_Userauth_InfoResponse(replies: [pw]) B(responses: [x])',
        ),
        // The branch, not only the absence: this ordering is the one the
        // withhold covers, and an absence assertion alone would be satisfied
        // by any other path that happened to scrub it — including
        // over-redacting the line away entirely.
        allOf(isNot(contains('pw')), contains('does not recognize')),
      );
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
      // And the other side of the colon, still on a bare chunk: there is no
      // class name here for the fail-closed branch to catch, so a pattern
      // that stopped tolerating the missing space would leak outright rather
      // than withhold. The exact pin below is the only guard on this one —
      // which is what the block after it, on a *named* line, is for.
      expect(
        redactConnectionTrace('(responses:[hunter2])'),
        '(responses: [redacted])',
      );
      final log = SshConnectionLog();
      log.add('-> sock: SSHMsgUserauthInfoResponse(responses:[hunter2])');
      expect(log.toString(), isNot(contains('hunter2')));
      // The branch, not just the absence: this line carries a class name, so
      // losing the spacing tolerance would send it to the fail-closed withhold
      // — which satisfies the assertion above while the shape anchor this test
      // is about stopped matching.
      expect(log.toString(), contains('(responses: [redacted])'));
      // And on the view, like every other log test in this group: the
      // transcript widget reads `lines` on each repaint, so a scrub that
      // only held at `toString` time would render the raw answer.
      expect(log.lines.join('\n'), isNot(contains('hunter2')));
      // Redacted there, not dropped: absence alone is also what a view that
      // discarded the record entirely would give, and that loses transcript
      // from the widget without a word.
      expect(log.lines.join('\n'), contains('(responses: [redacted])'));
    });

    test('a renamed field still hits the fail-closed branch', () {
      // Loose spacing must not loosen the shape: `answers:` is a rename, not
      // a spacing tweak, and it has to be withheld whole rather than pass.
      final log = SshConnectionLog();
      log.add('-> sock: SSH_Message_Userauth_InfoResponse'
          '(answers: [hunter2])');
      expect(log.toString(), isNot(contains('hunter2')));
      expect(log.toString(), contains('does not recognize'));
      // And on the view, which the group's opening comment requires of
      // every case: a scrub moved to render time would leave the
      // transcript widget reading the raw record on each repaint.
      expect(log.lines.join('\n'), isNot(contains('hunter2')));
      // Withheld there too rather than filtered away: absence alone is also
      // what a view that dropped a record it could not parse would give, and
      // that loses transcript from the widget without a word.
      expect(log.lines.join('\n'), contains('does not recognize'));
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
