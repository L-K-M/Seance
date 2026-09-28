import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/secure_master_key.dart';
import 'package:seance_app/services/snippet_source_cache.dart';
import 'package:seance_app/services/snippet_source_refresher.dart';
import 'package:seance_app/ui/snippets_pane.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _url = 'https://example.com/team/snippets/raw/branch/main/snippets.json';
const _token = 'tok-3f9a1c';

String _file(List<(String, String, String)> snippets) => jsonEncode({
  'version': 1,
  'snippets': [
    for (final (id, title, body) in snippets)
      {'id': id, 'title': title, 'body': body},
  ],
});

/// A fetcher over a fake server that records what it was asked.
class _Server {
  final requests = <http.Request>[];
  http.Response Function(http.Request request) respond = (_) =>
      http.Response(_file([('disk', 'Disk usage', 'du -sh {{path}}')]), 200);

  SnippetSourceFetcher fetcher() => SnippetSourceFetcher(
    client: MockClient((request) async {
      requests.add(request);
      return respond(request);
    }),
  );
}

SnippetSource _source({
  String id = 'team',
  String url = _url,
  String? tokenRef,
}) => SnippetSource(
  id: id,
  name: 'Team',
  url: url,
  tokenRef: tokenRef,
  createdAt: 1,
  updatedAt: 1,
);

