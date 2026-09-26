import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/macos_titlebar.dart';

class _FakeTitlebar implements MacosTitlebarAdapter {
  _FakeTitlebar({this.failInstall = false});

  final bool failInstall;
  int installs = 0;
  int resets = 0;

  @override
  Future<void> install() async {
    installs++;
    if (failInstall) throw PlatformException(code: 'NO_WINDOW');
  }

  @override
  Future<void> reset() async => resets++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/seance-window');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Delivers a runner-to-Dart call on [channel], as the Swift side would.
  Future<ByteData?> fromRunner(MethodCall call) {
    final completer = messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(call),
      (_) {},
    );
    return completer.then((_) => null);
  }

  group('install', () {
    test('an installed titlebar reports its band', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => true);
      final adapter = _FakeTitlebar();
      final band = await MacosTitlebar.install(
        adapter: adapter,
        channel: channel,
      );
      addTearDown(() => band?.dispose());
      expect(adapter.installs, 1);
      expect(adapter.resets, 0);
      expect(band, isNotNull);
      expect(band!.value, isTrue);
    });

    test(
      'a window restored into full screen starts without the band',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'isToolbarBandVisible');
          return false;
        });
        final band = await MacosTitlebar.install(
          adapter: _FakeTitlebar(),
          channel: channel,
        );
        addTearDown(() => band?.dispose());
        expect(band!.value, isFalse);
      },
    );

    test('a failed install puts the standard titlebar back', () async {
      final adapter = _FakeTitlebar(failInstall: true);
      final band = await MacosTitlebar.install(
        adapter: adapter,
        channel: channel,
      );
      // No band: nothing in the app reserves one or draws the header.
      expect(band, isNull);
      expect(adapter.resets, 1);
    });
  });

  group('band channel', () {
    test('follows the runner across full screen', () async {
      final band = MacosToolbarBandChannel(channel: channel);
      addTearDown(band.dispose);
      expect(band.value, isTrue);

      await fromRunner(const MethodCall('toolbarBandChanged', false));
      expect(band.value, isFalse);
      await fromRunner(const MethodCall('toolbarBandChanged', true));
      expect(band.value, isTrue);
    });

    test('no runner side keeps the windowed layout', () async {
      final band = MacosToolbarBandChannel(channel: channel);
      addTearDown(band.dispose);
      await band.start();
      expect(band.value, isTrue);
    });

    test('a malformed report changes nothing', () async {
      final band = MacosToolbarBandChannel(channel: channel);
      addTearDown(band.dispose);
      await fromRunner(const MethodCall('toolbarBandChanged', 'no'));
      expect(band.value, isTrue);
    });

    test('dispose detaches the handler', () async {
      final band = MacosToolbarBandChannel(channel: channel);
      band.dispose();
      await fromRunner(const MethodCall('toolbarBandChanged', false));
      expect(band.value, isTrue);
    });
  });
}
