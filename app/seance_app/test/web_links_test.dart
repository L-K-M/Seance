import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/web_links.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('opens web links externally', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    expect(await openWebLink(Uri.parse('https://example.com')), isTrue);
    final call = calls.single;
    expect(call.method, 'launch');
    expect(call.arguments['url'], 'https://example.com');
    expect(call.arguments['useSafariVC'], isFalse);
    expect(call.arguments['useWebView'], isFalse);
  });

  test('rejects unsafe links without invoking the platform', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      fail('Unsafe URI reached the platform');
    });

    for (final link in [
      'file:///tmp/secret',
      'javascript:alert(1)',
      'ssh://example.com',
      'https:',
      'https://user:password@example.com',
    ]) {
      expect(await openWebLink(Uri.parse(link)), isFalse, reason: link);
    }
  });

  test('reports launch failures without throwing', () async {
    final uri = Uri.parse('https://example.com');
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(await openWebLink(uri), isFalse);

    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'no_browser');
    });
    expect(await openWebLink(uri), isFalse);
  });
}
