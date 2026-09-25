import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/ui/app_menus.dart';
import 'package:seance_app/ui/server_list_density.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The Dart half of the native macOS menu (MainFlutterWindow.swift): what
/// its items do when they call in, and what Dart tells it back. The native
/// half has no test host on Linux; the channel is the contract between
/// them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    await services?.probe.dispose();
    messenger
      ..setMockMethodCallHandler(_pathChannel, null)
      ..setMockMethodCallHandler(macMenuChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    state = null;
    services = null;
    directory = null;
  });

  Future<void> boot(WidgetTester tester) => tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('seance-mac-menu-');
    messenger.setMockMethodCallHandler(
      _pathChannel,
      (call) async => directory!.path,
    );
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services!);
  });

  /// A call as the native menu item makes it.
  Future<void> fromNative(WidgetTester tester, String method) =>
      tester.runAsync(
        () => messenger.handlePlatformMessage(
          macMenuChannel.name,
          macMenuChannel.codec.encodeMethodCall(MethodCall(method)),
          (_) {},
        ),
      );

  testWidgets('View ▸ the density item flips the density, and its title '
      'always names the other choice', (tester) async {
    await boot(tester);
    final sent = <MethodCall>[];
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async {
      sent.add(call);
      return null;
    });

    installMacMenu(state!);
    // Titled before the menu can be opened: comfortable is the default.
    expect(sent, [
      isMethodCall(
        'setServerListDensityTitle',
        arguments: 'Use Compact Sidebar Rows',
      ),
    ]);

    await fromNative(tester, 'toggleServerListDensity');
    expect(state!.serverListDensity, ServerListDensity.compact);
    expect(
      services!.settings.serverListDensity,
      ServerListDensity.compact,
      reason: 'the menu persists the choice like the switches do',
    );
    expect(
      sent.last,
      isMethodCall(
        'setServerListDensityTitle',
        arguments: 'Use Comfortable Sidebar Rows',
      ),
    );

    // A switch elsewhere retitles it too; anything else the state says
    // does not.
    await tester.runAsync(
      () => state!.setServerListDensity(ServerListDensity.comfortable),
    );
    expect(
      sent.last,
      isMethodCall(
        'setServerListDensityTitle',
        arguments: 'Use Compact Sidebar Rows',
      ),
    );
    final count = sent.length;
    state!.notifyListeners();
    expect(sent, hasLength(count));
  });
}
