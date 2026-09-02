import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:meta/meta.dart';
import 'package:seance_protocol/seance_protocol.dart';

import '../hostkey/tofu.dart';
import '../terminal/terminal_engine.dart';
import 'remote_file_system.dart';
import 'sequential_cleanup.dart';

const _cleanupActionTimeout = Duration(seconds: 5);

Future<void> _discardCleanup(CleanupAction action) => runSequentialCleanup(
      [action],
      actionTimeout: _cleanupActionTimeout,
      failureMode: CleanupFailureMode.ignore,
    );

/// Resolved credentials for one connection. The vault produces these just
/// before connect; nothing here is persisted.
class SshCredentials {
  final AuthMethod method;
  final String? password;
  final String? privateKeyPem;
  final String? keyPassphrase;

  const SshCredentials.password(this.password)
      : method = AuthMethod.password,
        privateKeyPem = null,
        keyPassphrase = null;

  const SshCredentials.privateKey(this.privateKeyPem, {this.keyPassphrase})
      : method = AuthMethod.privateKey,
        password = null;

  const SshCredentials.agent()
      : method = AuthMethod.agent,
        password = null,
        privateKeyPem = null,
        keyPassphrase = null;
}

/// How an authenticated SSH client completed user authentication.
enum AuthKind { key, storedPassword, keyboardInteractive, promptedPassword }

/// Asks the user to approve a host key on first use or after a change. Returns
/// true to trust (and pin) the presented key. The app wires this to a dialog
/// (a plain confirm on first use, a hard "HOST KEY CHANGED" block otherwise).
typedef HostKeyPrompter = Future<bool> Function(HostKeyDecision decision);

/// Answers a keyboard-interactive challenge (e.g. a 2FA/TOTP code). Given the
/// prompts, returns one response per prompt.
typedef KeyboardInteractiveResponder = Future<List<String>> Function(
    List<String> prompts, String name, String instruction);

Future<bool> _verifyHostKey({
  required TofuVerifier tofu,
  required HostKeyPrompter onHostKey,
  required String host,
  required int port,
  required String type,
  required Uint8List fingerprintBytes,
}) async {
  final presented = HostKey(
    host: host,
    port: port,
    type: type,
    fingerprintSha256: utf8.decode(fingerprintBytes),
    pinnedAt: DateTime.now().millisecondsSinceEpoch,
  );
  final decision = await tofu.check(presented);
  if (decision.isTrusted) return true;

  // First use or changed key: the user must explicitly approve.
  final approved = await onHostKey(decision);
  if (approved) await tofu.pin(presented);
  return approved;
}

/// A running transcript of one connection attempt: the human-readable steps we
/// log plus dartssh2's own debug/trace output. The UI shows this so a failed
/// connection explains *what happened* — which auth methods were tried and
/// which the server actually accepts — instead of a bare
/// `SSHAuthFailError(All authentication methods failed)`.
class SshConnectionLog {
  final List<String> lines = [];

  /// Called after every [add] so a live view can repaint. Cleared by [freeze].
  void Function()? onUpdate;

  bool _frozen = false;

  /// Bound the transcript: dartssh2's `printTrace` fires per packet, so an
  /// unfrozen log on a busy session would grow without limit.
  static const int _maxLines = 400;

  SshConnectionLog({this.onUpdate});

  void add(String line) {
    if (_frozen) return;
    lines.add(line);
    if (lines.length > _maxLines) {
      lines.removeRange(0, lines.length - _maxLines);
    }
    onUpdate?.call();
  }

  /// Stop recording and notifying. Call this once a connection is established:
  /// the log only exists to diagnose connection *failures* (which happen during
  /// connect), but dartssh2 keeps calling `printTrace` for the whole session —
  /// left live, every packet would fire [onUpdate] (rebuilding the app) and
  /// append a line forever. A failed attempt never freezes, so its full
  /// transcript is preserved for the error view.
  void freeze() {
    _frozen = true;
    onUpdate = null;
  }

  @override
  String toString() => lines.join('\n');
}

/// Thrown when a connection attempt fails. [message] is a one-line,
/// user-facing summary; [log] carries the full transcript for a details view;
/// [cause] is the original error.
class SshConnectException implements Exception {
  final String message;
  final Object cause;
  final SshConnectionLog log;

  SshConnectException(this.message, this.cause, this.log);

  @override
  String toString() => message;
}

