import 'package:seance_protocol/seance_protocol.dart';

import '../hostkey/tofu.dart';
import 'ssh_session.dart';

/// What a trial connection needs from the SSH layer: authenticate against
/// [config], say how it completed, and leave nothing open.
///
/// Deliberately narrower than [openAuthenticatedClient], whose caller owns the
/// returned client. A trial wants no channel at all, so the seam a test stands
/// in for is one future and one enum rather than a live client somebody has to
/// remember to close.
///
/// One contract on failures: write the summary into the log only when
/// throwing an [SshConnectException]. [runConnectionTest] takes that
/// exception's own message verbatim and appends a summary itself for anything
/// else, so an implementation that logs a line and then throws something else
/// puts the same sentence in the transcript twice.
typedef HostAuthenticator =
    Future<AuthKind> Function(
      ServerConfig config,
      SshCredentials credentials,
      SshConnectionLog log,
    );

/// A [HostAuthenticator] over the real transport.
///
/// On failure it leaves the socket to [openAuthenticatedClient], which closes
/// the client before every throw that can happen after it is constructed (the
/// only ones are inside the `client.authenticated` try, which calls `close`
/// first). Keep that true: a settings form invites repeated clicks, so a leak
/// here is a leak per click.
///
/// Takes the [hostKeys] store rather than a [TofuVerifier] so it can wrap it
/// in an [UnpinnedHostKeyStore] itself. A verifier parameter would let a
/// caller hand over the app's persistent one in a single line and silently
/// turn every trial approval into permanent trust — the exact thing the
/// unpinned store exists to prevent. Here that is not expressible.
///
/// [timeout] bounds the TCP connect only — dartssh2's authentication wait is a
/// fixed five minutes inside [openAuthenticatedClient], which is deliberate
/// there (it leaves room for host-key approval and slow keyboard-interactive
/// replies) and applies here for the same reason: the trial shows the same
/// dialogs a real connection does.
HostAuthenticator liveHostAuthenticator({
  required HostKeyStore hostKeys,
  required HostKeyPrompter onHostKey,
  KeyboardInteractiveResponder? onKeyboardInteractive,
  Duration timeout = const Duration(seconds: 15),
}) {
  return (config, credentials, log) async {
    // Built per attempt, not once per authenticator: a shared trial store
    // would carry an approval from one attempt into the next, and "pinned for
    // the attempt only" is the whole reason this wrapper exists.
    final tofu = TofuVerifier(UnpinnedHostKeyStore(hostKeys));
    final (client, kind) = await openAuthenticatedClient(
      config: config,
      credentials: credentials,
      tofu: tofu,
      onHostKey: onHostKey,
      onKeyboardInteractive: onKeyboardInteractive,
      timeout: timeout,
      log: log,
    );
    // On success the client is ours to close (there is no SshSession here to
    // own it); on failure openAuthenticatedClient has already closed it.
    try {
      await client.close();
    } catch (error) {
      // Authentication has already succeeded by here, and that is the only
      // thing this reports: a socket that misbehaves on the way down must not
      // come back as "could not connect" for a server that just did. It still
      // earns a transcript line — "authenticated, but the connection feels
      // flaky" is undiagnosable if the one clue is dropped here.
      log.add('Closing the trial connection failed: $error');
    }
    return kind;
  };
}

/// What a trial connection found: one line for the user, the caveats that line
/// would otherwise overstate, and the transcript behind both.
class ConnectionTestResult {
  final bool ok;

  /// One user-facing sentence. On failure this is the same summary a real
  /// failed connection shows, so the two never disagree about the same host.
  final String summary;

  /// Things true of the trial but not of the summary — a jump host that was
  /// not used, for instance. Empty is the common case.
  final List<String> notes;

  /// The full handshake transcript.
  ///
  /// A failure that happens *before* the handshake — a locked keyring, an
  /// unreadable identity file — has its summary appended here by
  /// [runConnectionTest], since nothing else has written anything. One that
  /// happens during it already ends with the summary, because the SSH layer
  /// writes that line before it throws.
  final String log;

  const ConnectionTestResult({
    required this.ok,
    required this.summary,
    required this.log,
    this.notes = const [],
  });
}

