import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Another tab for a server dials the server as it is now, not as it was
/// when the tab it was opened from connected.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  AppState? state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-new-tab-');
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

  ServerConfig server({required String host, int port = 22}) => ServerConfig(
    id: 'web',
    label: 'web',
    host: host,
    port: port,
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  /// An [AppState] whose handshakes record the endpoint they were asked to
  /// dial into [dialed], then fail, so no real connection is attempted.
  AppState stateRecording(List<String> dialed) => state = AppState(
    services,
    openSshSession:
        (
          manager, {
          required config,
          required credentials,
          required engine,
          log,
        }) async {
          dialed.add('${config.host}:${config.port}');
          throw SshConnectException(
            'SSH error connecting',
            const SocketException('refused'),
            log!,
          );
        },
  );

  test('a new tab opened from an existing one uses the edited config', () async {
    final dialed = <String>[];
    final app = stateRecording(dialed);
    app.servers = [server(host: 'old.example.com')];
    await app.newTab(app.servers.single);
    final first = app.tabs.single as TerminalSession;

    // The user edits the server while its tab stays open.
    app.servers = [server(host: 'new.example.com', port: 2222)];

    // ⌘T, the tab strip's "+" and the macOS New Tab item all pass the
    // config the existing tab connected with.
    await app.newTab(first.config);

    expect(dialed, ['old.example.com:22', 'new.example.com:2222']);
    expect(
      (app.tabs.last as TerminalSession).config.host,
      'new.example.com',
    );
  });

  test('a server no longer in the list still opens with its tab config', () async {
    final dialed = <String>[];
    final app = stateRecording(dialed);
    await app.newTab(server(host: 'solo.example.com'));
    await app.newTab((app.tabs.single as TerminalSession).config);

    expect(dialed, ['solo.example.com:22', 'solo.example.com:22']);
  });
}