/// A live SSH shell session wired to a [TerminalEngine].
class SshSession {
  final SSHClient client;
  final SSHSession shell;
  final TerminalEngine engine;
  final List<StreamSubscription<dynamic>> _subs = [];
  final Completer<void> _stdoutDone = Completer<void>();
  final Completer<void> _stderrDone = Completer<void>();
  final SingleFlightCleanup _cleanup = SingleFlightCleanup();
  bool _closed = false;
  SftpClient? _sftpClient;
  Future<RemoteFileSystem>? _remoteFileSystem;
  bool _endedRemotely = false;
  bool _closedNotified = false;
  void Function()? _onClosed;

  /// Fired once when the remote shell ends (server-side exit, dropped
  /// connection). Lets the app flip the session's status dot to "disconnected".
  set onClosed(void Function()? callback) {
    _onClosed = callback;
    if (_endedRemotely && callback != null) scheduleMicrotask(_notifyClosed);
  }

  void Function()? get onClosed => _onClosed;

  SshSession._(this.client, this.shell, this.engine);

  /// Pipe SSH stdout/stderr into the engine and the engine's user input back
  /// into the shell; forward resize events.
  void _wire() {
    _subs.add(
      shell.stdout.listen(
        engine.feed,
        onDone: () => _complete(_stdoutDone),
        onError: (_) => _complete(_stdoutDone),
      ),
    );
    _subs.add(
      shell.stderr.listen(
        engine.feed,
        onDone: () => _complete(_stderrDone),
        onError: (_) => _complete(_stderrDone),
      ),
    );
    _subs.add(
      engine.userInput.listen((data) {
        if (!_closed) shell.write(Uint8List.fromList(data));
      }),
    );
    // The remote side closing the channel (logout, kill, network drop) should
    // mark the session disconnected in the UI.
    shell.done.then((_) => _remoteClosed()).catchError((_) => _remoteClosed());
  }

  /// Opens one SFTP subsystem beside this session's shell and reuses it for the
  /// life of the authenticated transport.
  Future<RemoteFileSystem> openRemoteFileSystem({
    Duration timeout = const Duration(seconds: 15),
  }) {
    if (_closed || client.isClosed) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'open SFTP',
        message: 'The SSH session is disconnected.',
      );
    }
    return _remoteFileSystem ??= _openRemoteFileSystem(timeout);
  }

  Future<RemoteFileSystem> _openRemoteFileSystem(Duration timeout) async {
    SftpClient? opening;
    try {
      opening = await client.sftp().timeout(timeout);
      final sftp = opening;
      await sftp.handshake.timeout(timeout);
      if (_closed || client.isClosed) {
        throw const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'open SFTP',
          message: 'The SSH session disconnected while SFTP was opening.',
        );
      }
      _sftpClient = sftp;
      return DartSshRemoteFileSystem(sftp);
    } on RemoteFileException {
      _remoteFileSystem = null;
      if (opening != null) await _discardCleanup(opening.close);
      rethrow;
    } catch (e) {
      _remoteFileSystem = null;
      if (opening != null) await _discardCleanup(opening.close);
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'open SFTP',
        message: 'Could not open SFTP on this server: $e',
        cause: e,
      );
    }
  }

  void resize(TerminalSize size) {
    engine.resize(size);
    shell.resizeTerminal(size.cols, size.rows);
  }

  Future<void> _remoteClosed() async {
    if (_closed) return;
    _endedRemotely = true;
    // dartssh2 can complete SSHSession.done before the final stdout/stderr
    // packets have drained. Give those streams a short window before teardown.
    try {
      await Future.wait([
        _stdoutDone.future,
        _stderrDone.future,
      ]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // A dropped transport may never deliver stream-done; teardown must still
      // complete and mark the session disconnected.
    }
    try {
      await _finish();
    } catch (_) {
      // A remote drop has no caller to receive teardown failures.
    } finally {
      _notifyClosed();
    }
  }

  static void _complete(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }

  void _notifyClosed() {
    if (_closedNotified) return;
    final callback = _onClosed;
    if (callback == null) return;
    _closedNotified = true;
    callback();
  }

  Future<void> close() => _finish();

  Future<void> _finish() => _cleanup.run(_finishOnce);

  Future<void> _finishOnce() async {
    _closed = true;
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subs);
    final sftpClient = _sftpClient;
    _subs.clear();
    _sftpClient = null;
    _remoteFileSystem = null;

    await runSequentialCleanup(
      [
        for (final subscription in subscriptions) subscription.cancel,
        if (sftpClient != null) sftpClient.close,
        shell.close,
        client.close,
        engine.dispose,
      ],
      actionTimeout: _cleanupActionTimeout,
    );
  }

  bool get isClosed => _closed || client.isClosed;
}

