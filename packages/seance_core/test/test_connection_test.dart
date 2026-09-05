import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

ServerConfig config({String? jumpHostId}) => ServerConfig(
      id: 's1',
      label: 'prod',
      host: 'prod.example.com',
      port: 2222,
      username: 'deploy',
      authMethod: AuthMethod.password,
      jumpHostId: jumpHostId,
      createdAt: 1,
      updatedAt: 2,
    );

/// Pass-through bytes, not a digest: dartssh2 hands `onVerifyHostKey` the
/// `SHA256:…` fingerprint *string* as bytes, so these are what a [HostKey]
/// built with `fingerprintSha256: 'SHA256:<s>'` describes.
Uint8List fingerprint(String s) => Uint8List.fromList(utf8.encode('SHA256:$s'));

void main() {
  group('runConnectionTest', () {
    test('reports how authentication completed, not merely that it did',
        () async {
      final result = await runConnectionTest(
        config: config(),
        credentials: () async => const SshCredentials.password('hunter2'),
        authenticate: (_, _, log) async {
          log.add('handshake');
          return AuthKind.key;
        },
      );

      expect(result.ok, isTrue);
      // "Connected" alone would not tell the user their key was the thing that
      // worked — which is exactly what a test of a key-auth server is asking.
      expect(result.summary, contains('deploy@prod.example.com:2222'));
      expect(result.summary, contains('public key'));
      expect(result.log, contains('handshake'));
      expect(result.notes, isEmpty);
    });

    test('a refused connection reuses the real failure summary', () async {
      final log = SshConnectionLog();
      final result = await runConnectionTest(
        config: config(),
        credentials: () async => const SshCredentials.password(''),
        authenticate: (_, _, transcript) async {
          transcript.add('  <- sock: auth failed');
          throw SshConnectException(
            'Password rejected by prod.example.com. Check the credential.',
            // An Exception, not an Error: this file's own rule is that an
            // Error means our bug and keeps a stack trace, while a rejected
            // password is the expected, readable kind of failure.
            Exception('auth rejected'),
            transcript,
          );
        },
        log: log,
      );

      expect(result.ok, isFalse);
      // Verbatim: a second wording here would be a second thing to keep true,
      // and the user would see two different sentences about one host.
      expect(
        result.summary,
        'Password rejected by prod.example.com. Check the credential.',
      );
      expect(result.log, contains('auth failed'));
    });

    test('a failure before the handshake still lands in the transcript',
        () async {
      // Resolving credentials can fail on its own — a locked keyring, an
      // identity file the sandbox will not open. Nothing has written to the
      // log at that point, so an expanded log would stop mid-sentence.
      final result = await runConnectionTest(
        config: config(),
        credentials: () async => throw StateError('keyring is locked'),
        authenticate: (_, _, _) async => fail('must not be reached'),
      );

      expect(result.ok, isFalse);
      expect(result.summary, contains('keyring is locked'));
      expect(result.log, contains('keyring is locked'));
      // And keeps its trace: an Error before the handshake is our bug, which
      // is the policy the later stack-trace test states in full.
      expect(result.log, contains('runConnectionTest'));
    });

    test('the unimplemented agent path reads as a sentence, not a crash',
        () async {
      final result = await runConnectionTest(
        config: config(),
        credentials: () async => const SshCredentials.agent(),
        authenticate: (_, _, _) async =>
            throw UnsupportedError('Agent auth is not available yet.'),
      );

      expect(result.ok, isFalse);
      expect(result.summary, 'Agent auth is not available yet.');
      expect(result.summary, isNot(contains('Unsupported operation')));
    });

    test('a jump host is called out rather than silently ignored', () async {
      // ProxyJump is modelled but not executed, so a direct success here does
      // not mean the server is reachable the way it will be used.
      final result = await runConnectionTest(
        config: config(jumpHostId: 'bastion'),
        credentials: () async => const SshCredentials.password('x'),
        authenticate: (_, _, _) async => AuthKind.storedPassword,
      );

      expect(result.ok, isTrue);
      expect(result.notes, hasLength(1));
      expect(result.notes.single, contains('jump host'));
    });

    test('the jump-host caveat also accompanies a failure', () async {
      // The caveat matters most on the failure it explains: "could not reach
      // the host" means something different for a host only reachable through
      // a bastion the test did not use.
      final result = await runConnectionTest(
        config: config(jumpHostId: 'bastion'),
        credentials: () async => const SshCredentials.password('x'),
        authenticate: (_, _, transcript) async => throw SshConnectException(
          'Could not reach prod.example.com:2222.',
          const SocketException('refused'),
          transcript,
        ),
      );

      expect(result.ok, isFalse);
      expect(result.notes.single, contains('jump host'));
    });

    test('a bug keeps its stack trace, an expected failure stays readable',
        () async {
      // An Error here is our bug, and its message alone rarely says where it
      // came from. An Exception — a locked keyring, an unreadable key file —
      // already says everything a person can act on, and a stack trace under
      // one is noise in a transcript people read.
      final bug = await runConnectionTest(
        config: config(),
        credentials: () async => throw StateError('bad state'),
        authenticate: (_, _, _) async => fail('must not be reached'),
      );
      expect(bug.log, contains('runConnectionTest'));

      final expected = await runConnectionTest(
        config: config(),
        credentials: () async =>
            throw const FormatException('unreadable identity file'),
        authenticate: (_, _, _) async => fail('must not be reached'),
      );
      expect(expected.log, contains('unreadable identity file'));
      expect(expected.log, isNot(contains('runConnectionTest')));

      // Past the credentials call the calculus flips. openAuthenticatedClient
      // wraps every failure it can name in SshConnectException, so a bare
      // Exception from authenticate is one nothing was written to expect —
      // and the trace is the only thing that says where it came from.
      final unexpected = await runConnectionTest(
        config: config(),
        credentials: () async => const SshCredentials.password('pw'),
        authenticate: (_, _, _) async =>
            throw const FormatException('unwrapped transport failure'),
      );
      expect(unexpected.log, contains('unwrapped transport failure'));
      expect(unexpected.log, contains('runConnectionTest'));

      // The one Error that stays quiet, wherever it comes from: the ssh-agent
      // path the backend deliberately does not implement.
      final unsupported = await runConnectionTest(
        config: config(),
        credentials: () async => const SshCredentials.password('pw'),
        authenticate: (_, _, _) async => throw UnsupportedError('no agent'),
      );
      expect(unsupported.log, contains('no agent'));
      expect(unsupported.log, isNot(contains('runConnectionTest')));
    });

    test('a summary an authenticator already logged is not repeated', () async {
      // The contract on HostAuthenticator: log the summary only when throwing
      // SshConnectException, whose message runConnectionTest takes verbatim.
      // Asserted here so the shipped authenticator's own behaviour is pinned
      // rather than assumed.
      const summary = 'Could not reach host.example.com:22 — refused';
      final log = SshConnectionLog();
      final result = await runConnectionTest(
        config: config(),
        log: log,
        credentials: () async => const SshCredentials.password('pw'),
        authenticate: (_, _, transcript) async {
          transcript.add(summary);
          throw SshConnectException(
            summary,
            const SocketException('refused'),
            transcript,
          );
        },
      );
      expect(result.ok, isFalse);
      // The whole summary, not a word it shares with its own cause: counting
      // 'refused' would also count the SocketException if that were ever
      // logged, and then this would fail for the wrong reason.
      expect(
        summary.allMatches(result.log).length,
        1,
        reason: 'the summary must appear once, not once per writer',
      );
    });

    test('a pre-handshake SshConnectException still lands in the transcript',
        () async {
      // The SSH layer logs its own summary before throwing this type, which is
      // why the branch appends nothing — but a resolver that reuses the type
      // has logged nothing, and the transcript would end mid-sentence.
      final result = await runConnectionTest(
        config: config(),
        credentials: () async => throw SshConnectException(
          'The identity file could not be read',
          const FormatException('bad key'),
          SshConnectionLog(),
        ),
        authenticate: (_, _, _) async => fail('must not be reached'),
      );
      expect(result.ok, isFalse);
      expect(result.log, contains('The identity file could not be read'));
    });

    test('the notes a result carries cannot be edited through it', () async {
      // The same instance flows into all three results, and a caller that
      // sorted or filtered it in place would be editing what it was handed.
      final result = await runConnectionTest(
        config: config(),
        credentials: () async => const SshCredentials.password('pw'),
        authenticate: (_, _, _) async => AuthKind.storedPassword,
      );
      expect(() => result.notes.add('mine'), throwsUnsupportedError);
    });

    test('every auth kind has a label', () {
      for (final kind in AuthKind.values) {
        expect(authKindLabel(kind), isNotEmpty);
      }
    });
  });

  group('UnpinnedHostKeyStore', () {
    test('reads existing pins but never writes one through', () async {
      final real = InMemoryHostKeyStore();
      final pinned = HostKey(
        host: 'known.example.com',
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:known',
        pinnedAt: 1,
      );
      await real.put(pinned);
      final trial = UnpinnedHostKeyStore(real);

      expect(await trial.get('known.example.com', 22), same(pinned));

      // Approving an unknown host inside a trial holds for the trial…
      final fresh = HostKey(
        host: 'new.example.com',
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:new',
        pinnedAt: 2,
      );
      await trial.put(fresh);
      expect(await trial.get('new.example.com', 22), same(fresh));
      expect((await trial.all()).length, 2);

      // Re-approving a host that is already pinned lists once, not twice, and
      // lists as the trial's version — the precedence get() establishes.
      final reapproved = HostKey(
        host: 'known.example.com',
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:rotated',
        pinnedAt: 3,
      );
      await trial.put(reapproved);
      final merged = await trial.all();
      expect(merged, hasLength(2));
      // Named, not just counted: a concatenating `all()` that returned the
      // original pin would also be length 2 while contradicting `get`.
      expect(merged, containsAll([fresh, reapproved]));
      expect(merged, isNot(contains(pinned)));
      expect(await trial.get('known.example.com', 22), same(reapproved));

      // …and nowhere else. The first real connection asks again and pins for
      // real, so a form that is never saved leaves no trust behind.
      expect(await real.get('new.example.com', 22), isNull);
      expect(await real.all(), [pinned]);
    });

    test('a trial approval satisfies the verifier it is wrapped in', () async {
      final trial = UnpinnedHostKeyStore(InMemoryHostKeyStore());
      final verifier = TofuVerifier(trial);
      final manager = SshSessionManager(
        tofu: verifier,
        onHostKey: (_) async => true,
      );

      // First use: prompted, approved, pinned into the trial store.
      expect(
        await manager.verifyHostKey(
          host: 'new.example.com',
          port: 22,
          type: 'ssh-ed25519',
          fingerprintBytes: fingerprint('new'),
        ),
        isTrue,
      );
      // Second offer of the same key is trusted without another prompt, so a
      // reconnect inside one attempt does not re-ask.
      final decision = await verifier.check(HostKey(
        host: 'new.example.com',
        port: 22,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:new',
        pinnedAt: 3,
      ));
      expect(decision.verdict, HostKeyVerdict.trusted);

      // And a *different* key for that host is still the MITM case: one
      // approval trusts one key, not the host forever.
      final mismatch = await verifier.check(HostKey(
        host: 'new.example.com',
        port: 22,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:attacker',
        pinnedAt: 4,
      ));
      expect(mismatch.verdict, HostKeyVerdict.changed);
    });
  });
}
