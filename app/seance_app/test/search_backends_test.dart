import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Which backends a configuration actually builds.
///
/// Declined once as needing a keystore seam that did not exist — it does:
/// `FlutterSecureStorage.setMockInitialValues` is what the other
/// `AppServices.initialize` suites already use, and it reaches the key
/// branches as well as the URL one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-search-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
  });

  tearDown(() async {
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  test('nothing configured is nothing to search', () async {
    // Null is what hides the search tool from the assistant, so it is not the
    // same answer as an empty CompositeSearch.
    expect(await services.buildSearchProvider(), isNull);
  });

  test('a URL that is only whitespace builds no backend', () async {
    // The settings screen writes trimmed-or-null, but `settings.json` is a
    // file on disk and the field also arrives over sync. Untrimmed, this
    // built a SearXNG backend whose every request fails, and the only sign
    // was the failure log one layer into a search.
    services.settings.searxngUrl = '   ';
    expect(await services.buildSearchProvider(), isNull);
  });

  test('a key reference of only whitespace builds no backend', () async {
    // Same exposure as the URL above — a hand-edited `settings.json` or a
    // synced one — and untrimmed it reads as configured, misses its lookup,
    // and is reported as a locked keyring rather than a bad reference.
    services.settings.zaiApiKeyRef = '   ';
    services.settings.braveApiKeyRef = '  ';
    expect(await services.buildSearchProvider(), isNull);
  });

  test('one backend is used directly, not wrapped', () async {
    services.settings.searxngUrl = 'https://searx.example.com';
    expect(await services.buildSearchProvider(), isA<SearxngSearch>());
  });

  test('a URL with spaces around it is still a backend', () async {
    // The complement of the whitespace case: trimming must not turn a padded
    // URL into no backend at all.
    services.settings.searxngUrl = '  https://searx.example.com  ';
    final provider = await services.buildSearchProvider();
    expect((provider as SearxngSearch).baseUrl, 'https://searx.example.com');
  });

  test('every configured backend is used, not the first one found', () async {
    // Configured means used: a priority chain would quietly ignore a second
    // key someone took the trouble to enter.
    services.settings.searxngUrl = 'https://searx.example.com';
    services.settings.braveApiKeyRef = 'brave';
    services.settings.zaiApiKeyRef = 'zai';
    await services.masterKeys.putApiKey('brave', 'sk-brave');
    await services.masterKeys.putApiKey('zai', 'sk-zai');

    final provider = await services.buildSearchProvider();
    expect(
      (provider as CompositeSearch).providers.map((p) => p.runtimeType),
      [SearxngSearch, BraveSearch, ZaiSearch],
    );
  });

  test('a reference whose key is gone skips that backend, not the search',
      () async {
    // A locked keyring reads as "this backend is unavailable", and the ones
    // that need no key still answer.
    services.settings.searxngUrl = 'https://searx.example.com';
    services.settings.braveApiKeyRef = 'brave';
    services.settings.zaiApiKeyRef = 'zai';
    await services.masterKeys.putApiKey('zai', 'sk-zai');

    final provider = await services.buildSearchProvider();
    expect(
      (provider as CompositeSearch).providers.map((p) => p.runtimeType),
      [SearxngSearch, ZaiSearch],
    );
  });

  test('a key reference on its own is enough', () async {
    // No URL at all: the Z.AI-only configuration this feature added, which
    // must not depend on a SearXNG instance being configured beside it.
    services.settings.zaiApiKeyRef = 'zai';
    await services.masterKeys.putApiKey('zai', 'sk-zai');
    expect(await services.buildSearchProvider(), isA<ZaiSearch>());
  });
}
