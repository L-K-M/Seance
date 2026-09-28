import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'sync_coordinator_test.dart' show FakeServer;

const _token = 'tok-3f9a1c';

SnippetSource _source({
  String id = 'team',
  String name = 'Team snippets',
  String? tokenRef = 'snippet-token-1',
  int updatedAt = 10,
}) => SnippetSource(
  id: id,
  name: name,
  url: 'https://example.com/team/snippets.json',
  tokenRef: tokenRef,
  createdAt: 1,
  updatedAt: updatedAt,
);

/// One device: its source store, its vault, and a coordinator over them.
class _Device {
  _Device(this.id, this.key, {this.syncSecrets = true});

  final String id;
  final List<int> key;
  final bool syncSecrets;
  final sources = InMemorySnippetSourceStore();
  final tombstones = InMemoryTombstoneStore();
  late final vault = SecretVault(InMemoryVaultStore(), key);

  SyncCoordinator coordinator([LocalRecordStore? local]) => SyncCoordinator(
    configStore: InMemoryConfigStore(),
    hostKeyStore: InMemoryHostKeyStore(),
    snippetSourceStore: sources,
    codec: RecordCodec(key),
    local: local ?? InMemoryLocalRecordStore(),
    deviceId: id,
    syncSecrets: syncSecrets,
    secretVault: syncSecrets ? vault : null,
    tombstoneStore: tombstones,
  );

  Future<void> run(SyncApi api) => coordinator().run(api);
}

void main() {
  late FakeServer api;
  late List<int> key;
  setUp(() {
    api = FakeServer();
    key = secureRandomBytes(32);
  });

  test('a source and its token reach a second device', () async {
    final a = _Device('A', key);
    final b = _Device('B', key);
    await a.sources.putSource(_source());
    await a.vault.putLocalSecret(
      const Secret(
        id: 'snippet-token-1',
        kind: SecretKind.password,
        value: _token,
      ),
      updatedAt: 10,
    );

    await a.run(api);
    await b.run(api);

    final onB = (await b.sources.listSources()).single;
    expect(onB.toJson(), _source().toJson());
    expect((await b.vault.getSecret('snippet-token-1'))!.value, _token);
  });

  test('the token stays behind when credential sync is off', () async {
    final a = _Device('A', key, syncSecrets: false);
    final b = _Device('B', key);
    await a.sources.putSource(_source());
    await a.vault.putLocalSecret(
      const Secret(
        id: 'snippet-token-1',
        kind: SecretKind.password,
        value: _token,
      ),
      updatedAt: 10,
    );

    await a.run(api);
    await b.run(api);

    expect(api.stored('snippetsource:team'), isNotNull);
    expect(api.stored('secret:snippet-token-1'), isNull);
    expect(await b.sources.getSource('team'), isNotNull);
    expect(await b.vault.getSecret('snippet-token-1'), isNull);
  });

  test(
    'the source record is sealed: its payload never holds the token',
    () async {
      final a = _Device('A', key);
      await a.sources.putSource(_source());
      await a.vault.putLocalSecret(
        const Secret(
          id: 'snippet-token-1',
          kind: SecretKind.password,
          value: _token,
        ),
        updatedAt: 10,
      );
      final local = InMemoryLocalRecordStore();
      await a.coordinator(local).collectLocal();

      final record = await RecordCodec(
        key,
      ).decrypt((await local.getRecord('snippetsource:team'))!);
      expect(record.kind, RecordKind.snippetSource);
      expect(record.data.toString(), isNot(contains(_token)));
      expect(record.data['tokenRef'], 'snippet-token-1');
    },
  );

  test('an edit on one device wins on the other', () async {
    final a = _Device('A', key);
    final b = _Device('B', key);
    await a.sources.putSource(_source(tokenRef: null));
    await a.run(api);
    await b.run(api);

    await b.sources.putSource(
      _source(name: 'Renamed', tokenRef: null, updatedAt: 20),
    );
    await b.run(api);
    await a.run(api);

    expect((await a.sources.getSource('team'))!.name, 'Renamed');
  });

  test('a deleted source is removed on the other device', () async {
    final a = _Device('A', key);
    final b = _Device('B', key);
    await a.sources.putSource(_source(tokenRef: null));
    await a.run(api);
    await b.run(api);
    expect(await b.sources.getSource('team'), isNotNull);

    await a.sources.deleteSource('team');
    await a.tombstones.add(
      EncryptedRecord.tombstone(
        id: 'snippetsource:team',
        updatedAt: 20,
        deviceId: 'A',
      ),
    );
    await a.run(api);
    await b.run(api);

    expect(await b.sources.getSource('team'), isNull);
  });

  test('a record whose id disagrees with its payload is skipped', () async {
    final b = _Device('B', key);
    final current = _source(name: 'Current', tokenRef: null, updatedAt: 20);
    await b.sources.putSource(current);
    final local = InMemoryLocalRecordStore();
    await local.putRemote(
      await RecordCodec(key).encrypt(
        DecryptedRecord(
          id: 'snippetsource:other',
          kind: RecordKind.snippetSource,
          updatedAt: 30,
          deviceId: 'A',
          data: _source(name: 'Hijacked', tokenRef: null).toJson(),
        ),
      ),
    );

    await b.coordinator(local).applyToStores();

    expect((await b.sources.getSource('team'))!.toJson(), current.toJson());
    expect(await b.sources.getSource('other'), isNull);
  });

  test('a source naming a server credential cannot publish it', () async {
    final a = _Device('A', key);
    final configs = InMemoryConfigStore();
    await configs.putServer(
      ServerConfig(
        id: 's1',
        label: 'box',
        host: 'box.example.com',
        username: 'u',
        secretRef: 'server-pw',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await a.vault.putLocalSecret(
      const Secret(id: 'server-pw', kind: SecretKind.password, value: 'pw'),
      updatedAt: 10,
    );
    await a.sources.putSource(_source(tokenRef: 'server-pw'));
    final local = InMemoryLocalRecordStore();
    await SyncCoordinator(
      configStore: configs,
      hostKeyStore: InMemoryHostKeyStore(),
      snippetSourceStore: a.sources,
      codec: RecordCodec(key),
      local: local,
      deviceId: 'A',
      syncSecrets: true,
      secretVault: a.vault,
    ).collectLocal();

    expect(await local.getRecord('snippetsource:team'), isNotNull);
    expect(
      await local.getRecord('secret:server-pw'),
      isNull,
      reason: 'the server has not opted its credential into sync',
    );
  });

  test('a device without a source store leaves source records alone', () async {
    final a = _Device('A', key);
    await a.sources.putSource(_source(tokenRef: null));
    await a.run(api);

    final older = SyncCoordinator(
      configStore: InMemoryConfigStore(),
      hostKeyStore: InMemoryHostKeyStore(),
      codec: RecordCodec(key),
      local: InMemoryLocalRecordStore(),
      deviceId: 'old',
    );
    await older.run(api);

    expect(api.stored('snippetsource:team')!.deleted, isFalse);
  });
}