SSHUserInfoRequestHandler? _keyboardInteractiveHandler(
    KeyboardInteractiveResponder? responder,
    void Function(AuthKind kind) onAuthKind) {
  if (responder == null) return null;
  // Parameter type is inferred from SSHUserInfoRequestHandler so we needn't
  // import dartssh2's (unexported) SSHUserInfoRequest class directly.
  return (request) async {
    final prompts = request.prompts.map((p) => p.promptText).toList();
    final promptedPassword = prompts.any(
        (prompt) => prompt.toLowerCase().contains('password'));
    onAuthKind(promptedPassword
        ? AuthKind.promptedPassword
        : AuthKind.keyboardInteractive);
    return responder(prompts, request.name, request.instruction);
  };
}

/// Opens and authenticates an SSH transport without opening a shell channel.
/// The returned client can open SFTP or other channels directly.
Future<(SSHClient, AuthKind)> openAuthenticatedClient({
  required ServerConfig config,
  required SshCredentials credentials,
  required TofuVerifier tofu,
  required HostKeyPrompter onHostKey,
  KeyboardInteractiveResponder? onKeyboardInteractive,
  Future<SSHSocket> Function(String, int, Duration)? connect,
  Duration timeout = const Duration(seconds: 15),
  SshConnectionLog? log,
}) async {
  void note(String message) => log?.add(message);

  if (credentials.method == AuthMethod.agent) {
    // dartssh2 has no local ssh-agent auth path; the app must resolve agent
    // keys via a platform bridge and pass them as privateKey credentials.
    throw UnsupportedError(
      'Agent auth is not available through the dartssh2 backend yet; '
      'resolve the key via the platform ssh-agent and connect with a '
      'privateKey credential.',
    );
  }

  final target = '${config.username}@${config.host}:${config.port}';
  note('Auth method: ${SshSessionManager._methodLabel(credentials.method)}');

  List<SSHKeyPair>? identities;
  if (credentials.method == AuthMethod.privateKey) {
    try {
      identities = SSHKeyPair.fromPem(
          credentials.privateKeyPem ?? '', credentials.keyPassphrase);
    } catch (e) {
      note('Could not load the private key: $e');
      final hint = credentials.keyPassphrase == null
          ? ' (is it passphrase-protected? add the passphrase to this server)'
          : ' (wrong key passphrase?)';
      throw SshConnectException(
        'Could not load the private key for $target — $e$hint',
        e,
        log ?? SshConnectionLog(),
      );
    }
    if (identities.isEmpty) {
      note('The configured identity contained no usable key.');
    }
    // Record offered fingerprints so rejected keys can be diagnosed.
    for (final kp in identities) {
      note('Offering key: ${kp.name} '
          '${SshSessionManager._fingerprint(kp.toPublicKey().encode())}');
    }
  }

  final socketConnector = connect ??
      ((host, port, socketTimeout) =>
          SSHSocket.connect(host, port, timeout: socketTimeout));
  SSHSocket socket;
  try {
    note('Connecting to $target …');
    socket = await socketConnector(config.host, config.port, timeout);
  } catch (e) {
    note('Could not open a TCP connection: $e');
    throw SshConnectException(
      'Could not reach ${config.host}:${config.port} — $e',
      e,
      log ?? SshConnectionLog(),
    );
  }
  note('TCP connection established; starting SSH handshake.');

  var authKind = credentials.method == AuthMethod.privateKey
      ? AuthKind.key
      : AuthKind.storedPassword;
  final client = SSHClient(
    socket,
    username: config.username,
    onVerifyHostKey: (type, fingerprint) => _verifyHostKey(
      tofu: tofu,
      onHostKey: onHostKey,
      host: config.host,
      port: config.port,
      type: type,
      fingerprintBytes: fingerprint,
    ),
    identities: identities,
    onPasswordRequest: credentials.method == AuthMethod.password
        ? () {
            authKind = AuthKind.storedPassword;
            return credentials.password;
          }
        : null,
    onUserInfoRequest: _keyboardInteractiveHandler(
      onKeyboardInteractive,
      (kind) => authKind = kind,
    ),
    // dartssh2's trace carries the server's accepted-methods detail.
    printDebug: log == null ? null : (m) => log.add('· ${m ?? ''}'),
    printTrace: log == null ? null : (m) => log.add('  ${m ?? ''}'),
  );

  try {
    await client.authenticated;
    note('Authenticated.');
    return (client, authKind);
  } catch (e) {
    final summary = SshSessionManager._summarizeFailure(
        e, config, target, credentials, log);
    note('');
    note(summary);
    await _discardCleanup(client.close);
    throw SshConnectException(summary, e, log ?? SshConnectionLog());
  }
}

