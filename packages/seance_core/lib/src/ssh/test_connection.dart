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
typedef HostAuthenticator =
    Future<AuthKind> Function(
      ServerConfig config,
      SshCredentials credentials,
      SshConnectionLog log,
    );

/// A [HostAuthenticator] over the real transport.
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
    } catch (_) {
      // Authentication has already succeeded by here, and that is the only
      // thing this reports. A socket that misbehaves on the way down must not
      // come back as "could not connect" for a server that just did.
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
  final notes = <String>[
    if (config.jumpHostId != null)
      'This server is configured to tunnel through a jump host, which Séance '
          'does not execute yet — the test connected straight to the host.',
  ];
  try {
    final kind = await authenticate(config, await credentials(), transcript);
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
    // Nothing has written the failure into the transcript on this path (only
    // openAuthenticatedClient does that, and we never reached it), so an
    // expanded log would otherwise stop mid-sentence.
    transcript.add(summary);
    // An `Error` here is a bug rather than a fact about the host, and its
    // message alone rarely says where it came from. `Exception`s — a locked
    // keyring, an unreadable identity file — already say everything a person
    // can act on, and a stack trace under one is noise in a transcript people
    // read. `UnsupportedError` is an Error but a known, deliberate one.
    if (error is Error && error is! UnsupportedError) {
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