/// Wait, on the real clock, for [done]: cache writes are real file I/O.
Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 200; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Server server;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-sources-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    server = _Server();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  group('SnippetSourceRefresher', () {
    late SnippetSourceCache cache;
    late Map<String, String> tokens;
    Object? tokenError;

    setUp(() {
      cache = SnippetSourceCache(File('${directory.path}/cache.json'));
      tokens = {};
      tokenError = null;
    });

    SnippetSourceRefresher refresher() => SnippetSourceRefresher(
      cache: cache,
      fetcher: server.fetcher,
      readToken: (ref) async {
        if (tokenError != null) throw tokenError!;
        return tokens[ref];
      },
      onChanged: () {},
    );

    test('a fetch is shown and survives a restart for offline use', () async {
      final r = refresher()..updateSources([_source()], fetchNew: false);
      await r.refresh('team');

      final state = r.stateOf(_source())!;
      expect(state.snippets.single.title, 'Disk usage');
      expect(state.fetchedAt, isNotNull);
      expect(state.error, isNull);

      final restarted = refresher();
      await restarted.load();
      restarted.updateSources([_source()], fetchNew: false);
      expect(restarted.stateOf(_source())!.snippets.single.id, 'disk');
      expect(server.requests, hasLength(1), reason: 'no fetch on restart');
    });

    test('a failed refresh keeps the last good copy and says why', () async {
      final r = refresher()..updateSources([_source()], fetchNew: false);
      await r.refresh('team');
      server.respond = (_) => http.Response('', 500);
      await r.refresh('team');

      final state = r.stateOf(_source())!;
      expect(state.snippets.single.id, 'disk');
      expect(state.error, 'The server answered HTTP 500.');
      expect(state.errorAt, isNotNull);
    });

    test('a malformed file is reported, not adopted', () async {
      server.respond = (_) =>
          http.Response(jsonEncode({'version': 2, 'snippets': []}), 200);
      final r = refresher()..updateSources([_source()], fetchNew: false);
      await r.refresh('team');

      final state = r.stateOf(_source())!;
      expect(state.snippets, isEmpty);
      expect(state.fetchedAt, isNull);
      expect(state.error, contains('Unsupported format version 2'));
    });

    test('sends the stored token, and only for a source naming one', () async {
      tokens['ref-1'] = _token;
      final r = refresher()
        ..updateSources([
          _source(tokenRef: 'ref-1'),
          _source(id: 'open', url: 'https://example.org/s.json'),
        ], fetchNew: false);
      await r.refreshAll();

      final byHost = {for (final q in server.requests) q.url.host: q};
      expect(byHost['example.com']!.headers['Authorization'], 'Bearer $_token');
      expect(byHost['example.org']!.headers, isNot(contains('Authorization')));
    });

    test('a token this device lacks fails without a request', () async {
      final r = refresher()
        ..updateSources([_source(tokenRef: 'ref-1')], fetchNew: false);
      await r.refresh('team');

      expect(server.requests, isEmpty);
      expect(
        r.stateOf(_source(tokenRef: 'ref-1'))!.error,
        contains('not stored on this device'),
      );
    });

    test('a locked vault is reported as such', () async {
      tokenError = const VaultLockedException();
      final r = refresher()
        ..updateSources([_source(tokenRef: 'ref-1')], fetchNew: false);
      await r.refresh('team');

      expect(server.requests, isEmpty);
      expect(
        r.stateOf(_source(tokenRef: 'ref-1'))!.error,
        contains('vault is locked'),
      );
    });

    test('a copy from another URL is not the source\'s copy', () async {
      final r = refresher()..updateSources([_source()], fetchNew: false);
      await r.refresh('team');

      final moved = _source(url: 'https://example.com/other.json');
      r.updateSources([moved], fetchNew: false);
      expect(r.stateOf(moved), isNull);
    });

    test('new sources are fetched, removed ones forgotten', () async {
      final r = refresher()..updateSources([_source()]);
      await _until(() async => !r.anyRefreshing);
      expect(server.requests, hasLength(1));
      expect(r.stateOf(_source()), isNotNull);
      expect(await cache.load(), contains('team'));

      r.updateSources([]);
      expect(r.stateOf(_source()), isNull);
      // The pruned cache is written in the background.
      await _until(() async => (await cache.load()).isEmpty);
    });

    test('a source removed mid-fetch keeps no result', () async {
      final r = refresher()..updateSources([_source()], fetchNew: false);
      final pending = r.refresh('team');
      r.updateSources([], fetchNew: false);
      await pending;

      r.updateSources([_source()], fetchNew: false);
      expect(r.stateOf(_source()), isNull);
    });

    test('a refresh asked for mid-fetch runs again afterwards', () async {
      final r = refresher()..updateSources([_source()], fetchNew: false);
      final first = r.refresh('team');
      final second = r.refresh('team');
      expect(r.isRefreshing('team'), isTrue);
      await Future.wait([first, second]);
      expect(server.requests, hasLength(2));
      expect(r.isRefreshing('team'), isFalse);
    });
  });

  group('AppState snippet sources', () {
    late AppServices services;
    late AppState state;

    setUp(() async {
      services = await AppServices.initialize();
      services.snippetSourceFetcher = server.fetcher();
      state = AppState(services);
    });

    tearDown(() async {
      state.dispose();
      await services.probe.dispose();
    });

    Future<void> settle() =>
        _until(() async => !state.snippetSourceRefresher.anyRefreshing);

    test(
      'the token goes to the vault and never into the source file',
      () async {
        await state.saveSnippetSource(name: 'Team', url: _url, token: _token);
        await settle();

        final source = state.snippetSources.single;
        final ref = source.tokenRef!;
        expect((await services.vault.getSecret(ref))!.value, _token);
        final onDisk = await File(
          '${directory.path}/snippet_sources.json',
        ).readAsString();
        expect(onDisk, isNot(contains(_token)));
        final vaultFile = await File(
          '${directory.path}/vault.json',
        ).readAsString();
        expect(vaultFile, isNot(contains(_token)), reason: 'sealed');

        expect(
          server.requests.single.headers['Authorization'],
          'Bearer $_token',
        );
        expect(
          state.snippetSourceRefresher.stateOf(source)!.snippets.single.id,
          'disk',
        );
      },
    );

    test('a blank token keeps the stored one; removing drops it', () async {
      await state.saveSnippetSource(name: 'Team', url: _url, token: _token);
      final id = state.snippetSources.single.id;
      final ref = state.snippetSources.single.tokenRef!;

      await state.saveSnippetSource(id: id, name: 'Renamed', url: _url);
      expect(state.snippetSources.single.name, 'Renamed');
      expect(state.snippetSources.single.tokenRef, ref);
      expect((await services.vault.getSecret(ref))!.value, _token);

      await state.saveSnippetSource(
        id: id,
        name: 'Renamed',
        url: _url,
        removeToken: true,
      );
      expect(state.snippetSources.single.tokenRef, isNull);
      expect(await services.vault.getSecret(ref), isNull);
      await settle();
    });

    test('an invalid URL is refused before anything is written', () async {
      await expectLater(
        state.saveSnippetSource(
          name: 'Team',
          url: 'http://example.com/s.json',
          token: _token,
        ),
        throwsA(isA<SnippetSourceException>()),
      );
      expect(await services.snippetSourceStore.listSources(), isEmpty);
    });

    test('deleting a source leaves a tombstone and drops its token', () async {
      await state.saveSnippetSource(name: 'Team', url: _url, token: _token);
      await settle();
      final source = state.snippetSources.single;

      await state.deleteSnippetSource(source.id);

      expect(state.snippetSources, isEmpty);
      expect(await services.vault.getSecret(source.tokenRef!), isNull);
      final pending = await services.tombstoneStore.all();
      expect(pending.single.id, 'snippetsource:${source.id}');
      expect(pending.single.deleted, isTrue);
      expect(state.snippetSourceRefresher.stateOf(source), isNull);
    });
  });

  group('A source naming a server credential', () {
    late AppServices services;
    late AppState state;
    const password = 'ssh-password';

    setUp(() async {
      services = await AppServices.initialize();
      services.snippetSourceFetcher = server.fetcher();
      state = AppState(services);
      await services.vault.putLocalSecret(
        const Secret(
          id: 'server-pw',
          kind: SecretKind.password,
          value: password,
        ),
        updatedAt: 1,
      );
      await state.saveServer(
        const ServerConfig(
          id: 's1',
          label: 'box',
          host: 'box.example.com',
          username: 'deploy',
          secretRef: 'server-pw',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      // As a peer could sync it: a source whose token is that credential.
      await services.snippetSourceStore.putSource(
        _source(tokenRef: 'server-pw'),
      );
      state.snippetSources = await services.snippetSourceStore.listSources();
      state.snippetSourceRefresher.updateSources(
        state.snippetSources,
        fetchNew: false,
      );
    });

    tearDown(() async {
      state.dispose();
      await services.probe.dispose();
    });

    test('never sends it', () async {
      await state.snippetSourceRefresher.refresh('team');

      expect(server.requests, isEmpty);
      expect(
        state.snippetSourceRefresher
            .stateOf(state.snippetSources.single)!
            .error,
        contains('names a server credential'),
      );
    });

    test('cannot overwrite it or delete it', () async {
      await state.saveSnippetSource(
        id: 'team',
        name: 'Team',
        url: _url,
        token: _token,
      );
      expect(state.snippetSources.single.tokenRef, isNot('server-pw'));
      expect((await services.vault.getSecret('server-pw'))!.value, password);

      await services.snippetSourceStore.putSource(
        _source(tokenRef: 'server-pw'),
      );
      await state.deleteSnippetSource('team');
      expect((await services.vault.getSecret('server-pw'))!.value, password);
      await _until(() async => !state.snippetSourceRefresher.anyRefreshing);
    });
  });

  group('Snippets tab', () {
    testWidgets('lists remote snippets read-only under their source', (
      tester,
    ) async {
      late AppServices services;
      late AppState state;
      await tester.runAsync(() async {
        services = await AppServices.initialize();
        services.snippetSourceFetcher = server.fetcher();
        state = AppState(services);
        await state.saveSnippetSource(name: 'Team', url: _url);
        await state.snippetSourceRefresher.refresh(
          state.snippetSources.single.id,
        );
        await state.saveSnippet(
          const Snippet(
            id: 'local',
            title: 'Local one',
            body: 'uptime',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
      });
      addTearDown(() async {
        state.dispose();
        await tester.runAsync(() => services.probe.dispose());
      });

      await tester.pumpWidget(
        AppScope(
          state: state,
          child: const MaterialApp(home: Scaffold(body: SnippetsPane())),
        ),
      );
      await tester.pump();

      expect(find.text('Team'), findsOneWidget);
      expect(find.textContaining('1 snippet'), findsOneWidget);
      expect(find.text('Disk usage'), findsOneWidget);
      expect(find.byTooltip('From Team (read-only)'), findsOneWidget);
      // The local snippet keeps its edit menu; the remote one has none.
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      expect(find.byTooltip('Refresh Team'), findsOneWidget);

      // Inserting goes through the local snippets' path, which refuses
      // without a connected session.
      await tester.tap(find.text('Disk usage'));
      await tester.pump();
      expect(find.text('Open a connected session first.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('shows why a source failed', (tester) async {
      late AppServices services;
      late AppState state;
      server.respond = (_) => http.Response('', 404);
      await tester.runAsync(() async {
        services = await AppServices.initialize();
        services.snippetSourceFetcher = server.fetcher();
        state = AppState(services);
        await state.saveSnippetSource(name: 'Team', url: _url);
        await state.snippetSourceRefresher.refresh(
          state.snippetSources.single.id,
        );
      });
      addTearDown(() async {
        state.dispose();
        await tester.runAsync(() => services.probe.dispose());
      });

      await tester.pumpWidget(
        AppScope(
          state: state,
          child: const MaterialApp(home: Scaffold(body: SnippetsPane())),
        ),
      );
      await tester.pump();

      expect(find.text('Not fetched yet.'), findsOneWidget);
      expect(find.textContaining('Not found (HTTP 404)'), findsOneWidget);
    });
  });
}