/// Opens SSH connections for [ServerConfig]s, enforcing trust-on-first-use host
/// key verification and wiring the byte streams to a terminal engine.
class SshSessionManager {
  final TofuVerifier tofu;
  final HostKeyPrompter onHostKey;
  final KeyboardInteractiveResponder? onKeyboardInteractive;

  /// Injectable connector, so tests can substitute a fake transport. Defaults
  /// to a real TCP socket.
  final Future<SSHSocket> Function(String host, int port, Duration timeout)
      _connect;

  SshSessionManager({
    required this.tofu,
    required this.onHostKey,
    this.onKeyboardInteractive,
    Future<SSHSocket> Function(String host, int port, Duration timeout)?
        connect,
  }) : _connect = connect ??
            ((host, port, timeout) =>
                SSHSocket.connect(host, port, timeout: timeout));

  /// The host-key callback dartssh2 invokes. Extracted as a public method so it
  /// can be unit-tested without a live connection. dartssh2 hands us the key
  /// [type] and the `SHA256:…` fingerprint bytes.
  Future<bool> verifyHostKey({
    required String host,
    required int port,
    required String type,
    required Uint8List fingerprintBytes,
  }) async {
    return _verifyHostKey(
      tofu: tofu,
      onHostKey: onHostKey,
      host: host,
      port: port,
      type: type,
      fingerprintBytes: fingerprintBytes,
    );
  }

  /// What running [script] at a prompt looks like on the wire: its bytes
  /// (edges trimmed) plus one Enter, i.e. exactly the keystrokes of the user
  /// having typed it themselves. Throws for blank input — there is nothing to
  /// type.
  ///
  /// Written into the interactive shell rather than executed on a separate
  /// channel, so `cd`, aliases, and `tmux attach` affect *this* session and
  /// the script's output lands in scrollback. No wait-for-prompt handshake
  /// precedes it: a PTY buffers input until the remote shell reads, so a
  /// script sent during login banner/init simply runs once the prompt is up.
  @visibleForTesting
  static Uint8List loginScriptKeystrokes(String script) {
    final normalized = normalizeLoginScript(script);
    if (normalized == null) {
      throw ArgumentError.value(script, 'script', 'must be non-blank');
    }
    return utf8.encode('$normalized\n');
  }

  /// The keystrokes [config]'s optional login script contributes, or null when
  /// there is nothing to run. The seam between "does this config want a login
  /// script" and the live shell, so both halves are testable without an SSH
  /// handshake (see [loginScriptKeystrokes]).
  @visibleForTesting
  static Uint8List? loginScriptKeystrokesFor(ServerConfig config) =>
      normalizeLoginScript(config.loginScript) == null
          ? null
          : loginScriptKeystrokes(config.loginScript!);

  /// Send [config]'s optional login script into the freshly opened [shell].
  void _runLoginScript(
      SSHSession shell, ServerConfig config, void Function(String) note) {
    final keystrokes = loginScriptKeystrokesFor(config);
    if (keystrokes == null) return;
    note('Running login script.');
    try {
      shell.write(keystrokes);
    } catch (_) {
      // Best-effort by design: the channel died between open and write. The
      // session teardown reports that fault; letting it escape here would
      // resurface as a connect failure for a session that authenticated fine.
    }
  }

  Future<SshSession> connect({
    required ServerConfig config,
    required SshCredentials credentials,
    required TerminalEngine engine,
    Duration timeout = const Duration(seconds: 15),
    SshConnectionLog? log,
  }) async {
    final (client, _) = await openAuthenticatedClient(
      config: config,
      credentials: credentials,
      tofu: tofu,
      onHostKey: onHostKey,
      onKeyboardInteractive: onKeyboardInteractive,
      connect: _connect,
      timeout: timeout,
      log: log,
    );
    final target = '${config.username}@${config.host}:${config.port}';
    void note(String message) => log?.add(message);
    void removeAuthenticatedNote() {
      final lines = log?.lines;
      if (lines == null) return;
      final index = lines.lastIndexOf('Authenticated.');
      if (index >= 0) lines.removeAt(index);
    }

    try {
      final shell = await client.shell(
        pty: SSHPtyConfig(width: engine.size.cols, height: engine.size.rows),
      );
      // Keep connect()'s historical single success line after shell setup.
      removeAuthenticatedNote();
      note('Authenticated. Shell session opened.');
      final session = SshSession._(client, shell, engine).._wire();
      // After _wire(), so the script's echo and output are captured by the
      // engine from its very first bytes.
      _runLoginScript(shell, config, note);
      return session;
    } catch (e) {
      removeAuthenticatedNote();
      final summary = _summarizeFailure(e, config, target, credentials, log);
      note('');
      note(summary);
      await _discardCleanup(client.close);
      throw SshConnectException(summary, e, log ?? SshConnectionLog());
    }
  }

