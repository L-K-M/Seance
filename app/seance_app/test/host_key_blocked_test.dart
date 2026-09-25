import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart'
    show SSHAuthAbortError, SSHAuthFailError, SSHHostkeyError;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

const _pinnedKey = 'SHA256:the-key-this-device-pinned';
const _newKey = 'SHA256:a-key-this-device-has-never-seen';

/// What dartssh2 reports when the transport closes on a host-key error: an
/// authentication abort carrying it. It does so for a key its verify
/// callback refused, and for a key-exchange signature that did not verify
/// (RSA and ECDSA host keys), which it checks before the key reaches that
/// callback. `ssh_host_key_refusal_test.dart` in seance_core drives the
/// real exchange; this replays its outcome.
SSHAuthAbortError _hostKeyAbort(String message) => SSHAuthAbortError(
  'Connection closed before authentication',
  SSHHostkeyError(message),
);

/// A session is marked blocked from what its own host-key prompt decided,
/// not from the shape of the error the connection failed with.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  AppState? state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-host-key-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
  });

  tearDown(() async {
    state?.dispose();
    state = null;
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
  });

  final server = ServerConfig(
    id: 'web',
    label: 'web',
    host: 'web.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  Future<void> pin(String fingerprint) => services.tofu.pin(
    HostKey(
      host: server.host,
      port: server.port,
      type: 'ssh-ed25519',
      fingerprintSha256: fingerprint,
      pinnedAt: 0,
    ),
  );

  /// The verdicts the prompt was shown, across every attempt.
  late List<HostKeyVerdict> prompted;

  /// An [AppState] whose handshakes present [presented], or, when it is
  /// null, fail before the key reaches the host-key check. A presented key
  /// goes through the app's own check and prompt exactly where dartssh2
  /// would call it; a refusal then fails as dartssh2 fails it, and an
  /// accepted or trusted key fails with [afterKey]. [answers] are the
  /// prompt's replies in turn; without them the prompt is left unwired.
  AppState stateWith({
    required String? presented,
    Object? afterKey,
    List<bool>? answers,
  }) {
    prompted = [];
    final replies = [...?answers];
    final app = AppState(
      services,
      openSshSession:
          (
            manager, {
            required config,
            required credentials,
            required engine,
            log,
          }) async {
            if (presented == null) {
              throw SshConnectException(
                'SSH error connecting',
                _hostKeyAbort('Signature verification failed'),
                log!,
              );
            }
            final accepted = await manager.verifyHostKey(
              host: config.host,
              port: config.port,
              type: 'ssh-ed25519',
              fingerprintBytes: utf8.encode(presented),
            );
            throw SshConnectException(
              'SSH error connecting',
              accepted
                  ? afterKey!
                  : _hostKeyAbort('Hostkey verification failed'),
              log!,
            );
          },
    );
    if (answers != null) {
      app.hostKeyPrompter = (decision) async {
        prompted.add(decision.verdict);
        return replies.removeAt(0);
      };
    }
    return state = app;
  }

  Future<TerminalSession> open(AppState app) async {
    await app.newTab(server);
    return app.tabs.single as TerminalSession;
  }

  test('a changed key the user declines blocks the server', () async {
    await pin(_pinnedKey);
    final tab = await open(stateWith(presented: _newKey, answers: [false]));

    expect(prompted, [HostKeyVerdict.changed]);
    expect(tab.status, TerminalStatus.error);
    expect(tab.hostKeyBlocked, isTrue);
  });

  test('a changed key the unwired prompt refuses blocks the server', () async {
    await pin(_pinnedKey);
    final tab = await open(stateWith(presented: _newKey));

    expect(tab.status, TerminalStatus.error);
    expect(tab.hostKeyBlocked, isTrue);
  });

  test('a first-use key the user declines is an ordinary failure', () async {
    final tab = await open(stateWith(presented: _newKey, answers: [false]));

    expect(prompted, [HostKeyVerdict.firstUse]);
    expect(tab.status, TerminalStatus.error);
    expect(tab.hostKeyBlocked, isFalse);
  });

  test('a changed key the user accepts, on a connection that then fails, '
      'is an ordinary failure', () async {
    await pin(_pinnedKey);
    final tab = await open(
      stateWith(
        presented: _newKey,
        afterKey: SSHAuthFailError('All authentication methods failed'),
        answers: [true],
      ),
    );

    expect(prompted, [HostKeyVerdict.changed]);
    expect(tab.status, TerminalStatus.error);
    expect(tab.hostKeyBlocked, isFalse);
    expect(
      (await services.tofu.store.get(
        server.host,
        server.port,
      ))?.fingerprintSha256,
      _newKey,
      reason: 'accepting re-pins, so the next attempt meets a trusted key',
    );
  });

  group('a host-key error on the pinned, unchanged key', () {
    test('is an ordinary failure when the key was trusted', () async {
      await pin(_pinnedKey);
      final tab = await open(
        stateWith(
          presented: _pinnedKey,
          afterKey: _hostKeyAbort('Signature verification failed'),
          answers: [],
        ),
      );

      expect(prompted, isEmpty, reason: 'a trusted key is never prompted');
      expect(tab.status, TerminalStatus.error);
      expect(tab.error, 'SSH error connecting');
      expect(tab.hostKeyBlocked, isFalse);
    });

    test('is an ordinary failure when the signature failed before the key '
        'was checked', () async {
      await pin(_pinnedKey);
      final tab = await open(stateWith(presented: null, answers: []));

      expect(prompted, isEmpty);
      expect(tab.status, TerminalStatus.error);
      expect(tab.error, 'SSH error connecting');
      expect(tab.hostKeyBlocked, isFalse);
    });
  });

  test('a reconnect is decided by its own prompt', () async {
    await pin(_pinnedKey);
    final app = stateWith(
      presented: _newKey,
      afterKey: SSHAuthFailError('All authentication methods failed'),
      answers: [false, true],
    );
    final declined = await open(app);
    expect(declined.hostKeyBlocked, isTrue);

    await app.reconnect(declined.id);
    final retried = app.tabs.single as TerminalSession;
    expect(prompted, [HostKeyVerdict.changed, HostKeyVerdict.changed]);
    expect(retried, isNot(same(declined)));
    expect(retried.status, TerminalStatus.error);
    expect(retried.hostKeyBlocked, isFalse);
  });
}
