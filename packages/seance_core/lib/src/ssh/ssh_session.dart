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

/// A live SSH shell session wired to a [TerminalEngine].
class SshSession {
  final SSHClient client;
  final SSHSession shell;
  final TerminalEngine engine;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _closed = false;

  SshSession._(this.client, this.shell, this.engine);

  /// Pipe SSH stdout/stderr into the engine and the engine's user input back
  /// into the shell; forward resize events.
  void _wire() {
    _subs.add(shell.stdout.listen(engine.feed));
    _subs.add(shell.stderr.listen(engine.feed));
    _subs.add(engine.userInput.listen((data) {
      if (!_closed) shell.write(Uint8List.fromList(data));
    }));
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
  }) async {
    if (credentials.method == AuthMethod.agent) {
      // dartssh2 has no local ssh-agent auth path; the app must resolve agent
      // keys via a platform bridge and pass them as privateKey credentials.
      throw UnsupportedError(
        'Agent auth is not available through the dartssh2 backend yet; '
        'resolve the key via the platform ssh-agent and connect with a '
        'privateKey credential.',
      );
    }

    final socket = await _connect(config.host, config.port, timeout);

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
    );

    final shell = await client.shell(
      pty: SSHPtyConfig(width: engine.size.cols, height: engine.size.rows),
    );
    final session = SshSession._(client, shell, engine).._wire();
    return session;
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