  static String _methodLabel(AuthMethod method) => switch (method) {
        AuthMethod.password => 'password',
        AuthMethod.privateKey => 'public key',
        AuthMethod.agent => 'ssh-agent',
      };

  /// Test seam for [_summarizeFailure], which is otherwise reachable only via a
  /// live handshake.
  @visibleForTesting
  static String summarizeFailureForTest(Object e, ServerConfig config,
          SshCredentials credentials, SshConnectionLog log) =>
      _summarizeFailure(e, config,
          '${config.username}@${config.host}:${config.port}', credentials, log);

  /// Turn dartssh2's terse errors into an actionable one-liner, mining the
  /// captured trace for the server's accepted-methods list when auth failed.
  static String _summarizeFailure(Object e, ServerConfig config, String target,
      SshCredentials credentials, SshConnectionLog? log) {
    if (e is SSHAuthFailError) {
      final accepted = _acceptedMethodsFromLog(log);
      final tried = _methodLabel(credentials.method);
      final buffer = StringBuffer(
          'Authentication failed for $target (tried $tried).');
      if (accepted != null && accepted.isNotEmpty) {
        buffer.write(' The server accepts: ${accepted.join(', ')}.');
        if (!accepted.contains(_sshMethodName(credentials.method))) {
          buffer.write(
              ' Switch this server to a method the host allows.');
        } else if (credentials.method == AuthMethod.privateKey) {
          // The key was presented (publickey is accepted) but the server said
          // no: almost always the key isn't in the target user's
          // authorized_keys, or a different key than expected was configured.
          final key = _offeredKeyFromLog(log);
          buffer.write(' The key Séance offered'
              '${key != null ? ' ($key)' : ''} was rejected. Add its public '
              "half to ${config.username}@${config.host}'s "
              '~/.ssh/authorized_keys, or configure the key that host already '
              'trusts.');
        } else if (config.username == 'root') {
          // The host advertises password but rejected it for root: on stock
          // Debian/Ubuntu this is PermitRootLogin prohibit-password, which
          // blocks password login for root even with the correct password.
          buffer.write(' The host advertises password auth but rejected it for '
              'root — many servers set PermitRootLogin prohibit-password, which '
              'blocks password login for root. Use a key, or log in as a '
              'non-root user and escalate.');
        } else {
          buffer.write(' Check the credential (wrong password or key).');
        }
      } else {
        buffer.write(' Check the username, password, or key.');
      }
      return buffer.toString();
    }
    if (e is SSHError) {
      return 'SSH error connecting to $target: $e';
    }
    return 'Failed to connect to $target: $e';
  }

  /// dartssh2's SSH-protocol name for our credential's method.
  static String _sshMethodName(AuthMethod method) => switch (method) {
        AuthMethod.password => 'password',
        AuthMethod.privateKey => 'publickey',
        AuthMethod.agent => 'publickey',
      };

  /// The OpenSSH-style SHA256 fingerprint of a public-key blob (matches
  /// `ssh-keygen -lf`), so a user can eyeball it against `authorized_keys`.
  static String _fingerprint(List<int> keyBlob) =>
      'SHA256:${base64.encode(sha256.convert(keyBlob).bytes).replaceAll('=', '')}';

  /// Recover the "Offering key: …" line we logged, so the failure summary can
  /// name the exact key the server rejected.
  static String? _offeredKeyFromLog(SshConnectionLog? log) {
    if (log == null) return null;
    const marker = 'Offering key: ';
    for (final line in log.lines.reversed) {
      final i = line.indexOf(marker);
      if (i >= 0) return line.substring(i + marker.length).trim();
    }
    return null;
  }

  /// Scan the trace for the last `methodsLeft: [ … ]` the server sent.
  static List<String>? _acceptedMethodsFromLog(SshConnectionLog? log) {
    if (log == null) return null;
    final re = RegExp(r'methodsLeft: \[([^\]]*)\]');
    String? last;
    for (final line in log.lines) {
      final m = re.firstMatch(line);
      if (m != null) last = m.group(1);
    }
    if (last == null) return null;
    return last
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

}