/// Authenticate against [config] without opening a shell, and report it.
///
/// [credentials] is a callback rather than a value because resolving them can
/// itself fail in ways the user needs to read — a locked keyring, an identity
/// file the sandbox will not open — and those failures belong in the same
/// result as a refused password rather than as an exception the caller has to
/// classify a second time.
Future<ConnectionTestResult> runConnectionTest({
  required ServerConfig config,
  required Future<SshCredentials> Function() credentials,
  required HostAuthenticator authenticate,
  SshConnectionLog? log,
}) async {
  final transcript = log ?? SshConnectionLog();
  // Read-only: the same instance flows into all three results, and a caller
  // that sorted or filtered it in place would be editing a result it was
  // handed rather than a list of its own.
  final notes = List<String>.unmodifiable(<String>[
    if (config.jumpHostId != null)
      'This server is configured to tunnel through a jump host, which Séance '
          // Present tense on purpose: this note rides every result,
          // including the failures it exists to explain, and "connected"
          // would assert a connection next to "could not reach the host".
          'does not execute yet — this test goes straight to the host.',
  ]);
  var authenticating = false;
  try {
    final resolved = await credentials();
    authenticating = true;
    final kind = await authenticate(config, resolved, transcript);
    return ConnectionTestResult(
      ok: true,
      summary:
          'Authenticated as ${config.username}@${config.host}:${config.port} '
          '(${authKindLabel(kind)}).',
      notes: notes,
      log: transcript.toString(),
    );
  } on SshConnectException catch (e) {
    // Its own summary, verbatim: it already knows which of "unreachable",
    // "wrong key", "PermitRootLogin prohibit-password" applies, and a second
    // wording here would be a second thing to keep true.
    //
    // The SSH layer writes that summary into the transcript before throwing,
    // which is why nothing is appended here — but only `authenticate` goes
    // through it. A `credentials()` that raises this same type has logged
    // nothing, and the transcript would end mid-sentence.
    if (!authenticating) {
      transcript.add(e.message);
      // A resolver that raised this type may have written its own detail
      // into the log it attached — the only place that detail lives, since
      // nothing here saw it happen. Skipped when it is the transcript
      // already in hand, which is what `authenticate` always attaches.
      if (!identical(e.log, transcript)) {
        for (final line in e.log.lines) {
          transcript.add(line);
        }
      }
    }
    return ConnectionTestResult(
      ok: false,
      summary: e.message,
      notes: notes,
      log: transcript.toString(),
    );
  } catch (error, stackTrace) {
    final summary = error is UnsupportedError
        // "Unsupported operation: …" reads as a crash. The message alone is
        // the sentence the SSH layer wrote for a person to read — this is the
        // ssh-agent path, which the backend does not implement yet.
        ? (error.message?.toString() ?? '$error')
        : '$error';
    // The failure has not written itself into the transcript on the path that
    // reaches here first — resolving credentials — so an expanded log would
    // otherwise stop mid-sentence.
    transcript.add(summary);
    // An `Error` is a bug rather than a fact about the host, and its message
    // alone rarely says where it came from. `Exception`s raised while
    // resolving credentials — a locked keyring, an unreadable identity file —
    // already say everything a person can act on, and a stack trace under one
    // is noise in a transcript people read.
    //
    // Past that point the calculus flips. `openAuthenticatedClient` wraps
    // every failure it can name in `SshConnectException` — the key that will
    // not load, the socket that will not open, everything `client.
    // authenticated` throws — and that is caught above. So a bare `Exception`
    // arriving from `authenticate` is one nothing was written to expect,
    // which is exactly when the trace is the only thing that locates it.
    //
    // `UnsupportedError` stays out either way: it is an Error, but a known
    // and deliberate one (the ssh-agent path the backend does not implement).
    if (error is! UnsupportedError && (error is Error || authenticating)) {
      transcript.add('$stackTrace');
    }
    return ConnectionTestResult(
      ok: false,
      summary: summary,
      notes: notes,
      log: transcript.toString(),
    );
  }
}

/// How authentication completed, in the words the editor shows.
String authKindLabel(AuthKind kind) => switch (kind) {
  AuthKind.key => 'public key',
  AuthKind.storedPassword => 'stored password',
  AuthKind.keyboardInteractive => 'keyboard-interactive',
  AuthKind.promptedPassword => 'password',
};

/// A [HostKeyStore] that reads through to [inner] but keeps its pins to
/// itself.
///
/// Testing a connection must not be the one place in Séance where
/// trust-on-first-use is granted without connecting. The user is still asked —
/// a changed key still gets its hard block — but approving it from a form that
/// may never be saved, for a host the draft may still be renamed away from,
/// only lasts as long as the attempt. The first real connection asks once more
/// and pins for real.
class UnpinnedHostKeyStore implements HostKeyStore {
  final HostKeyStore inner;
  final Map<String, HostKey> _trial = {};

  UnpinnedHostKeyStore(this.inner);

  @override
  Future<HostKey?> get(String host, int port) async =>
      _trial[hostKeyLocator(host, port)] ?? await inner.get(host, port);

  /// Pinned keys and trial approvals together, as one view.
  ///
  /// Consistent with [get], which answers from the trial first — a store
  /// whose listing disagreed with its lookups would be a stranger thing to
  /// hand a verifier. What that means for a caller is that this is never a
  /// persistence source: a trial approval must not outlive the attempt, and
  /// this wrapper is only ever built inside one ([liveHostAuthenticator]),
  /// so nothing that syncs or exports a store can reach it.
  @override
  Future<List<HostKey>> all() async {
    // Merged by locator rather than concatenated, so a host that is both
    // pinned and re-approved in a trial appears once — and appears as the
    // trial's version, which is the precedence [get] already establishes.
    final byLocator = <String, HostKey>{
      for (final key in await inner.all()) key.locator: key,
      ..._trial,
    };
    return byLocator.values.toList();
  }

  @override
  Future<void> put(HostKey key) async => _trial[key.locator] = key;
}
