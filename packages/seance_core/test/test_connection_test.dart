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
      SshCredentials? seen;
      final result = await runConnectionTest(
        config: config(),
        credentials: () async => const SshCredentials.password('hunter2'),
        authenticate: (_, creds, log) async {
          seen = creds;
          log.add('handshake');
          return AuthKind.key;
        },
      );
      // The seam the `credentials` parameter exists for: every stub in this
      // file discarded it, so nothing observed that the resolver's answer is
      // what authentication is actually attempted with.
      expect(seen, const SshCredentials.password('hunter2'));

      expect(result.ok, isTrue);
      // "Connected" alone would not tell the user their key was the thing that
      // worked — which is exactly what a test of a key-auth server is asking.
      expect(result.summary, contains('deploy@prod.example.com:2222'));
      expect(result.summary, contains('public key'));
      expect(result.log, contains('handshake'));
      // A tripwire, not a redaction test: nothing should ever put the
      // credential into a transcript shown with a Copy button and meant for
      // bug reports, and one negative assertion keeps it that way.
      expect(result.log, isNot(contains('hunter2')));
      expect(result.summary, isNot(contains('hunter2')));
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
      // The caller's own instance, not just `result.log`: a runConnectionTest
      // that ignored `log:` and wrote to one of its own would render the same
      // string into the result and pass every assertion above.
      expect(log.lines.join('\n'), contains('auth failed'));
    });

    test('a bookmark with no path fails the test instead of the app',
        () async {
      // `resolveCredentials` throws `ArgumentError` on that wiring mistake,
      // deliberately, so it cannot be missed. A user-triggered button must
      // still get a red result rather than an unhandled async error — loudly
      // *and* gracefully.
      final result = await runConnectionTest(
        config: config(),
        credentials: () async =>
            throw ArgumentError.value(null, 'identityFilePath', 'missing'),
        authenticate: (_, _, _) async => AuthKind.key,
      );

      expect(result.ok, isFalse);
      expect(result.summary, contains('identityFilePath'));
      // An Error is our bug, so the transcript keeps the trace that locates it.
      expect(result.log, contains('identityFilePath'));
      expect(result.log, contains('runConnectionTest'));
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

    test('a resolver\'s own log ends with the summary exactly once', () async {
      // The summary is appended after the copied lines, where a failure
      // transcript is documented to end — and not again when the resolver's
      // log already closes with it.
      final own = SshConnectionLog()
        ..add('reading the identity file')
        ..add('keyring is locked');
      final result = await runConnectionTest(
        config: config(),
        credentials: () async =>
            throw SshConnectException('keyring is locked', StateError('x'), own),
        authenticate: (_, _, _) async => fail('must not be reached'),
      );
      final lines = result.log.trim().split('\n');
      expect(lines.last, 'keyring is locked');
      expect(lines.where((l) => l == 'keyring is locked').length, 1);
      expect(lines, contains('reading the identity file'));
    });

    test('a log an authenticator attached is kept, not only a resolver\'s',
        () async {
      // The live authenticator writes into the transcript it is handed and
      // attaches that same instance; a double — or a future implementation —
      // that logs into one of its own would otherwise lose that detail, and
      // the merge below only ever ran for the resolver.
      final result = await runConnectionTest(
        config: config(),
        credentials: () async => const SshCredentials.password('pw'),
        authenticate: (_, _, _) async => throw SshConnectException(
          'auth failed',
          StateError('cause'),
          SshConnectionLog()..add('the authenticator\'s own detail'),
        ),
      );

      expect(result.ok, isFalse);
      expect(result.log, contains('the authenticator\'s own detail'));
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

    // One test per branch of the Error-vs-Exception trace policy: as a single
    // sequential test the first failure aborted the rest, so a regression
    // showed one red branch and three unverified ones under a name that said
    // which none of them.
    test('an Error while resolving credentials keeps its stack trace',
        () async {
      // An Error here is our bug, and its message alone rarely says where it
      // came from.
      final bug = await runConnectionTest(
        config: config(),
        credentials: () async => throw StateError('bad state'),
        authenticate: (_, _, _) async => fail('must not be reached'),
      );
      expect(bug.log, contains('runConnectionTest'));
    });

    test('an Exception while resolving credentials stays readable', () async {
      // A locked keyring, an unreadable key file: it already says everything
      // a person can act on, and a stack trace under one is noise in a
      // transcript people read.
      final expected = await runConnectionTest(
        config: config(),
        credentials: () async =>
            throw const FormatException('unreadable identity file'),
        authenticate: (_, _, _) async => fail('must not be reached'),
      );
      expect(expected.log, contains('unreadable identity file'));
      expect(expected.log, isNot(contains('runConnectionTest')));
    });

    test('a bare Exception from authenticate keeps its stack trace', () async {
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
    });

    test('UnsupportedError stays quiet wherever it is thrown', () async {
      // The one Error that stays quiet: the ssh-agent path the backend
      // deliberately does not implement.
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

    test('a resolver failure keeps the transcript it brought', () async {
      // The SSH layer writes into the transcript it is handed, so on that
      // path the exception's log *is* the transcript. A resolver that raised
      // the same type attached a log of its own, and that log was the only
      // place its detail lived — appending the summary alone dropped it.
      final carried = SshConnectionLog()
        ..add('identity file: ~/.ssh/id_ed25519')
        ..add('permission denied reading it');
      final result = await runConnectionTest(
        config: config(),
        credentials: () async => throw SshConnectException(
          'The identity file could not be read',
          const FormatException('bad key'),
          carried,
        ),
        authenticate: (_, _, _) async => fail('must not be reached'),
      );
      expect(result.ok, isFalse);
      expect(result.log, contains('The identity file could not be read'));
      expect(result.log, contains('permission denied reading it'));
    });

    test('an authenticate failure does not repeat its transcript', () async {
      // The other half: the log `authenticate` attaches is the transcript
      // itself, and appending that to itself would double every line.
      final result = await runConnectionTest(
        config: config(),
        credentials: () async => const SshCredentials.password('pw'),
        authenticate: (_, _, transcript) async {
          transcript.add('only once');
          throw SshConnectException(
            'refused',
            const FormatException('no'),
            transcript,
          );
        },
      );
      expect(result.ok, isFalse);
      expect('only once'.allMatches(result.log).length, 1);
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

    test('every auth kind has a distinct, non-empty label', () {
      // Distinct as well as present: two kinds sharing a label would report
      // the wrong thing about how authentication completed, which is the one
      // distinction the summary exists to draw.
      final labels = <String>{};
      for (final kind in AuthKind.values) {
        expect(authKindLabel(kind), isNotEmpty);
        expect(labels.add(authKindLabel(kind)), isTrue,
            reason: 'duplicate label for ${kind.name}');
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

    test('a declined host key is neither trusted nor pinned', () async {
      // Consent is the whole security boundary here, and every other callback
      // in this file answers yes — so an implementation that ignored the
      // decline and pinned anyway passed the suite.
      final inner = InMemoryHostKeyStore();
      final trial = UnpinnedHostKeyStore(inner);
      final manager = SshSessionManager(
        tofu: TofuVerifier(trial),
        onHostKey: (_) async => false,
      );

      expect(
        await manager.verifyHostKey(
          host: 'declined.example.com',
          port: 22,
          type: 'ssh-ed25519',
          fingerprintBytes: fingerprint('declined'),
        ),
        isFalse,
      );
      expect(await trial.get('declined.example.com', 22), isNull);
      expect(await inner.get('declined.example.com', 22), isNull);
    });

    test('an approval during a trial never reaches the real store', () async {
      // The promise the editor makes in copy — "trusted for the test only, the
      // first real connection asks again" — enforced rather than asserted in a
      // comment. `UnpinnedHostKeyStore.put` writes only its own map, and this
      // is what would fail if it ever delegated.
      final persistent = InMemoryHostKeyStore();
      final trial = UnpinnedHostKeyStore(persistent);
      final manager = SshSessionManager(
        tofu: TofuVerifier(trial),
        onHostKey: (_) async => true,
      );

      expect(
        await manager.verifyHostKey(
          host: 'trial.example.com',
          port: 22,
          type: 'ssh-ed25519',
          fingerprintBytes: fingerprint('trial'),
        ),
        isTrue,
      );
      // Approved and usable for the rest of this attempt…
      expect(await trial.get('trial.example.com', 22), isNotNull);
      // …and invisible to the store a real session would consult.
      expect(await persistent.get('trial.example.com', 22), isNull);
      expect(await persistent.all(), isEmpty);
    });

    test('a trial approval satisfies the verifier it is wrapped in', () async {
      final trial = UnpinnedHostKeyStore(InMemoryHostKeyStore());
      final verifier = TofuVerifier(trial);
      // Counted, because a pin is not consent: an implementation that trusted
      // and pinned an unknown key without asking would satisfy every verdict
      // assertion below while skipping the one step this whole design is for.
      var prompts = 0;
      final manager = SshSessionManager(
        tofu: verifier,
        onHostKey: (_) async {
          prompts++;
          return true;
        },
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
      expect(prompts, 1, reason: 'first sight must ask, not silently pin');

      // Second offer of the same key is trusted without another prompt, so a
      // reconnect inside one attempt does not re-ask.
      expect(
        await manager.verifyHostKey(
          host: 'new.example.com',
          port: 22,
          type: 'ssh-ed25519',
          fingerprintBytes: fingerprint('new'),
        ),
        isTrue,
      );
      expect(prompts, 1, reason: 'the pin from this attempt answers for it');

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

      // Through the manager as well, not only the verifier: if
      // `verifyHostKey` consulted the verifier for unknown hosts and short-cut
      // a host it had already pinned, every assertion above still passes and
      // a changed key is silently trusted.
      final reoffered = await manager.verifyHostKey(
        host: 'new.example.com',
        port: 22,
        type: 'ssh-ed25519',
        fingerprintBytes: fingerprint('attacker'),
      );
      // Written as an implication rather than a compound boolean: the
      // compound form also passes when the key was refused *and* the prompt
      // count drifted, and fails with an opaque "Expected: false" that cannot
      // say which of the two happened.
      if (reoffered) {
        expect(prompts, greaterThan(1),
            reason: 'a changed key must be refused or re-asked, never assumed');
        // An approved re-ask pins the key that was approved — in the trial
        // store, and only there. A "yes" that left the old pin standing would
        // re-prompt on every reconnect, or trust the old key while reporting
        // the new one verified.
        expect(
          (await trial.get('new.example.com', 22))?.fingerprintSha256,
          'SHA256:attacker',
          reason: 'an approved re-ask must pin the key that was approved',
        );
      } else {
        // The prompt above always answers yes, so a refusal can only mean
        // the manager never asked — a prompt that was answered and then
        // ignored would be a bug wearing the safe outcome's clothes. And a
        // refused key must not have replaced the approved pin.
        expect(prompts, 1,
            reason: 'a silent refusal must not consume a yes-answered prompt');
        expect(
          (await trial.get('new.example.com', 22))?.fingerprintSha256,
          'SHA256:new',
          reason: 'a refused key must not overwrite the approved pin',
        );
      }
    });

    test('a pin is scoped to the port it was approved on', () async {
      // Every other test here uses port 22, and the app's own sample config
      // targets 2222: a store keyed by host alone would let a pin for one
      // port answer for the other, in either direction, unnoticed.
      final real = InMemoryHostKeyStore();
      await real.put(HostKey(
        host: 'stored.example.com',
        port: 2222,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:known',
        pinnedAt: 1,
      ));
      final trial = UnpinnedHostKeyStore(real);
      // A pin read through from the wrapped store is scoped to its port —
      // the path every trial takes for the pins it already has…
      expect(await trial.get('stored.example.com', 2222), isNotNull);
      expect(await trial.get('stored.example.com', 22), isNull);
      // …and so is one approved during the trial itself.
      await trial.put(HostKey(
        host: 'dual.example.com',
        port: 22,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:known',
        pinnedAt: 2,
      ));
      expect(await trial.get('dual.example.com', 22), isNotNull);
      expect(await trial.get('dual.example.com', 2222), isNull);
    });
  });
}
