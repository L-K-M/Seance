import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:seance_protocol/seance_protocol.dart';

import '../hostkey/tofu.dart';
import '../terminal/terminal_engine.dart';

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

/// Asks the user to approve a host key on first use or after a change. Returns
/// true to trust (and pin) the presented key. The app wires this to a dialog
/// (a plain confirm on first use, a hard "HOST KEY CHANGED" block otherwise).
typedef HostKeyPrompter = Future<bool> Function(HostKeyDecision decision);

/// Answers a keyboard-interactive challenge (e.g. a 2FA/TOTP code). Given the
/// prompts, returns one response per prompt.
typedef KeyboardInteractiveResponder = Future<List<String>> Function(
    List<String> prompts, String name, String instruction);

/// A running transcript of one connection attempt: the human-readable steps we
/// log plus dartssh2's own debug/trace output. The UI shows this so a failed
/// connection explains *what happened* — which auth methods were tried and
/// which the server actually accepts — instead of a bare
/// `SSHAuthFailError(All authentication methods failed)`.
class SshConnectionLog {
  final List<String> lines = [];

  /// Called after every [add] so a live view can repaint.
  final void Function()? onUpdate;

  SshConnectionLog({this.onUpdate});

  void add(String line) {
    lines.add(line);
    onUpdate?.call();
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
  bool _closed = false;

  /// Fired once when the remote shell ends (server-side exit, dropped
  /// connection). Lets the app flip the session's status dot to "disconnected".
  void Function()? onClosed;

  SshSession._(this.client, this.shell, this.engine);

  /// Pipe SSH stdout/stderr into the engine and the engine's user input back
  /// into the shell; forward resize events.
  void _wire() {
    _subs.add(shell.stdout.listen(engine.feed));
    _subs.add(shell.stderr.listen(engine.feed));
    _subs.add(engine.userInput.listen((data) {
      if (!_closed) shell.write(Uint8List.fromList(data));
    }));
    // The remote side closing the channel (logout, kill, network drop) should
    // mark the session disconnected in the UI.
    shell.done.then((_) {
      if (!_closed) onClosed?.call();
    }).catchError((_) {
      if (!_closed) onClosed?.call();
    });
  }

  void resize(TerminalSize size) {
    engine.resize(size);
    shell.resizeTerminal(size.cols, size.rows);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    shell.close();
    client.close();
    await engine.dispose();
  }

  bool get isClosed => _closed || client.isClosed;
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
    if (approved) {
      await tofu.pin(presented);
    }
    return approved;
  }

  Future<SshSession> connect({
    required ServerConfig config,
    required SshCredentials credentials,
    required TerminalEngine engine,
    Duration timeout = const Duration(seconds: 15),
    SshConnectionLog? log,
  }) async {
    void note(String m) => log?.add(m);

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
    note('Connecting to $target …');
    note('Auth method: ${_methodLabel(credentials.method)}');

    SSHSocket socket;
    try {
      socket = await _connect(config.host, config.port, timeout);
    } catch (e) {
      note('Could not open a TCP connection: $e');
      throw SshConnectException(
        'Could not reach ${config.host}:${config.port} — $e',
        e,
        log ?? SshConnectionLog(),
      );
    }
    note('TCP connection established; starting SSH handshake.');

    final identities = credentials.method == AuthMethod.privateKey
        ? SSHKeyPair.fromPem(
            credentials.privateKeyPem ?? '', credentials.keyPassphrase)
        : null;

    final client = SSHClient(
      socket,
      username: config.username,
      onVerifyHostKey: (type, fingerprint) => verifyHostKey(
        host: config.host,
        port: config.port,
        type: type,
        fingerprintBytes: fingerprint,
      ),
      identities: identities,
      onPasswordRequest:
          credentials.method == AuthMethod.password ? () => credentials.password : null,
      onUserInfoRequest: _wrapKeyboardInteractive(),
      // dartssh2's own tracing. Trace lines carry the decisive detail — e.g.
      // `SSH_Message_Userauth_Failure(methodsLeft: [publickey], ...)` tells us
      // exactly which methods the server will accept.
      printDebug: log == null ? null : (m) => log.add('· ${m ?? ''}'),
      printTrace: log == null ? null : (m) => log.add('  ${m ?? ''}'),
    );

    try {
      final shell = await client.shell(
        pty: SSHPtyConfig(width: engine.size.cols, height: engine.size.rows),
      );
      note('Authenticated. Shell session opened.');
      final session = SshSession._(client, shell, engine).._wire();
      return session;
    } catch (e) {
      final summary = _summarizeFailure(e, target, credentials, log);
      note('');
      note(summary);
      client.close();
      throw SshConnectException(summary, e, log ?? SshConnectionLog());
    }
  }

  static String _methodLabel(AuthMethod method) => switch (method) {
        AuthMethod.password => 'password',
        AuthMethod.privateKey => 'public key',
        AuthMethod.agent => 'ssh-agent',
      };

  /// Turn dartssh2's terse errors into an actionable one-liner, mining the
  /// captured trace for the server's accepted-methods list when auth failed.
  static String _summarizeFailure(Object e, String target,
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

  SSHUserInfoRequestHandler? _wrapKeyboardInteractive() {
    final responder = onKeyboardInteractive;
    if (responder == null) return null;
    // Parameter type is inferred from SSHUserInfoRequestHandler so we needn't
    // import dartssh2's (unexported) SSHUserInfoRequest class directly.
    return (request) async {
      final prompts = request.prompts.map((p) => p.promptText).toList();
      return responder(prompts, request.name, request.instruction);
    };
  }
}
