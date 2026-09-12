import 'dart:convert';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// In-memory stand-in for the server (same as sync_test's), reused here.
class FakeServer implements SyncApi {
  final Map<String, EncryptedRecord> _store = {};
  int _seq = 0;
  int pushedRecords = 0;
  int pulls = 0;

  /// The record the server holds under [id], exactly as it was pushed.
  EncryptedRecord? stored(String id) => _store[id];

  /// The last sequence number handed out. Growth across otherwise idle rounds
  /// is what a record that re-writes itself every time looks like.
  int get latestSeq => _seq;

  @override
  Future<PullResponse> pull({required int since}) async {
    pulls++;
    final records = _store.values.where((r) => (r.seq ?? 0) > since).toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return PullResponse(records: records, latestSeq: _seq);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    pushedRecords += records.length;
    final results = <PushResult>[];
    for (final incoming in records) {
      final existing = _store[incoming.id];
      final wins = existing == null ||
          identical(Lww.resolve(existing, incoming), incoming);
      if (wins) {
        final assigned = incoming.withSeq(++_seq);
        _store[incoming.id] = assigned;
        results.add(
            PushResult(id: incoming.id, seq: assigned.seq!, accepted: true));
      } else {
        results.add(PushResult(
            id: incoming.id, seq: existing.seq ?? 0, accepted: false));
      }
    }
    return PushResponse(results: results, latestSeq: _seq);
  }
}

ServerConfig server(String id, String label, int updatedAt) => ServerConfig(
      id: id,
      label: label,
      host: '$label.example.com',
      username: 'u',
      createdAt: 1,
      updatedAt: updatedAt,
    );

void main() {
  test('server configs and host keys sync between two devices', () async {
    final server0 = FakeServer();
    final vaultKey = secureRandomBytes(32); // shared across the two devices
    final codec = RecordCodec(vaultKey);

    // Device A
    final cfgA = InMemoryConfigStore();
    final hkA = InMemoryHostKeyStore();
    await cfgA.putServer(server('s1', 'alpha', 10));
    await hkA.put(HostKey(
        host: 'alpha.example.com',
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:aaa',
        pinnedAt: 5));
    final coordA = SyncCoordinator(
      configStore: cfgA,
      hostKeyStore: hkA,
      codec: codec,
      local: InMemoryLocalRecordStore(),
      deviceId: 'A',
    );

    // Device B
    final cfgB = InMemoryConfigStore();
    final hkB = InMemoryHostKeyStore();
    await cfgB.putServer(server('s2', 'beta', 10));
    final coordB = SyncCoordinator(
      configStore: cfgB,
      hostKeyStore: hkB,
      codec: codec,
      local: InMemoryLocalRecordStore(),
      deviceId: 'B',
    );

    await coordA.run(server0);
    await coordB.run(server0);
    await coordA.run(server0); // A pulls beta

    expect((await cfgA.listServers()).map((s) => s.id).toSet(), {'s1', 's2'});
    expect((await cfgB.listServers()).map((s) => s.id).toSet(), {'s1', 's2'});
    // Host key pinned on A shows up on B.
    expect(await hkB.get('alpha.example.com', 22), isNotNull);
  });

  test('an edit on one device wins by last-write-wins on the other', () async {
    final srv = FakeServer();
    final codec = RecordCodec(secureRandomBytes(32));

    final cfgA = InMemoryConfigStore();
    final cfgB = InMemoryConfigStore();
    await cfgA.putServer(server('s1', 'name-v1', 10));

    SyncCoordinator coord(ConfigStore c, String dev) => SyncCoordinator(
        configStore: c,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: InMemoryLocalRecordStore(),
        deviceId: dev);

    await coord(cfgA, 'A').run(srv);
    await coord(cfgB, 'B').run(srv); // B gets name-v1

    // B renames it later.
    final onB = (await cfgB.getServer('s1'))!;
    await cfgB.putServer(onB.copyWith(label: 'name-v2', updatedAt: 50));

    await coord(cfgB, 'B').run(srv);
    await coord(cfgA, 'A').run(srv); // A pulls the rename

    expect((await cfgA.getServer('s1'))!.label, 'name-v2');
  });

  test('a server\'s group, colour and icon travel with it', () async {
    final srv = FakeServer();
    final codec = RecordCodec(secureRandomBytes(32));

    final cfgA = InMemoryConfigStore();
    final cfgB = InMemoryConfigStore();
    await cfgA.putServer(server('s1', 'alpha', 10).copyWith(
      group: 'Production',
      color: ServerColor.red,
      icon: ServerIcon.rocket,
      updatedAt: 10,
    ));

    SyncCoordinator coord(ConfigStore c, String dev) => SyncCoordinator(
        configStore: c,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: InMemoryLocalRecordStore(),
        deviceId: dev);

    await coord(cfgA, 'A').run(srv);
    await coord(cfgB, 'B').run(srv);

    final onB = (await cfgB.getServer('s1'))!;
    expect(onB.group, 'Production');
    expect(onB.color, ServerColor.red);
    expect(onB.icon, ServerIcon.rocket);

    // Regrouping is an ordinary edit, so it converges the same way a rename
    // does — the point being that a group is a name the member carries, with
    // no separate record that could be left behind.
    await cfgB.putServer(onB.copyWith(group: 'Staging', updatedAt: 50));
    await coord(cfgB, 'B').run(srv);
    await coord(cfgA, 'A').run(srv);

    expect((await cfgA.getServer('s1'))!.group, 'Staging');
  });

  test('a server\'s login script travels with it, and clearing it converges',
      () async {
    final srv = FakeServer();
    final codec = RecordCodec(secureRandomBytes(32));

    final cfgA = InMemoryConfigStore();
    final cfgB = InMemoryConfigStore();
    await cfgA.putServer(server('s1', 'alpha', 10).copyWith(
      loginScript: 'cd /srv/app\ntail -f app.log',
      updatedAt: 10,
    ));

    SyncCoordinator coord(ConfigStore c, String dev) => SyncCoordinator(
        configStore: c,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: InMemoryLocalRecordStore(),
        deviceId: dev);

    await coord(cfgA, 'A').run(srv);
    await coord(cfgB, 'B').run(srv);

    // The script rides the sealed record verbatim — the payload is opaque
    // JSON, so a new field needs no sync-layer change to travel. This pins
    // that assumption.
    final onB = (await cfgB.getServer('s1'))!;
    expect(onB.loginScript, 'cd /srv/app\ntail -f app.log');

    // Clearing it is an ordinary edit and converges the same way.
    await cfgB
        .putServer(onB.copyWith(clearLoginScript: true, updatedAt: 50));
    await coord(cfgB, 'B').run(srv);
    await coord(cfgA, 'A').run(srv);

    expect((await cfgA.getServer('s1'))!.loginScript, isNull);
  });

  test('an offline server rename cannot overwrite a peer credential edit',
      () async {
    final api = FakeServer();
    final key = secureRandomBytes(32);
    final configsA = InMemoryConfigStore();
    final configsB = InMemoryConfigStore();
    final vaultA = SecretVault(InMemoryVaultStore(), key);
    final vaultB = SecretVault(InMemoryVaultStore(), key);
    for (final label in ['alpha', 'zulu']) {
      await configsA.putServer(server(label, label, 10)
          .copyWith(secretRef: 'shared', syncSecret: true));
    }
    await vaultA.putLocalSecret(const Secret(
      id: 'shared',
      kind: SecretKind.password,
      value: 'original',
    ), updatedAt: 10);
    SyncCoordinator coordinator(ConfigStore configs, SecretVault vault,
            String device) =>
        SyncCoordinator(
          configStore: configs,
          hostKeyStore: InMemoryHostKeyStore(),
          codec: RecordCodec(key),
          local: InMemoryLocalRecordStore(),
          deviceId: device,
          syncSecrets: true,
          secretVault: vault,
        );
    await coordinator(configsA, vaultA, 'A').run(api);
    await coordinator(configsB, vaultB, 'B').run(api);

    await vaultB.putLocalSecret(const Secret(
      id: 'shared',
      kind: SecretKind.password,
      value: 'rotated',
    ), updatedAt: 20);
    final editedB = (await configsB.getServer('alpha'))!;
    await configsB.putServer(editedB.copyWith(updatedAt: 20));
    await coordinator(configsB, vaultB, 'B').run(api);

    final staleA = (await configsA.getServer('zulu'))!;
    await configsA.putServer(staleA.copyWith(label: 'renamed', updatedAt: 30));
    await coordinator(configsA, vaultA, 'A').run(api);
    await coordinator(configsB, vaultB, 'B').run(api);

    expect((await vaultA.getSecret('shared'))!.value, 'rotated');
    expect((await vaultB.getSecret('shared'))!.value, 'rotated');
    expect((await configsB.getServer('zulu'))!.label, 'renamed');
  });

  test('a legacy secret adopts and persists the remote credential version',
      () async {
    final api = FakeServer();
    final key = secureRandomBytes(32);
    final codec = RecordCodec(key);
    final configs = InMemoryConfigStore();
    final vaultStore = InMemoryVaultStore();
    final vault = SecretVault(vaultStore, key);
    await configs.putServer(server('s1', 'renamed while offline', 30)
        .copyWith(secretRef: 'legacy', syncSecret: true));
    await vault.putSecret(const Secret(
      id: 'legacy',
      kind: SecretKind.password,
      value: 'stale',
    ));
    await api.push([
      await codec.encrypt(const DecryptedRecord(
        id: 'secret:legacy',
        kind: RecordKind.secret,
        updatedAt: 20,
        deviceId: 'B',
        data: {'id': 'legacy', 'kind': 'password', 'value': 'current'},
      )),
    ]);
    final coordinator = SyncCoordinator(
      configStore: configs,
      hostKeyStore: InMemoryHostKeyStore(),
      codec: codec,
      local: InMemoryLocalRecordStore(),
      deviceId: 'A',
      syncSecrets: true,
      secretVault: vault,
    );

    await coordinator.run(api);

    final reopened = SecretVault(vaultStore, key);
    final restored = (await reopened.getSecret('legacy'))!;
    expect(restored.value, 'current');
    expect(restored.updatedAt, 20);
    // The encrypted vault now carries the observed credential version, even
    // though the peer's legacy payload did not contain one.
    await reopened.putLocalSecret(restored, updatedAt: 40);
    expect((await reopened.getSecret('legacy'))!.updatedAt, 20);
  });

  for (final envelopeStamp in [5, 30]) {
    test('a credential rejects envelope timestamp $envelopeStamp '
        'that disagrees with its sealed version', () async {
      final key = secureRandomBytes(32);
      final codec = RecordCodec(key);
      final vault = SecretVault(InMemoryVaultStore(), key);
      const original = Secret(
        id: 'secret',
        kind: SecretKind.password,
        value: 'current',
        updatedAt: 10,
      );
      await vault.putSecret(original);
      final local = InMemoryLocalRecordStore();
      await local.putRemote(await codec.encrypt(DecryptedRecord(
        id: 'secret:secret',
        kind: RecordKind.secret,
        updatedAt: envelopeStamp,
        deviceId: 'B',
        data: original.copyWith(value: 'incoming', updatedAt: 20).toJson(),
      )));
      final coordinator = SyncCoordinator(
        configStore: InMemoryConfigStore(),
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'A',
        syncSecrets: true,
        secretVault: vault,
      );

      await coordinator.applyToStores();

      expect((await vault.getSecret('secret'))!.toJson(), original.toJson());
    });
  }

  test('an unreadable vault entry is healed by the credential record', () async {
    final key = secureRandomBytes(32);
    final codec = RecordCodec(key);
    final vaultStore = InMemoryVaultStore();
    final vault = SecretVault(vaultStore, key);
    // Sealed under a key this vault does not have, which is what a vault entry
    // damaged in storage or left behind by a half-finished re-key looks like:
    // `getSecret` throws a MAC error instead of returning a version to compare.
    await SecretVault(vaultStore, secureRandomBytes(32)).putSecret(const Secret(
      id: 'secret',
      kind: SecretKind.password,
      value: 'unreadable',
      updatedAt: 99,
    ));
    await expectLater(vault.getSecret('secret'), throwsA(anything));
    final local = InMemoryLocalRecordStore();
    await local.putRemote(await codec.encrypt(const DecryptedRecord(
      id: 'secret:secret',
      kind: RecordKind.secret,
      updatedAt: 10,
      deviceId: 'B',
      data: {
        'id': 'secret',
        'kind': 'password',
        'value': 'current',
        'updatedAt': 10,
      },
    )));
    final coordinator = SyncCoordinator(
      configStore: InMemoryConfigStore(),
      hostKeyStore: InMemoryHostKeyStore(),
      codec: codec,
      local: local,
      deviceId: 'A',
      syncSecrets: true,
      secretVault: vault,
    );

    await coordinator.applyToStores();

    // The downgrade guard must not strand a copy that is useless anyway. An
    // entry with no readable version is absent, not something to protect —
    // the pull is the only thing that can repair it, and the read that decides
    // whether to keep it is the read that fails.
    final healed = await vault.getSecret('secret');
    expect(healed!.value, 'current');
    // Pinned, because a heal that wrote the value but kept the damaged entry's
    // sealed stamp would decrypt fine and then refuse every later update below
    // 99 — the same stranding, one step removed.
    expect(healed.updatedAt, 10);
  });

  test('opting out of credential publishing preserves a newer local edit',
      () async {
    final api = FakeServer();
    final key = secureRandomBytes(32);
    final codec = RecordCodec(key);
    final configs = InMemoryConfigStore();
    final vault = SecretVault(InMemoryVaultStore(), key);
    await configs.putServer(server('s1', 'server', 30)
        .copyWith(secretRef: 'secret', syncSecret: false));
    const current = Secret(
      id: 'secret',
      kind: SecretKind.password,
      value: 'current',
      updatedAt: 20,
    );
    await vault.putSecret(current);
    await api.push([
      await codec.encrypt(DecryptedRecord(
        id: 'secret:secret',
        kind: RecordKind.secret,
        updatedAt: 10,
        deviceId: 'B',
        data: current.copyWith(value: 'stale', updatedAt: 10).toJson(),
      )),
    ]);
    final coordinator = SyncCoordinator(
      configStore: configs,
      hostKeyStore: InMemoryHostKeyStore(),
      codec: codec,
      local: InMemoryLocalRecordStore(),
      deviceId: 'A',
      syncSecrets: true,
      secretVault: vault,
    );

    await coordinator.run(api);

    expect((await vault.getSecret('secret'))!.toJson(), current.toJson());
    expect(api.stored('secret:secret')!.updatedAt, 10,
        reason: 'receiving must not opt this device back into publishing');
  });

  test('reincluding a server restores its unchanged credential for new peers',
      () async {
    final api = FakeServer();
    final key = secureRandomBytes(32);
    final configsA = InMemoryConfigStore();
    final configsB = InMemoryConfigStore();
    final vaultA = SecretVault(InMemoryVaultStore(), key);
    final vaultB = SecretVault(InMemoryVaultStore(), key);
    final original = server('s1', 'server', 10)
        .copyWith(secretRef: 'secret', syncSecret: true);
    await configsA.putServer(original);
    await vaultA.putLocalSecret(const Secret(
      id: 'secret',
      kind: SecretKind.password,
      value: 'password',
    ), updatedAt: 10);
    SyncCoordinator coordinator(ConfigStore configs, SecretVault vault,
            String device) =>
        SyncCoordinator(
          configStore: configs,
          hostKeyStore: InMemoryHostKeyStore(),
          codec: RecordCodec(key),
          local: InMemoryLocalRecordStore(),
          deviceId: device,
          syncSecrets: true,
          secretVault: vault,
        );
    await coordinator(configsA, vaultA, 'A').run(api);
    final excluded = original.copyWith(excludeFromSync: true, updatedAt: 20);
    await configsA.putServer(excluded);
    await coordinator(configsA, vaultA, 'A').run(api);
    expect(api.stored('secret:secret')!.deleted, isTrue);

    await configsA.putServer(excluded.copyWith(
      excludeFromSync: false,
      updatedAt: 30,
    ));
    await coordinator(configsA, vaultA, 'A').run(api);
    await coordinator(configsB, vaultB, 'B').run(api);

    expect((await vaultB.getSecret('secret'))?.value, 'password');
    expect(api.stored('secret:secret')!.deleted, isFalse);
    final settled = api.latestSeq;
    await coordinator(configsA, vaultA, 'A').run(api);
    expect(api.latestSeq, settled, reason: 'a restore only advances once');
  });

  test('a peer\'s credential retraction is not revived by this device',
      () async {
    final api = FakeServer();
    final key = secureRandomBytes(32);
    final codec = RecordCodec(key);
    final configs = InMemoryConfigStore();
    final vault = SecretVault(InMemoryVaultStore(), key);
    await configs.putServer(server('s1', 'server', 10)
        .copyWith(secretRef: 'secret', syncSecret: true));
    await vault.putLocalSecret(const Secret(
      id: 'secret',
      kind: SecretKind.password,
      value: 'password',
    ), updatedAt: 10);
    // Device B excluded its own server sharing this credential. That is not a
    // decision this device can read as reversed, so the revival pass leaves
    // it alone — the documented residual is an orphan credential, never a
    // credential this device loses.
    await api.push([
      await codec.encrypt(DecryptedRecord(
        id: 'secret:secret',
        kind: RecordKind.secret,
        updatedAt: 20,
        deviceId: 'B',
        deleted: true,
      )),
    ]);

    await SyncCoordinator(
      configStore: configs,
      hostKeyStore: InMemoryHostKeyStore(),
      codec: codec,
      local: InMemoryLocalRecordStore(),
      deviceId: 'A',
      syncSecrets: true,
      secretVault: vault,
    ).run(api);

    expect(api.stored('secret:secret')!.deleted, isTrue);
    // The tombstone is never honoured against the vault, so the credential is
    // still here: withdrawn from the account, not lost on this device.
    expect((await vault.getSecret('secret'))!.value, 'password');
    expect((await vault.getSecret('secret'))!.updatedAt, 10,
        reason: 'a retraction this device did not make moves no stamp');
  });

  for (final scenario in [
    (label: 'alpha', syncSecret: true, excluded: false),
    (label: 'zulu', syncSecret: true, excluded: false),
    (label: 'alpha', syncSecret: false, excluded: false),
    (label: 'zulu', syncSecret: false, excluded: false),
    (label: 'alpha', syncSecret: true, excluded: true),
    (label: 'zulu', syncSecret: true, excluded: true),
  ]) {
    final editedLabel = scenario.label;
    test('a shared credential edit syncs when $scenario is edited', () async {
      final api = FakeServer();
      final key = secureRandomBytes(32);
      final codec = RecordCodec(key);
      final configsA = InMemoryConfigStore();
      final configsB = InMemoryConfigStore();
      final vaultA = SecretVault(InMemoryVaultStore(), key);
      final vaultB = SecretVault(InMemoryVaultStore(), key);
      for (final label in ['alpha', 'zulu']) {
        final excluded = label == editedLabel && scenario.excluded;
        await configsA.putServer(server(label, label, 10).copyWith(
          secretRef: 'shared',
          syncSecret: label != editedLabel || scenario.syncSecret,
          excludeFromSync: excluded,
          updatedAt: excluded ? 11 : 10,
        ));
      }
      await vaultA.putLocalSecret(const Secret(
        id: 'shared',
        kind: SecretKind.password,
        value: 'original',
      ), updatedAt: 10);

      SyncCoordinator coordinator(
        ConfigStore configs,
        SecretVault vault,
        String device,
      ) =>
          SyncCoordinator(
            configStore: configs,
            hostKeyStore: InMemoryHostKeyStore(),
            codec: codec,
            local: InMemoryLocalRecordStore(),
            deviceId: device,
            syncSecrets: true,
            secretVault: vault,
          );

      await coordinator(configsA, vaultA, 'A').run(api);
      await coordinator(configsB, vaultB, 'B').run(api);
      await vaultA.putLocalSecret(const Secret(
        id: 'shared',
        kind: SecretKind.password,
        value: 'rotated',
      ), updatedAt: 20);
      final edited = (await configsA.getServer(editedLabel))!;
      await configsA.putServer(edited.copyWith(updatedAt: 20));

      await coordinator(configsA, vaultA, 'A').run(api);
      await coordinator(configsB, vaultB, 'B').run(api);

      expect((await vaultA.getSecret('shared'))!.value, 'rotated');
      expect((await vaultB.getSecret('shared'))!.value, 'rotated');
      expect(api.stored('secret:shared')!.updatedAt, 20);
    });
  }

  for (final syncSecrets in [false, true]) {
    test('a shared credential needs an eligible owner (syncSecrets=$syncSecrets)',
        () async {
      final key = secureRandomBytes(32);
      final configs = InMemoryConfigStore();
      final vault = SecretVault(InMemoryVaultStore(), key);
      await vault.putSecret(const Secret(
        id: 'shared',
        kind: SecretKind.password,
        value: 'private',
      ));
      await configs.putServer(server('alpha', 'alpha', 10).copyWith(
        secretRef: 'shared',
        syncSecret: !syncSecrets,
      ));
      await configs.putServer(server('zulu', 'zulu', 10).copyWith(
        secretRef: 'shared',
        syncSecret: true,
        excludeFromSync: true,
        updatedAt: 20,
      ));
      final local = InMemoryLocalRecordStore();
      final coordinator = SyncCoordinator(
        configStore: configs,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: RecordCodec(key),
        local: local,
        deviceId: 'A',
        syncSecrets: syncSecrets,
        secretVault: vault,
      );

      await coordinator.collectLocal();

      expect(await local.getRecord('secret:shared'), isNull);
    });
  }

  test('snippets sync between two devices', () async {
    final srv = FakeServer();
    final codec = RecordCodec(secureRandomBytes(32));

    final snipA = InMemorySnippetStore();
    await snipA.putSnippet(Snippet(
        id: 'x1',
        title: 'Tail log',
        body: 'tail -f {{file}}',
        createdAt: 1,
        updatedAt: 10));
    SyncCoordinator coord(SnippetStore store, String dev) => SyncCoordinator(
          configStore: InMemoryConfigStore(),
          hostKeyStore: InMemoryHostKeyStore(),
          snippetStore: store,
          codec: codec,
          local: InMemoryLocalRecordStore(),
          deviceId: dev,
        );

    final snipB = InMemorySnippetStore();
    await coord(snipA, 'A').run(srv);
    await coord(snipB, 'B').run(srv);

    final onB = await snipB.listSnippets();
    expect(onB.single.title, 'Tail log');
    expect(onB.single.body, 'tail -f {{file}}');
    expect(onB.single.placeholders, ['file']);
  });

  for (final recordId in ['snippet:other', 'server-config-id']) {
    test('a snippet under $recordId cannot overwrite another snippet', () async {
      final codec = RecordCodec(secureRandomBytes(32));
      final snippets = InMemorySnippetStore();
      const current = Snippet(
        id: 'saved',
        title: 'Current snippet',
        body: 'echo current',
        createdAt: 1,
        updatedAt: 20,
      );
      await snippets.putSnippet(current);
      final local = InMemoryLocalRecordStore();
      await local.putRemote(await codec.encrypt(DecryptedRecord(
        id: recordId,
        kind: RecordKind.snippet,
        updatedAt: 30,
        deviceId: 'B',
        data: const Snippet(
          id: 'saved',
          title: 'Old snippet',
          body: 'echo old',
          createdAt: 1,
          updatedAt: 10,
        ).toJson(),
      )));
      final coordinator = SyncCoordinator(
        configStore: InMemoryConfigStore(),
        hostKeyStore: InMemoryHostKeyStore(),
        snippetStore: snippets,
        codec: codec,
        local: local,
        deviceId: 'A',
      );

      await coordinator.applyToStores();

      expect((await snippets.getSnippet('saved'))!.toJson(), current.toJson());
    });
  }

  test('bookmark records never create phantom server configs', () async {
    final server0 = FakeServer();
    final vaultKey = secureRandomBytes(32);
    final codec = RecordCodec(vaultKey);
    final blob = await VaultCrypto.sealJson(vaultKey, const {
      'kind': 'bookmark',
      'data': {
        'id': 'bookmark-1',
        'label': 'A bookmark, not a server',
        'host': 'nas.example.com',
        'username': 'alice',
        'createdAt': 1,
        'updatedAt': 2,
      },
    });
    await server0.push([
      EncryptedRecord(
        id: 'bookmark:bookmark-1',
        updatedAt: 2,
        deviceId: 'poltergeist',
        deleted: false,
        seq: null,
        blob: blob,
      ),
    ]);
    final configStore = InMemoryConfigStore();
    final coordinator = SyncCoordinator(
      configStore: configStore,
      hostKeyStore: InMemoryHostKeyStore(),
      codec: codec,
      local: InMemoryLocalRecordStore(),
      deviceId: 'seance',
    );

    final outcome = await coordinator.run(server0);

    expect(outcome.pulled, 1);
    expect(await configStore.listServers(), isEmpty);
  });

  test('unknown records remain byte-identical and are not refetched', () async {
    final server0 = FakeServer();
    final vaultKey = secureRandomBytes(32);
    final codec = RecordCodec(vaultKey);
    final blob = await VaultCrypto.sealJson(vaultKey, const {
      'kind': 'flurb',
      'data': {'future': true},
    });
    await server0.push([
      EncryptedRecord(
        id: 'flurb:future-1',
        updatedAt: 100,
        deviceId: 'future-device',
        deleted: false,
        seq: null,
        blob: blob,
      ),
    ]);
    final before = (await server0.pull(since: 0)).records.single;
    final local = InMemoryLocalRecordStore();
    final coordinator = SyncCoordinator(
      configStore: InMemoryConfigStore(),
      hostKeyStore: InMemoryHostKeyStore(),
      codec: codec,
      local: local,
      deviceId: 'seance',
    );
    final pushesBeforeSync = server0.pushedRecords;

    final first = await coordinator.run(server0);
    final second = await coordinator.run(server0);
    final after = (await server0.pull(since: 0)).records.single;

    expect(first.pulled, 1);
    expect(second.pulled, 0);
    expect(await local.highWaterSeq(), before.seq);
    expect(server0.pushedRecords, pushesBeforeSync);
    expect(after.id, before.id);
    expect(after.updatedAt, before.updatedAt);
    expect(after.deviceId, before.deviceId);
    expect(after.seq, before.seq);
    expect(after.blob, orderedEquals(before.blob));
  });

  test('persistent records are re-applied without another pull', () async {
    final server0 = FakeServer();
    final codec = RecordCodec(secureRandomBytes(32));
    final local = InMemoryLocalRecordStore();
    await local.putRemote(
      (await codec.encrypt(
        DecryptedRecord(
          id: 'learned-kind',
          kind: RecordKind.serverConfig,
          updatedAt: 2,
          deviceId: 'remote',
          data: server('learned-kind', 'learned', 2).toJson(),
        ),
      ))
          .withSeq(7),
    );
    await local.setHighWaterSeq(7);
    final configStore = InMemoryConfigStore();
    final coordinator = SyncCoordinator(
      configStore: configStore,
      hostKeyStore: InMemoryHostKeyStore(),
      codec: codec,
      local: local,
      deviceId: 'seance',
    );

    final outcome = await coordinator.run(server0);

    expect(outcome.pulled, 0);
    expect((await configStore.getServer('learned-kind'))!.label, 'learned');
  });

  test('a malformed known record does not block later records', () async {
    final codec = RecordCodec(secureRandomBytes(32));
    final local = InMemoryLocalRecordStore();
    await local.putRemote(
      await codec.encrypt(
        const DecryptedRecord(
          id: 'bad',
          kind: RecordKind.serverConfig,
          updatedAt: 1,
          deviceId: 'remote',
          data: {'id': 'bad', 'label': 'missing host and username'},
        ),
      ),
    );
    await local.putRemote(
      await codec.encrypt(
        DecryptedRecord(
          id: 'good',
          kind: RecordKind.serverConfig,
          updatedAt: 2,
          deviceId: 'remote',
          data: server('good', 'healthy', 2).toJson(),
        ),
      ),
    );
    final configStore = InMemoryConfigStore();
    final coordinator = SyncCoordinator(
      configStore: configStore,
      hostKeyStore: InMemoryHostKeyStore(),
      codec: codec,
      local: local,
      deviceId: 'seance',
    );

    await coordinator.applyToStores();

    expect((await configStore.getServer('good'))!.label, 'healthy');
    expect(await configStore.getServer('bad'), isNull);
  });

  test(
    'prefixless server tombstones still delete after the placeholder flip',
    () async {
      final codec = RecordCodec(secureRandomBytes(32));
      final local = InMemoryLocalRecordStore();
      final configStore = InMemoryConfigStore();
      await configStore.putServer(server('server-1', 'deleted', 1));
      await local.putRemote(
        await codec.encrypt(
          const DecryptedRecord(
            id: 'server-1',
            kind: RecordKind.serverConfig,
            updatedAt: 2,
            deviceId: 'remote',
            deleted: true,
          ),
        ),
      );
      final coordinator = SyncCoordinator(
        configStore: configStore,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'seance',
      );

      await coordinator.applyToStores();

      expect(await configStore.getServer('server-1'), isNull);
    },
  );

  test('prefixed tombstones are consumed before kind dispatch', () async {
    final codec = RecordCodec(secureRandomBytes(32));
    final local = InMemoryLocalRecordStore();
    final hostKeys = InMemoryHostKeyStore();
    final key = HostKey(
      host: 'nas.example.com',
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:aaa',
      pinnedAt: 1,
    );
    await hostKeys.put(key);
    await local.putRemote(
      await codec.encrypt(
        const DecryptedRecord(
          id: 'hostkey:nas.example.com:22',
          kind: RecordKind.hostKey,
          updatedAt: 2,
          deviceId: 'remote',
          deleted: true,
        ),
      ),
    );
    final coordinator = SyncCoordinator(
      configStore: InMemoryConfigStore(),
      hostKeyStore: hostKeys,
      codec: codec,
      local: local,
      deviceId: 'seance',
    );

    await coordinator.applyToStores();

    expect(await hostKeys.get('nas.example.com', 22), same(key));
  });

  group('exclude from sync', () {
    /// The set of record ids a coordinator would push, and whether each is a
    /// tombstone. Reading the local store after `collectLocal` is the only way
    /// to see what a round *would* send without a server in the way.
    Future<Map<String, bool>> collected(SyncCoordinator coordinator,
        LocalRecordStore local) async {
      await coordinator.collectLocal();
      return {
        for (final record in await local.allRecords())
          record.id: record.deleted,
      };
    }

    /// A plain coordinator over its own local store, for the [FakeServer]
    /// rounds below. Hoisted rather than repeated per test: a constructor
    /// argument added or renamed has to reach every one of them, and a copy
    /// left behind would quietly test the default instead.
    SyncCoordinator coord(
      RecordCodec codec,
      ConfigStore configs,
      String device, {
      LocalRecordStore? local,
      HostKeyStore? hostKeys,
      bool syncSecrets = false,
      SecretVault? secretVault,
    }) =>
        SyncCoordinator(
          configStore: configs,
          hostKeyStore: hostKeys ?? InMemoryHostKeyStore(),
          codec: codec,
          local: local ?? InMemoryLocalRecordStore(),
          deviceId: device,
          syncSecrets: syncSecrets,
          secretVault: secretVault,
        );

    test('an excluded server is retracted instead of pushed', () async {
      final codec = RecordCodec(secureRandomBytes(32));
      final configs = InMemoryConfigStore();
      final local = InMemoryLocalRecordStore();
      await configs.putServer(server('kept', 'alpha', 10));
      await configs.putServer(
        server('local-only', 'beta', 20).copyWith(
          secretRef: 'sec-1',
          excludeFromSync: true,
          updatedAt: 21,
        ),
      );

      final records = await collected(
        coord(codec, configs, 'A', local: local),
        local,
      );

      expect(records['kept'], isFalse, reason: 'a normal server still syncs');
      // Not merely absent: the copy pushed before the exclusion has to come
      // off the server, which only a tombstone does.
      expect(records['local-only'], isTrue);
      // And its credential with it, whatever the secret-sync settings say —
      // this device cannot tell whether an earlier session pushed one.
      expect(records['secret:sec-1'], isTrue);
    });

    test('the retraction is dated at the exclusion, not at the round',
        () async {
      final codec = RecordCodec(secureRandomBytes(32));
      final configs = InMemoryConfigStore();
      final local = InMemoryLocalRecordStore();
      await configs.putServer(
        server('local-only', 'beta', 4242)
            .copyWith(excludeFromSync: true, updatedAt: 4243),
      );
      final coordinator = coord(codec, configs, 'A', local: local);

      await coordinator.collectLocal();
      final tombstone = await local.getRecord('local-only');

      // A tombstone stamped "now" would be a different record every round, so
      // the server would sequence it again on each one and every other device
      // would pull it again. Stamping it at the edit that excluded the server
      // makes repeat rounds a no-op.
      expect(tombstone!.updatedAt, 4243);
      expect(tombstone.blob, isEmpty, reason: 'a tombstone leaks no payload');
    });

    test('the credential is retracted under the id it was pushed under',
        () async {
      // The push path keys a secret record by the vault's own `secret.id`
      // while the retraction keys it by the config's `secretRef`. They agree
      // because putSecret stores a blob under `secret.id` and serializes that
      // same id inside it — but the two paths are written apart, so the
      // agreement is asserted rather than assumed.
      final vaultKey = secureRandomBytes(32);
      final codec = RecordCodec(vaultKey);
      final vault = SecretVault(InMemoryVaultStore(), vaultKey);
      await vault.putSecret(const Secret(
        id: 'sec-1',
        kind: SecretKind.password,
        value: 'hunter2',
      ));

      final configs = InMemoryConfigStore();
      await configs.putServer(
        server('s1', 'alpha', 10)
            .copyWith(secretRef: 'sec-1', syncSecret: true),
      );
      SyncCoordinator coordinator(LocalRecordStore local) =>
          coord(codec, configs, 'A',
              local: local, syncSecrets: true, secretVault: vault);

      final pushed = InMemoryLocalRecordStore();
      final pushedIds = await collected(coordinator(pushed), pushed);
      expect(pushedIds['secret:sec-1'], isFalse);

      await configs.putServer((await configs.getServer('s1'))!
          .copyWith(excludeFromSync: true, updatedAt: 20));
      final retracted = InMemoryLocalRecordStore();
      final retractedIds =
          await collected(coordinator(retracted), retracted);
      // Same id, now as a tombstone. A mismatch here would leave the real
      // credential on the server forever.
      expect(retractedIds['secret:sec-1'], isTrue);
      // And dated past the copy this device pushed: a retraction that ties
      // or loses against it leaves the credential on the server just as
      // surely as a mismatched id would.
      expect(
        (await retracted.getRecord('secret:sec-1'))!.updatedAt,
        greaterThan((await pushed.getRecord('secret:sec-1'))!.updatedAt),
      );
    });

    test('a secret whose payload names another ref is skipped, not written',
        () async {
      // The shield keys on the record id and the vault write keys on the
      // payload's id, so a record whose two disagree would slip a credential
      // past the shield — and land it under a ref no shield ever named.
      final vaultKey = secureRandomBytes(32);
      final codec = RecordCodec(vaultKey);
      final vault = SecretVault(InMemoryVaultStore(), vaultKey);
      await vault.putSecret(const Secret(
        id: 'sec-shielded',
        kind: SecretKind.password,
        value: 'local-only',
      ));
      final configs = InMemoryConfigStore();
      await configs.putServer(
        server('excluded', 'alpha', 20).copyWith(
            secretRef: 'sec-shielded', excludeFromSync: true, updatedAt: 21),
      );
      final local = InMemoryLocalRecordStore();
      await local.putRemote(await codec.encrypt(DecryptedRecord(
        id: 'secret:sec-other',
        kind: RecordKind.secret,
        updatedAt: 99,
        deviceId: 'B',
        data: const Secret(
          id: 'sec-shielded',
          kind: SecretKind.password,
          value: 'from-the-other-device',
        ).toJson(),
      )));

      await coord(codec, configs, 'A',
              local: local, syncSecrets: true, secretVault: vault)
          .applyToStores();

      expect((await vault.getSecret('sec-shielded'))?.value, 'local-only');
      expect(await vault.getSecret('sec-other'), isNull);
    });

    test('no tombstone deletes a vault entry, referenced or not', () async {
      final vaultKey = secureRandomBytes(32);
      final codec = RecordCodec(vaultKey);
      final vault = SecretVault(InMemoryVaultStore(), vaultKey);
      const kept = Secret(
        id: 'sec-kept',
        kind: SecretKind.password,
        value: 'local-only',
      );
      const orphaned = Secret(
        id: 'sec-orphan',
        kind: SecretKind.password,
        value: 'withdrawn',
      );
      await vault.putSecret(kept);
      await vault.putSecret(orphaned);

      final configs = InMemoryConfigStore();
      await configs.putServer(
        server('excluded', 'alpha', 20).copyWith(
          secretRef: 'sec-kept',
          excludeFromSync: true,
          updatedAt: 21,
        ),
      );
      final local = InMemoryLocalRecordStore();
      // This device's own retraction, and one from a device whose server the
      // matching config tombstone has already removed. Neither is honoured:
      // a tombstone is unsealed, so a sync server can assert one on its own,
      // and the second case is exactly the shape that attack takes — an id no
      // local config references any more.
      for (final (id, from) in [
        ('secret:sec-kept', 'A'),
        ('secret:sec-orphan', 'B'),
      ]) {
        await local.putRemote(await codec.encrypt(DecryptedRecord(
          id: id,
          kind: RecordKind.secret,
          // Newer than the exclusion at 21, deliberately. Dated older, a
          // shield that merely refused tombstones *losing* last-write-wins
          // would pass this — and the point is that the refusal is
          // unconditional, because the date on an unsealed tombstone is the
          // sync server's to choose.
          updatedAt: 99,
          deviceId: from,
          deleted: true,
        )));
      }

      await coord(codec, configs, 'A',
              local: local, syncSecrets: true, secretVault: vault)
          .applyToStores();

      // Referenced by the local-only server, so it stays — this device has to
      // keep working.
      expect((await vault.getSecret('sec-kept'))?.value, 'local-only');
      // Referenced by nothing, and it stays too. This is the deliberate cost:
      // an orphan the vault carries rather than a delete taken on a sync
      // server's unauthenticated say-so. Sealing tombstones is what would let
      // this one be honoured; until then, garbage beats a vault-wipe
      // primitive.
      expect((await vault.getSecret('sec-orphan'))?.value, 'withdrawn');
      // And both stay staged, so a build that can verify them still has them:
      // pulls are incremental, and a dropped record is never redelivered.
      for (final id in ['secret:sec-kept', 'secret:sec-orphan']) {
        final staged = await local.getRecord(id);
        expect(staged, isNotNull);
        // Still the tombstone as received, not a record the apply rewrote:
        // what a sealed-tombstone build inherits has to be the deletion
        // itself, or there is nothing left to verify.
        expect(staged!.deleted, isTrue);
        expect(staged.updatedAt, 99,
            reason: 'the apply must not rewrite a tombstone it refused');
      }
    });

    test('a stale credential cannot overwrite an excluded server\'s',
        () async {
      final vaultKey = secureRandomBytes(32);
      final codec = RecordCodec(vaultKey);
      final vault = SecretVault(InMemoryVaultStore(), vaultKey);
      await vault.putSecret(const Secret(
        id: 'sec-1',
        kind: SecretKind.password,
        value: 'local-only',
      ));
      final configs = InMemoryConfigStore();
      await configs.putServer(
        server('excluded', 'alpha', 20)
            .copyWith(secretRef: 'sec-1', excludeFromSync: true, updatedAt: 21),
      );

      final local = InMemoryLocalRecordStore();
      // A device that has not seen the retraction yet, still pushing its copy.
      await local.putRemote(await codec.encrypt(DecryptedRecord(
        id: 'secret:sec-1',
        kind: RecordKind.secret,
        updatedAt: 99,
        deviceId: 'B',
        data: const Secret(
          id: 'sec-1',
          kind: SecretKind.password,
          value: 'from-the-other-device',
        ).toJson(),
      )));

      await coord(codec, configs, 'A',
              local: local, syncSecrets: true, secretVault: vault)
          .applyToStores();

      expect((await vault.getSecret('sec-1'))?.value, 'local-only');
    });

    test('changing the flag without a fresh timestamp is a bug, not a tie',
        () {
      final synced = server('s1', 'alpha', 10);
      // The tombstone is dated from updatedAt, so a stale one ties with the
      // record already on the server and loses the tie-break to it: the UI
      // would say "excluded" while the record sat there untouched. Caught at
      // the write rather than in a sync log.
      expect(
        () => synced.copyWith(excludeFromSync: true),
        throwsA(isA<ArgumentError>()),
      );
      // A timestamp that merely re-states the current one is the same bug: it
      // ties with the record on the server and loses the tie-break to it.
      expect(
        () => synced.copyWith(excludeFromSync: true, updatedAt: 10),
        throwsA(isA<ArgumentError>()),
      );
      // And strictly older, which loses outright rather than on a tie-break.
      expect(
        () => synced.copyWith(excludeFromSync: true, updatedAt: 9),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        synced.copyWith(excludeFromSync: true, updatedAt: 11).excludeFromSync,
        isTrue,
      );
      // Restating the value it already has is not a change and needs nothing.
      expect(synced.copyWith(excludeFromSync: false).excludeFromSync, isFalse);
      // Not even with a stale timestamp: the guard is about the flag's
      // tie-break, not about clock hygiene, so a no-op save from a device
      // whose clock trails is not something to refuse.
      expect(
        synced.copyWith(excludeFromSync: false, updatedAt: 5).excludeFromSync,
        isFalse,
      );
      // Re-including has the mirror-image tie: the live record that supersedes
      // the tombstone has to outrank it, so the guard must fire both ways.
      final excluded = synced.copyWith(excludeFromSync: true, updatedAt: 11);
      expect(
        () => excluded.copyWith(excludeFromSync: false),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => excluded.copyWith(excludeFromSync: false, updatedAt: 11),
        throwsA(isA<ArgumentError>()),
      );
      // And a strictly older timestamp loses outright, not merely ties.
      expect(
        () => excluded.copyWith(excludeFromSync: false, updatedAt: 5),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        excluded
            .copyWith(excludeFromSync: false, updatedAt: 12)
            .excludeFromSync,
        isFalse,
      );
      // And restating an exclusion the record already carries is the same
      // no-op, stale clock or not: only a *change* of the flag needs the
      // fresh timestamp.
      expect(
        excluded.copyWith(excludeFromSync: true, updatedAt: 5).excludeFromSync,
        isTrue,
      );
    });

    test('a credential a synced server shares is neither withdrawn nor frozen',
        () async {
      // Nothing stops two configs pointing at one vault entry, and a secret
      // record is keyed by the credential rather than by the server holding
      // it. Excluding one of the pair must not take the credential away from
      // the other — the same "every server that names it" rule the host-key
      // locators use.
      final vaultKey = secureRandomBytes(32);
      final codec = RecordCodec(vaultKey);
      final vault = SecretVault(InMemoryVaultStore(), vaultKey);
      await vault.putSecret(const Secret(
        id: 'shared',
        kind: SecretKind.password,
        value: 'old',
      ));

      final configs = InMemoryConfigStore();
      await configs.putServer(
        server('local-only', 'alpha', 20)
            .copyWith(secretRef: 'shared', excludeFromSync: true,
                updatedAt: 21),
      );
      await configs.putServer(
        server('still-synced', 'beta', 20)
            .copyWith(secretRef: 'shared', syncSecret: true),
      );
      SyncCoordinator coordinator(LocalRecordStore local) => coord(
            codec,
            configs,
            'A',
            local: local,
            syncSecrets: true,
            secretVault: vault,
          );

      final local = InMemoryLocalRecordStore();
      final collectedRecords = await collected(coordinator(local), local);
      // Pushed live for the server that still syncs, not tombstoned for the
      // one that no longer does: a tombstone dated at the exclusion would beat
      // that server's own push of the same id every round, ending credential
      // sync for a server the user never excluded.
      expect(collectedRecords, containsPair('secret:shared', isFalse));

      // And an update arriving for it is applied rather than shielded.
      final incoming = InMemoryLocalRecordStore();
      await incoming.putRemote(await codec.encrypt(DecryptedRecord(
        id: 'secret:shared',
        kind: RecordKind.secret,
        updatedAt: 99,
        deviceId: 'B',
        data: const Secret(
          id: 'shared',
          kind: SecretKind.password,
          value: 'rotated',
        ).toJson(),
      )));
      await coordinator(incoming).applyToStores();
      expect((await vault.getSecret('shared'))?.value, 'rotated');
    });

    test('a host key is withheld only when no synced server shares it',
        () async {
      final codec = RecordCodec(secureRandomBytes(32));
      final configs = InMemoryConfigStore();
      final hostKeys = InMemoryHostKeyStore();
      final local = InMemoryLocalRecordStore();
      await configs.putServer(
        server('local-only', 'beta', 10)
            .copyWith(excludeFromSync: true, updatedAt: 11),
      );
      // A second, syncing server on the same box — its own record already
      // names the address, so withholding the pin would protect nothing.
      await configs.putServer(ServerConfig(
        id: 'shared',
        label: 'beta root',
        host: 'beta.example.com',
        username: 'root',
        createdAt: 1,
        updatedAt: 10,
      ));
      for (final host in ['beta.example.com', 'gamma.example.com']) {
        await hostKeys.put(HostKey(
          host: host,
          type: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:$host',
          pinnedAt: 5,
        ));
      }

      var records = await collected(
        coord(codec, configs, 'A', local: local, hostKeys: hostKeys),
        local,
      );
      expect(records.containsKey('hostkey:beta.example.com:22'), isTrue);

      // Drop the syncing server and the same pin is withheld.
      await configs.deleteServer('shared');
      final second = InMemoryLocalRecordStore();
      records = await collected(
        coord(codec, configs, 'A', local: second, hostKeys: hostKeys),
        second,
      );
      // Withheld, not retracted — unlike the config and the credential. A
      // pin is keyed by `host:port`, so a tombstone for it would delete the
      // pin on every other device and drop them back to trust-on-first-use
      // for a host they may still reach through a server of their own. The
      // copy already on the server stays; only new pins stop going out.
      expect(records.containsKey('hostkey:beta.example.com:22'), isFalse);
      // A host no excluded server names is unaffected either way.
      expect(records.containsKey('hostkey:gamma.example.com:22'), isTrue);
    });

    test('applying records never deletes or overwrites an excluded server',
        () async {
      final codec = RecordCodec(secureRandomBytes(32));
      final configs = InMemoryConfigStore();
      final local = InMemoryLocalRecordStore();
      final excluded =
          server('local-only', 'beta', 20)
          .copyWith(excludeFromSync: true, updatedAt: 21);
      await configs.putServer(excluded);

      // This device's own retraction, come back from the server sequenced —
      // dated at the exclusion, which is where [_retract] dates it…
      await local.putRemote(await codec.encrypt(const DecryptedRecord(
        id: 'local-only',
        kind: RecordKind.serverConfig,
        updatedAt: 21,
        deviceId: 'A',
        deleted: true,
      )));
      // …and a second device that has not seen it yet, still pushing a
      // copy of its own.
      await local.putRemote(await codec.encrypt(DecryptedRecord(
        id: 'local-only',
        kind: RecordKind.serverConfig,
        updatedAt: 99,
        deviceId: 'B',
        data: server('local-only', 'renamed-elsewhere', 99).toJson(),
      )));

      final rescheduled =
          await coord(codec, configs, 'A', local: local).applyToStores();

      final after = await configs.getServer('local-only');
      expect(after, isNotNull,
          reason: 'the retraction must not delete it here');
      expect(after!.label, 'beta');
      expect(after.excludeFromSync, isTrue);

      // The copy at 99 could only get here by beating the tombstone dated 21,
      // so the retraction is re-dated to outrank it instead of being re-minted
      // at the same losing date every round.
      expect(rescheduled, 1);
      final staged =
          await codec.decrypt((await local.getRecord('local-only'))!);
      expect(staged.deleted, isTrue);
      expect(staged.updatedAt, 100);
    });

    test('a retraction the server outranked still lands', () async {
      // Device B edits under a clock ahead of A's, so A's exclusion carries a
      // timestamp that loses last-write-wins to the copy already on the
      // server. Without re-dating, A would show the server as excluded while
      // every other device kept it, forever.
      final remote = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));

      final cfgA = InMemoryConfigStore();
      final cfgB = InMemoryConfigStore();
      await cfgA.putServer(server('s1', 'alpha', 10));
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);

      // B renames it, stamping a timestamp A's clock has not reached yet.
      await cfgB.putServer(server('s1', 'renamed', 5000));
      await coord(codec, cfgB, 'B').run(remote);

      // A excludes it before pulling that rename: 31 is A's honest "now".
      await cfgA.putServer(
        server('s1', 'alpha', 30)
            .copyWith(excludeFromSync: true, updatedAt: 31),
      );
      await coord(codec, cfgA, 'A').run(remote);

      // A keeps its own copy, and B loses it on its next round all the same.
      expect((await cfgA.getServer('s1'))!.excludeFromSync, isTrue);
      await coord(codec, cfgB, 'B').run(remote);
      expect(await cfgB.getServer('s1'), isNull);

      // And it settles there: nothing re-dates once no live copy comes back.
      // Pinned by the server's sequence, which every accepted push advances:
      // a tombstone re-dated on every round would produce the same end state
      // and a new sequence number each time.
      final settled = (await remote.pull(since: 0)).latestSeq;
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);
      expect(await cfgB.getServer('s1'), isNull);
      expect((await cfgA.getServer('s1'))!.label, 'alpha');
      expect((await remote.pull(since: 0)).latestSeq, settled,
          reason: 'a settled round must not sequence anything new');
    });

    test('two devices that both exclude the same server settle', () async {
      // Each pulls the other's tombstone for an id it excludes itself, and
      // the shield skips it before anything could re-date it — so neither
      // bids past the other, and both keep their local-only copy.
      final remote = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));
      final cfgA = InMemoryConfigStore();
      final cfgB = InMemoryConfigStore();
      await cfgA.putServer(server('s1', 'alpha', 10));
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);

      await cfgA.putServer(
        server('s1', 'alpha', 10).copyWith(excludeFromSync: true, updatedAt: 31),
      );
      await coord(codec, cfgA, 'A').run(remote);
      await cfgB.putServer(
        server('s1', 'alpha', 10).copyWith(excludeFromSync: true, updatedAt: 40),
      );
      await coord(codec, cfgB, 'B').run(remote);
      await coord(codec, cfgA, 'A').run(remote);

      final settled = (await remote.pull(since: 0)).latestSeq;
      await coord(codec, cfgB, 'B').run(remote);
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);
      expect((await remote.pull(since: 0)).latestSeq, settled,
          reason: 'two exclusions must not re-date each other');
      expect((await cfgA.getServer('s1'))!.excludeFromSync, isTrue);
      expect((await cfgB.getServer('s1'))!.excludeFromSync, isTrue);
    });

    test('rescheduleOutranked never re-dates a tombstone', () async {
      // The call site only ever hands it live records, and a pulled tombstone
      // carries no kind — but the invariant is enforced where the minting
      // happens, like the kind check beside it.
      final codec = RecordCodec(secureRandomBytes(32));
      final configs = InMemoryConfigStore();
      await configs.putServer(
        server('s1', 'alpha', 10).copyWith(excludeFromSync: true, updatedAt: 11),
      );
      final local = InMemoryLocalRecordStore();
      final minted = await coord(codec, configs, 'A', local: local)
          .rescheduleOutranked([
        const DecryptedRecord(
          id: 's1',
          kind: RecordKind.serverConfig,
          updatedAt: 20,
          deviceId: 'B',
          deleted: true,
        ),
      ]);
      expect(minted, 0);
      expect(await local.allRecords(), isEmpty);
    });

    test('a host key whose payload names another locator is skipped', () async {
      // The pin would be stored under the payload's locator, planting trust
      // for an address no record ever named — the hole the config and secret
      // paths close for their own ids.
      final codec = RecordCodec(secureRandomBytes(32));
      final pins = InMemoryHostKeyStore();
      final local = InMemoryLocalRecordStore();
      await local.putRemote(await codec.encrypt(DecryptedRecord(
        id: 'hostkey:a.example.com:22',
        kind: RecordKind.hostKey,
        updatedAt: 10,
        deviceId: 'B',
        data: HostKey(
          host: 'b.example.com',
          port: 22,
          type: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:planted',
          pinnedAt: 10,
        ).toJson(),
      )));

      await coord(codec, InMemoryConfigStore(), 'A',
              local: local, hostKeys: pins)
          .applyToStores();

      expect(await pins.get('b.example.com', 22), isNull);
      expect(await pins.get('a.example.com', 22), isNull);
    });

    test('a pin pulled for an address only excluded servers use stays out',
        () async {
      // Withheld on the way out, so the mirror never holds this device's own
      // pin — a pulled copy would win by default and overwrite it. One
      // included server on the same address keeps pins flowing, as it keeps
      // them pushed.
      final codec = RecordCodec(secureRandomBytes(32));
      final configs = InMemoryConfigStore();
      await configs.putServer(server('only', 'alpha', 20)
          .copyWith(excludeFromSync: true, updatedAt: 21));
      await configs.putServer(
        server('shared', 'beta', 20).copyWith(host: 'both.example.com'),
      );
      await configs.putServer(server('shared-excluded', 'gamma', 20).copyWith(
          host: 'both.example.com', excludeFromSync: true, updatedAt: 21));
      final pins = InMemoryHostKeyStore();
      final local = InMemoryLocalRecordStore();
      for (final host in ['alpha.example.com', 'both.example.com']) {
        await local.putRemote(await codec.encrypt(DecryptedRecord(
          id: 'hostkey:$host:22',
          kind: RecordKind.hostKey,
          updatedAt: 10,
          deviceId: 'B',
          data: HostKey(
            host: host,
            port: 22,
            type: 'ssh-ed25519',
            fingerprintSha256: 'SHA256:from-b',
            pinnedAt: 10,
          ).toJson(),
        )));
      }

      await coord(codec, configs, 'A', local: local, hostKeys: pins)
          .applyToStores();

      expect(await pins.get('alpha.example.com', 22), isNull);
      expect(await pins.get('both.example.com', 22), isNotNull);
    });

    test('a peer\'s later exclusion outranks a re-inclusion', () async {
      // The residual the revival guard leaves: both devices exclude, A
      // re-includes, and B's re-dated retraction — not A's own, so not
      // revived past — deletes the config A just took back. Pinned so a
      // change here is a decision, not a drift.
      final remote = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));
      final cfgA = InMemoryConfigStore();
      final cfgB = InMemoryConfigStore();
      await cfgA.putServer(server('s1', 'alpha', 10));
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);

      await cfgA.putServer(server('s1', 'alpha', 10)
          .copyWith(excludeFromSync: true, updatedAt: 20));
      await coord(codec, cfgA, 'A').run(remote);
      await cfgB.putServer(server('s1', 'alpha', 10)
          .copyWith(excludeFromSync: true, updatedAt: 25));
      await coord(codec, cfgB, 'B').run(remote);

      await cfgA.putServer(server('s1', 'alpha', 10)
          .copyWith(excludeFromSync: false, updatedAt: 30));
      await coord(codec, cfgA, 'A').run(remote);
      expect((await cfgA.getServer('s1'))?.excludeFromSync, isFalse);

      // B's shield re-dates its retraction past A's live copy…
      await coord(codec, cfgB, 'B').run(remote);
      // …and A, pulling a retraction that is not its own, honours it.
      await coord(codec, cfgA, 'A').run(remote);
      expect(await cfgA.getServer('s1'), isNull);
    });

    test('a round that re-dates nothing makes one engine pass', () async {
      // The second pass is gated on the *re-dating* count. Were
      // `applyToStores` ever to answer with the number of records applied,
      // the gate would open on every round that pulled anything, and the
      // extra pass would hide inside the summed outcome — so the pull count
      // is pinned: one to find the record, one to see nothing follows it.
      final codec = RecordCodec(secureRandomBytes(32));
      final remote = FakeServer();
      final cfgA = InMemoryConfigStore();
      final cfgB = InMemoryConfigStore();
      await cfgA.putServer(server('s1', 'alpha', 22));
      await coord(codec, cfgA, 'A').run(remote);

      remote.pulls = 0;
      await coord(codec, cfgB, 'B').run(remote);
      expect(await cfgB.getServer('s1'), isNotNull);
      expect(remote.pulls, 2);
    });

    test('the credential is retracted end to end, without emptying B\'s vault',
        () async {
      // The other half of what the switch's subtitle promises, and the half
      // no cross-device test covered: it asserted only that B's server row
      // goes. Both halves matter and they resolve differently — the record
      // leaves the sync server, B's vault entry does not leave B.
      final remote = FakeServer();
      final vaultKey = secureRandomBytes(32);
      final codec = RecordCodec(vaultKey);
      const credential = Secret(
        id: 'sec-1',
        kind: SecretKind.password,
        value: 'hunter2',
      );

      final vaultA = SecretVault(InMemoryVaultStore(), vaultKey);
      final vaultB = SecretVault(InMemoryVaultStore(), vaultKey);
      await vaultA.putSecret(credential);

      final cfgA = InMemoryConfigStore();
      final cfgB = InMemoryConfigStore();
      await cfgA.putServer(
        server('s1', 'alpha', 10)
            .copyWith(secretRef: 'sec-1', syncSecret: true),
      );
      SyncCoordinator withSecrets(
        ConfigStore configs,
        SecretVault vault,
        String device,
      ) =>
          SyncCoordinator(
            configStore: configs,
            hostKeyStore: InMemoryHostKeyStore(),
            codec: codec,
            local: InMemoryLocalRecordStore(),
            deviceId: device,
            syncSecrets: true,
            secretVault: vault,
          );

      await withSecrets(cfgA, vaultA, 'A').run(remote);
      await withSecrets(cfgB, vaultB, 'B').run(remote);
      expect((await vaultB.getSecret('sec-1'))?.value, 'hunter2',
          reason: 'the credential has to reach B before it can be retracted');

      await cfgA.putServer((await cfgA.getServer('s1'))!
          .copyWith(excludeFromSync: true, updatedAt: 31));
      await withSecrets(cfgA, vaultA, 'A').run(remote);
      await withSecrets(cfgB, vaultB, 'B').run(remote);

      // The server row goes, and the credential's record on the sync server is
      // a tombstone — so a third device joining now gets neither.
      expect(await cfgB.getServer('s1'), isNull);
      final onServer = await remote.pull(since: 0);
      final secretRecord =
          onServer.records.where((r) => r.id == 'secret:sec-1').last;
      expect(secretRecord.deleted, isTrue);
      // Payload-free, observed after a real push/pull round trip rather than
      // straight off the local store: the config and secret retraction paths
      // are written apart, and only the config one was pinned.
      expect(secretRecord.blob, isEmpty);

      // A keeps working, which is the point of excluding rather than deleting.
      expect((await vaultA.getSecret('sec-1'))?.value, 'hunter2');
      // B keeps an orphan: nothing names it, and nothing deletes it either,
      // because the tombstone that says so is unsealed. Stated as an
      // assertion so the residual is visible rather than folklore.
      expect((await vaultB.getSecret('sec-1'))?.value, 'hunter2');
    });

    test('one refused write does not sink the whole re-dating pass', () async {
      // The record loop is fail-soft per record; the post-loop re-dating was
      // not, so a transient store error on one server threw out of
      // applyToStores — discarding the sync outcome the round had earned and
      // skipping its second pass.
      final codec = RecordCodec(secureRandomBytes(32));
      final configs = InMemoryConfigStore();
      final local = _RefusingLocalStore(InMemoryLocalRecordStore(), 'bad');

      // Both re-included behind this device's own retraction, so both need a
      // bump — and staging 'bad' throws.
      for (final id in ['bad', 'good']) {
        await configs.putServer(server(id, id, 10));
        await local.putRemote(await codec.encrypt(DecryptedRecord(
          id: id,
          kind: RecordKind.serverConfig,
          updatedAt: 20,
          deviceId: 'A',
          deleted: true,
        )));
      }

      final coordinator = coord(codec, configs, 'A', local: local);
      // 'good' is revived even though 'bad' threw, and the count reports only
      // what actually landed — the caller spends its extra push round on a
      // real re-dating rather than on a batch that failed.
      expect(await coordinator.applyToStores(), 1);
      expect((await configs.getServer('good'))!.updatedAt, 21);
      // The *bump* is what has to be staged: the tombstone seeded above sits
      // under the same id, so "a record exists" would hold even if nothing
      // had been written.
      final staged = await codec.decrypt((await local.getRecord('good'))!);
      expect(staged.deleted, isFalse);
      expect(staged.updatedAt, 21);
    });

    test('a config whose payload id disagrees is skipped, not written',
        () async {
      // The exclusion shield keys on the record id and the write would key on
      // the payload's, so a record whose two ids disagree slips past it — and
      // lands under an id no tombstone can name.
      final codec = RecordCodec(secureRandomBytes(32));
      final configs = InMemoryConfigStore();
      final local = InMemoryLocalRecordStore();
      await local.putRemote(await codec.encrypt(DecryptedRecord(
        id: 'envelope-id',
        kind: RecordKind.serverConfig,
        updatedAt: 10,
        deviceId: 'B',
        data: server('payload-id', 'alpha', 10).toJson(),
      )));

      await coord(codec, configs, 'A', local: local).applyToStores();

      expect(await configs.listServers(), isEmpty);
    });

    test('a server nobody excluded is never re-tombstoned', () async {
      // [_rescheduleOutranked] mints a deletion for every record it is given,
      // so its safety used to rest entirely on the call site handing it only
      // configs that beat a retraction. It re-reads the exclusion itself now:
      // an unfiltered list would otherwise delete every pulled config on every
      // device, which is the one mistake in this file whose blast radius is
      // the whole account.
      final remote = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));
      final cfgA = InMemoryConfigStore();
      final cfgB = InMemoryConfigStore();

      await cfgA.putServer(server('s1', 'alpha', 10));
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);

      final local = InMemoryLocalRecordStore();
      final coordB = SyncCoordinator(
        configStore: cfgB,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'B',
      );
      await coordB.run(remote);

      expect(await coordB.applyToStores(), 0,
          reason: 'nothing was outranked, so nothing needs a second push');
      final staged = await codec.decrypt((await local.getRecord('s1'))!);
      expect(staged.deleted, isFalse);
      expect(await cfgB.getServer('s1'), isNotNull);

      // And the guard itself, reached directly: handed the live config it
      // would have been handed by a call site that forgot to filter, it mints
      // nothing, because no local server carries the exclusion. Going through
      // applyToStores can only ever prove the filter.
      expect(await coordB.rescheduleOutranked([staged]), 0);
      expect(
        (await codec.decrypt((await local.getRecord('s1'))!)).deleted,
        isFalse,
        reason: 'an unfiltered record must not become a deletion',
      );

      // The same call with the server actually excluded does re-date it, so
      // the zero above is the guard and not an inert method.
      await cfgB.putServer(
        (await cfgB.getServer('s1'))!
            .copyWith(excludeFromSync: true, updatedAt: staged.updatedAt + 5),
      );
      expect(await coordB.rescheduleOutranked([staged]), 1);
      expect(
        (await codec.decrypt((await local.getRecord('s1'))!)).deleted,
        isTrue,
      );
    });

    test('re-including a server that already outranks its retraction is free',
        () async {
      // [_revive] skips a server whose live record already beats the
      // retraction — nothing to bump. It must not report those as re-dated:
      // the count is what [SyncCoordinator.run] spends an extra pull-and-push
      // round on, so counting a no-op batch buys a round that changes nothing.
      final codec = RecordCodec(secureRandomBytes(32));
      final configs = InMemoryConfigStore();
      final local = InMemoryLocalRecordStore();

      // Re-included at 50, against this device's own retraction dated 20.
      await configs.putServer(server('s1', 'alpha', 50));
      await local.putRemote(await codec.encrypt(const DecryptedRecord(
        id: 's1',
        kind: RecordKind.serverConfig,
        updatedAt: 20,
        deviceId: 'A',
        deleted: true,
      )));

      final coordinator = coord(codec, configs, 'A', local: local);
      expect(await coordinator.applyToStores(), 0);
      // Still there, still on its own timestamp — no bump was needed and none
      // was made.
      expect((await configs.getServer('s1'))!.updatedAt, 50);
    });

    test('re-including a server supersedes its tombstone', () async {
      // The one transition where a tombstone is already staged locally: the
      // live record has to replace it rather than be skipped for being deleted.
      final remote = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));

      final cfgA = InMemoryConfigStore();
      final cfgB = InMemoryConfigStore();
      await cfgA.putServer(server('s1', 'alpha', 10)
          .copyWith(excludeFromSync: true, updatedAt: 11));
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);
      expect(await cfgB.getServer('s1'), isNull);

      await cfgA.putServer((await cfgA.getServer('s1'))!
          .copyWith(excludeFromSync: false, updatedAt: 30));
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);

      final revived = await cfgB.getServer('s1');
      expect(revived, isNotNull,
          reason: 're-including must beat the tombstone');
      expect(revived!.label, 'alpha');
      expect(revived.excludeFromSync, isFalse);
    });

    test('re-including still lands after the tombstone was re-dated',
        () async {
      // Excluding under a clock this device runs behind re-dates the tombstone
      // past its own "now", and the guard on copyWith only compares against
      // the config's own updatedAt — so an honest re-inclusion stamp still
      // loses, and the device would apply its own stale retraction and delete
      // the server it had just brought back.
      final remote = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));
      final cfgA = InMemoryConfigStore();
      final cfgB = InMemoryConfigStore();
      await cfgA.putServer(server('s1', 'alpha', 10));
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);

      // B's clock is an hour ahead; A excludes at its own honest 31.
      await cfgB.putServer(server('s1', 'renamed', 5000));
      await coord(codec, cfgB, 'B').run(remote);
      await cfgA.putServer(
        server('s1', 'alpha', 30)
            .copyWith(excludeFromSync: true, updatedAt: 31),
      );
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);
      expect(await cfgB.getServer('s1'), isNull);

      // A changes its mind, at a stamp that still trails the re-dated
      // tombstone sitting on the server.
      await cfgA.putServer((await cfgA.getServer('s1'))!
          .copyWith(excludeFromSync: false, updatedAt: 32));
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);

      expect(await cfgA.getServer('s1'), isNotNull,
          reason: 'a device must not delete a server it just re-included');
      expect((await cfgA.getServer('s1'))!.label, 'alpha');
      final revived = await cfgB.getServer('s1');
      expect(revived, isNotNull,
          reason: 're-inclusion has to outrank the re-dated tombstone');
      expect(revived!.label, 'alpha');

      // And it settles: nothing re-dates once the live record is winning.
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);
      expect(await cfgB.getServer('s1'), isNotNull);
    });

    test('a secret tombstone never reaches the vault, and stalls nothing',
        () async {
      // The vault is one that throws on any delete. Nothing should ask it to:
      // a `secret:` tombstone is staged and pushed, never applied. The
      // refusing vault is what makes that assertable — a delete attempted at
      // all would surface here as a skipped record rather than as silence.
      final vaultKey = secureRandomBytes(32);
      final codec = RecordCodec(vaultKey);
      final vault = _RefusingVault(InMemoryVaultStore(), vaultKey);
      final configs = InMemoryConfigStore();
      final hostKeys = InMemoryHostKeyStore();
      final local = InMemoryLocalRecordStore();

      await local.putRemote(await codec.encrypt(const DecryptedRecord(
        id: 'secret:sec-1',
        kind: RecordKind.secret,
        updatedAt: 20,
        deviceId: 'B',
        deleted: true,
      )));
      await local.putRemote(await codec.encrypt(DecryptedRecord(
        id: 'hostkey:beta.example.com:22',
        kind: RecordKind.hostKey,
        updatedAt: 20,
        deviceId: 'B',
        data: const HostKey(
          host: 'beta.example.com',
          port: 22,
          type: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:abc',
          pinnedAt: 20,
        ).toJson(),
      )));

      await expectLater(
        SyncCoordinator(
          configStore: configs,
          hostKeyStore: hostKeys,
          codec: codec,
          local: local,
          deviceId: 'A',
          syncSecrets: true,
          secretVault: vault,
        ).applyToStores(),
        completion(0),
      );
      expect(vault.deletesAttempted, 0,
          reason: 'an unsealed tombstone must not reach the vault at all');
      // And it is still staged, so a build that seals tombstones inherits it
      // — pulls are incremental, so a dropped one is never delivered again.
      expect(await local.getRecord('secret:sec-1'), isNotNull);
      // The rest of the batch still applied.
      expect((await hostKeys.all()).single.host, 'beta.example.com');
    });

    test('excluding on one device removes the server from the other', () async {
      final remote = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));

      final cfgA = InMemoryConfigStore();
      await cfgA.putServer(server('s1', 'alpha', 10));
      SyncCoordinator coordA(LocalRecordStore local) => SyncCoordinator(
            configStore: cfgA,
            hostKeyStore: InMemoryHostKeyStore(),
            codec: codec,
            local: local,
            deviceId: 'A',
          );

      final cfgB = InMemoryConfigStore();
      SyncCoordinator coordB(LocalRecordStore local) => SyncCoordinator(
            configStore: cfgB,
            hostKeyStore: InMemoryHostKeyStore(),
            codec: codec,
            local: local,
            deviceId: 'B',
          );

      await coordA(InMemoryLocalRecordStore()).run(remote);
      await coordB(InMemoryLocalRecordStore()).run(remote);
      expect(await cfgB.getServer('s1'), isNotNull);

      // A excludes it — an edit, so it carries a later timestamp.
      await cfgA.putServer(
        server('s1', 'alpha', 30)
            .copyWith(excludeFromSync: true, updatedAt: 31),
      );
      await coordA(InMemoryLocalRecordStore()).run(remote);

      // A keeps its copy; B loses it on its next round, which is what the
      // editor's subtitle promises.
      expect((await cfgA.getServer('s1'))!.excludeFromSync, isTrue);
      await coordB(InMemoryLocalRecordStore()).run(remote);
      expect(await cfgB.getServer('s1'), isNull);

      // And it stays gone: B re-pushing nothing, A re-pushing the same
      // tombstone, converges instead of resurrecting or churning.
      await coordA(InMemoryLocalRecordStore()).run(remote);
      await coordB(InMemoryLocalRecordStore()).run(remote);
      expect(await cfgB.getServer('s1'), isNull);
      expect((await cfgA.getServer('s1'))!.label, 'alpha');
    });
  });

  group('deleting a server propagates instead of reappearing', () {
    // Regression for "I can't delete servers; they immediately reappear"
    // (issue #54). The app rebuilds its record mirror from a full pull each
    // round, so a deleted server used to return from the server and be
    // re-adopted. The fix records the deletion in a durable [TombstoneStore]
    // that the coordinator republishes as a tombstone until the server has it.
    //
    // Each round gets a *fresh* mirror, as `AppServices.runSync` does; the
    // config store and the tombstone store persist across rounds, as the app's
    // files do. Deleting is modelled the way the app performs it: drop the
    // config row and record a tombstone.
    SyncCoordinator coord(
      String deviceId,
      ConfigStore configStore,
      TombstoneStore tombstones,
      RecordCodec codec,
    ) => SyncCoordinator(
          configStore: configStore,
          hostKeyStore: InMemoryHostKeyStore(),
          codec: codec,
          local: InMemoryLocalRecordStore(),
          deviceId: deviceId,
          tombstoneStore: tombstones,
        );

    EncryptedRecord tombstoneFor(String id, String deviceId, int at) =>
        EncryptedRecord.tombstone(id: id, updatedAt: at, deviceId: deviceId);

    test('a deleted server is not re-adopted from the server', () async {
      final api = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));
      final cfg = InMemoryConfigStore();
      final tombstones = InMemoryTombstoneStore();

      await cfg.putServer(server('s1', 'alpha', 10));
      await coord('A', cfg, tombstones, codec).run(api);
      expect(api.stored('s1')!.deleted, isFalse,
          reason: 'the server was pushed live');

      await cfg.deleteServer('s1');
      await tombstones.add(tombstoneFor('s1', 'A', 20));
      await coord('A', cfg, tombstones, codec).run(api);

      expect(await cfg.getServer('s1'), isNull,
          reason: 'the still-live server record must not be re-adopted');
      expect(api.stored('s1')!.deleted, isTrue,
          reason: 'the delete reached the server as a tombstone');
      expect(api.stored('s1')!.blob, isEmpty,
          reason: 'a tombstone leaks no payload');
      expect(await tombstones.all(), isEmpty,
          reason: 'a tombstone the server has taken is pruned');
    });

    test('the deletion converges to a second device', () async {
      final api = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32)); // shared vault
      final cfgA = InMemoryConfigStore();
      final tsA = InMemoryTombstoneStore();
      final cfgB = InMemoryConfigStore();
      final tsB = InMemoryTombstoneStore();

      await cfgA.putServer(server('s1', 'alpha', 10));
      await coord('A', cfgA, tsA, codec).run(api);
      // B has to hold the server before it can be asked to lose it.
      await coord('B', cfgB, tsB, codec).run(api);
      expect(await cfgB.getServer('s1'), isNotNull);

      await cfgA.deleteServer('s1');
      await tsA.add(tombstoneFor('s1', 'A', 20));
      await coord('A', cfgA, tsA, codec).run(api);
      await coord('B', cfgB, tsB, codec).run(api);

      expect(await cfgB.getServer('s1'), isNull,
          reason: 'B honours the tombstone A pushed');
    });

    test('a settled deletion pushes nothing on later rounds', () async {
      final api = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));
      final cfg = InMemoryConfigStore();
      final tombstones = InMemoryTombstoneStore();

      await cfg.putServer(server('s1', 'alpha', 10));
      await coord('A', cfg, tombstones, codec).run(api);
      await cfg.deleteServer('s1');
      await tombstones.add(tombstoneFor('s1', 'A', 20));
      await coord('A', cfg, tombstones, codec).run(api);
      expect(await tombstones.all(), isEmpty);

      final settledSeq = api.latestSeq;
      await coord('A', cfg, tombstones, codec).run(api);
      expect(api.latestSeq, settledSeq,
          reason: 'a pruned tombstone is not re-pushed every round');
      expect(await cfg.getServer('s1'), isNull,
          reason: 'the server still holds the tombstone, so it stays gone');
    });

    test('deleting one server leaves the others untouched', () async {
      final api = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));
      final cfg = InMemoryConfigStore();
      final tombstones = InMemoryTombstoneStore();

      await cfg.putServer(server('s1', 'alpha', 10));
      await cfg.putServer(server('s2', 'beta', 10));
      await coord('A', cfg, tombstones, codec).run(api);

      await cfg.deleteServer('s1');
      await tombstones.add(tombstoneFor('s1', 'A', 20));
      await coord('A', cfg, tombstones, codec).run(api);

      expect(await cfg.getServer('s1'), isNull);
      expect(await cfg.getServer('s2'), isNotNull,
          reason: 'only the deleted server goes');
      expect(api.stored('s2')!.deleted, isFalse);
    });

    test('an interrupted row-drop keeps its tombstone pending', () async {
      // The prune must not drop a tombstone the delete has not yet won. A
      // tombstone recorded at a later stamp than a row that still exists (an
      // interrupted row-drop) has a mirrored live record that is sequenced but
      // *older*, so the tombstone can still win and is retained, not pruned.
      final api = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));
      final cfg = InMemoryConfigStore();
      final tombstones = InMemoryTombstoneStore();

      await cfg.putServer(server('s1', 'alpha', 10));
      await coord('A', cfg, tombstones, codec).run(api);

      await tombstones.add(tombstoneFor('s1', 'A', 20));
      await coord('A', cfg, tombstones, codec).run(api);

      expect(await cfg.getServer('s1'), isNotNull,
          reason: 'the still-live row is untouched');
      expect(await tombstones.all(), hasLength(1),
          reason: 'a tombstone an older sequenced live record cannot supersede '
              'is retained for retry, not pruned');
    });

    test('a tombstone a newer peer edit supersedes is pruned', () async {
      // A peer's later edit wins last-write-wins, so the delete lost and the
      // record converges back locally. The tombstone can never beat that newer
      // record, and collectLocal skips it while the row exists, so it is pruned
      // rather than left to leak — distinct from an unconfirmed (offline) entry,
      // which is retained and retried.
      final api = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));
      final cfg = InMemoryConfigStore();
      final tombstones = InMemoryTombstoneStore();

      await cfg.putServer(server('s1', 'alpha', 10));
      await coord('A', cfg, tombstones, codec).run(api);

      // A peer edits the same server later than this device's delete stamp.
      final peerEdit = await codec.encrypt(DecryptedRecord(
        id: 's1',
        kind: RecordKind.serverConfig,
        updatedAt: 99,
        deviceId: 'B',
        data: server('s1', 'alpha-renamed', 99).toJson(),
      ));
      await api.push([peerEdit]);

      await cfg.deleteServer('s1');
      await tombstones.add(tombstoneFor('s1', 'A', 20));
      await coord('A', cfg, tombstones, codec).run(api);

      expect(await cfg.getServer('s1'), isNotNull,
          reason: 'the newer peer edit converges back onto this device');
      expect(api.stored('s1')!.deleted, isFalse,
          reason: 'the peer edit outranks the delete (LWW), as it should');
      expect(await tombstones.all(), isEmpty,
          reason: 'a tombstone a strictly-newer live record superseded can '
              'never win, so it is pruned rather than retried forever');
    });

    test('a pending tombstone never shadows a re-created live record', () async {
      // An id deleted while offline (tombstone still pending) then re-created
      // with the same id: collectLocal must publish the live record and skip
      // the tombstone, so the delete is not pushed for a row that exists.
      final api = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));
      final cfg = InMemoryConfigStore();
      final tombstones = InMemoryTombstoneStore();

      await cfg.putServer(server('s1', 'alpha', 30));
      await tombstones.add(tombstoneFor('s1', 'A', 20));
      await coord('A', cfg, tombstones, codec).run(api);

      expect(api.stored('s1'), isNotNull);
      expect(api.stored('s1')!.deleted, isFalse,
          reason: 'the live re-created record wins, not the shadowed tombstone');
      expect(await cfg.getServer('s1'), isNotNull);
      expect(await tombstones.all(), isEmpty,
          reason: 'the shadowed tombstone is superseded by the newer live '
              'record and pruned (the app also clears it on re-save)');
    });

    test('a snippet deletion converges to a second device', () async {
      final api = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));

      SyncCoordinator coordS(
        String deviceId,
        SnippetStore snippets,
        TombstoneStore tombstones,
      ) => SyncCoordinator(
            configStore: InMemoryConfigStore(),
            hostKeyStore: InMemoryHostKeyStore(),
            codec: codec,
            local: InMemoryLocalRecordStore(),
            deviceId: deviceId,
            snippetStore: snippets,
            tombstoneStore: tombstones,
          );

      final snipA = InMemorySnippetStore();
      final tsA = InMemoryTombstoneStore();
      final snipB = InMemorySnippetStore();
      final tsB = InMemoryTombstoneStore();

      await snipA.putSnippet(const Snippet(
          id: 'x', title: 't', body: 'ls', createdAt: 1, updatedAt: 10));
      await coordS('A', snipA, tsA).run(api);
      await coordS('B', snipB, tsB).run(api);
      expect(await snipB.getSnippet('x'), isNotNull);

      await snipA.deleteSnippet('x');
      await tsA.add(tombstoneFor('snippet:x', 'A', 20));
      await coordS('A', snipA, tsA).run(api);
      await coordS('B', snipB, tsB).run(api);

      expect(await snipB.getSnippet('x'), isNull,
          reason: 'a snippet tombstone is honoured on the peer, unlike '
              'secret:/hostkey:');
    });
  });

  group('assistant settings', () {
    AssistantSettings assistant({
      String model = 'claude-haiku-4-5-20251001',
      String llmApiKeyRef = 'anthropic',
      Map<String, String> apiKeys = const {'anthropic': 'sk-1'},
      int updatedAt = 10,
    }) => AssistantSettings(
          providerKind: 'anthropic',
          baseUrl: 'https://api.anthropic.com',
          model: model,
          llmApiKeyRef: llmApiKeyRef,
          apiKeys: apiKeys,
          updatedAt: updatedAt,
        );

    SyncCoordinator coordinator(
      String deviceId,
      LocalRecordStore local, {
      AssistantSettingsStore? store,
      SnippetStore? snippets,
    }) => SyncCoordinator(
          configStore: InMemoryConfigStore(),
          hostKeyStore: InMemoryHostKeyStore(),
          codec: _sharedCodec,
          local: local,
          deviceId: deviceId,
          assistantStore: store,
          snippetStore: snippets,
        );

    test('the configuration and its keys reach the other device', () async {
      final remote = FakeServer();
      final storeA = InMemoryAssistantSettingsStore(assistant());
      final storeB = InMemoryAssistantSettingsStore();

      await coordinator('A', InMemoryLocalRecordStore(), store: storeA)
          .run(remote);
      await coordinator('B', InMemoryLocalRecordStore(), store: storeB)
          .run(remote);

      final arrived = storeB.settings!;
      expect(arrived.model, 'claude-haiku-4-5-20251001');
      // Without the key, the other device looks configured and answers
      // nothing — which is why they travel inside the sealed record.
      expect(arrived.apiKeys, {'anthropic': 'sk-1'});
      expect(arrived.updatedAt, 10);
    });

    test('a keyring that cannot be read sits the round out', () async {
      // The store contract's most delicate case, and the one
      // `InMemoryAssistantSettingsStore` cannot express: a null read with a
      // *nonzero* stamp means "the keys could not be vouched for right now",
      // not "nothing configured". The round must publish nothing — a keyless
      // copy would carry the keyed record's own stamp and could evict it —
      // while the stamp still refuses an older record pulled in the same
      // round, so the withheld edit is not overwritten either.
      final remote = FakeServer();
      final local = InMemoryLocalRecordStore();
      final withheld = _WithheldKeyStore(assistant(updatedAt: 30));
      await coordinator('A', local, store: withheld).run(remote);

      expect(remote.stored(AssistantSettings.recordId), isNull);
      expect((await local.allRecords()).map((r) => r.id),
          isNot(contains(AssistantSettings.recordId)));

      // And an older record from another device does not slip in behind it.
      final older = FakeServer();
      await coordinator('B', InMemoryLocalRecordStore(),
              store: InMemoryAssistantSettingsStore(
                  assistant(model: 'older', updatedAt: 20)))
          .run(older);
      final mirror = InMemoryLocalRecordStore();
      final pushesBefore = older.pushedRecords;
      await coordinator('A', mirror, store: withheld).run(older);
      expect(withheld.settings.model, 'claude-haiku-4-5-20251001');
      // And nothing of this device's was staged behind that refusal, which
      // the assertion above cannot show. This is the phase where the apply
      // path runs with a record it decided not to adopt: a copy staged there
      // to tell the account about the newer local stamp would be keyless —
      // the keyring is what is withheld — and would carry stamp 30, so it
      // outranks and evicts B's keyed record the moment anything pushes it.
      // The round happens not to push again unless a re-dating asks for it,
      // so the mirror is where the hazard is visible; the server assertion
      // states the outcome that composition currently gives.
      expect(
          (await mirror.allRecords())
              .where((r) => r.id == AssistantSettings.recordId)
              .map((r) => r.deviceId),
          // `equals`, not `everyElement`: the store is a map keyed by record
          // id, so B's pulled copy is the one entry there is — and
          // `everyElement` is satisfied by an empty iterable, which would let
          // a regression that stopped mirroring the record at all pass as
          // "nothing of A's was staged".
          equals(['B']),
          reason: 'a withheld keyring stages no copy of its own, either');
      expect(older.stored(AssistantSettings.recordId)!.deviceId, 'B');
      // The direct signal, which the assertion above cannot give: a round
      // that re-offered the record it just pulled would push B's copy back
      // under B's device id, so the author never changes and only the write
      // itself says it happened.
      expect(older.pushedRecords, pushesBefore);
    });

    test('a store that throws costs the assistant its round, not the round',
        () async {
      // The contract reserves null for "the keys cannot be vouched for", but
      // the app's store reads an OS keyring through a platform channel, and a
      // locked one throws instead. Uncaught, that would abandon collection
      // mid-method and take every record collected after the assistant with
      // it — the rest of the round paying for one keyring.
      final remote = FakeServer();
      final local = InMemoryLocalRecordStore();
      final snippets = InMemorySnippetStore();
      await snippets.putSnippet(const Snippet(
        id: 's1',
        title: 'tail the log',
        body: 'tail -f /var/log/syslog',
        createdAt: 1,
        updatedAt: 5,
      ));

      await coordinator('A', local,
              store: _ThrowingAssistantStore(), snippets: snippets)
          .run(remote);

      expect(remote.stored('snippet:s1'), isNotNull);
      expect(remote.stored(AssistantSettings.recordId), isNull);
      // Staging and pushing are separate steps, so the server assertion above
      // only speaks for this round. A keyless copy staged now would carry the
      // real stamp, ride the next round's push, and evict the keyed record
      // account-wide — which a single-round test can never see from the
      // server side, exactly as the withheld-keyring test two above says.
      expect(
        (await local.allRecords()).map((r) => r.id),
        isNot(contains(AssistantSettings.recordId)),
      );
    });

    test('a store that throws on apply costs the assistant its record, '
        'not the round', () async {
      // The mirror of the collect-side test above, and the answer to the
      // recurring question of why that read needed a guard while this write
      // does not: the apply loop's body is inside a per-record `try` whose
      // `catch` reports through `skip` and moves on, so a keystore write that
      // throws cannot take the records queued behind it. Pinned here rather
      // than argued again — a refactor that hoisted the write out of that
      // `try` would fail this.
      final local = InMemoryLocalRecordStore();
      final snippets = InMemorySnippetStore();
      // Staged first, so a throw that escaped would be in front of the
      // snippet rather than behind it.
      await local.putRemote((await _sharedCodec.encrypt(DecryptedRecord(
        id: AssistantSettings.recordId,
        kind: RecordKind.assistantSettings,
        updatedAt: 900,
        deviceId: 'phone',
        data: assistant(updatedAt: 900).toJson(),
      )))
          .withSeq(1));
      await local.putRemote((await _sharedCodec.encrypt(DecryptedRecord(
        id: 'snippet:s1',
        kind: RecordKind.snippet,
        updatedAt: 5,
        deviceId: 'phone',
        data: const Snippet(
          id: 's1',
          title: 'tail the log',
          body: 'tail -f /var/log/syslog',
          createdAt: 1,
          updatedAt: 5,
        ).toJson(),
      )))
          .withSeq(2));

      await coordinator('A', local,
              store: _ThrowingOnWriteAssistantStore(), snippets: snippets)
          .applyToStores();

      expect(await snippets.getSnippet('s1'), isNotNull,
          reason: 'the record behind the throwing one still applied');
      // And the record it skipped is still staged. Pulls are sequenced, so
      // the account will not hand this one over again: a refactor that
      // consumed a record whose store write threw would lose the edit
      // outright rather than retry it on the next round.
      expect(
        (await local.allRecords()).map((r) => r.id),
        contains(AssistantSettings.recordId),
      );
    });

    test('a device that never edited its assistant publishes nothing',
        () async {
      // Stamp zero means "never edited here", and it is what separates a
      // fresh install from a device with a configuration. Published anyway, a
      // laptop that opted in with nothing configured parks its *shipped
      // defaults* on the account under that stamp.
      final remote = FakeServer();
      final never = InMemoryAssistantSettingsStore(assistant(updatedAt: 0));
      await coordinator('A', InMemoryLocalRecordStore(), store: never)
          .run(remote);
      expect(remote.stored(AssistantSettings.recordId), isNull);
    });

    test('a stamp below zero is refused on both sides too', () async {
      // The viability predicate asked `!= 0`, so a corrupt or clock-wrapped
      // negative stamp passed the publish check — while the apply side's
      // `updatedAt < localStamp` refuses it against any compliant local
      // stamp. Published and permanently unadoptable is exactly the parked
      // junk record the predicate exists to keep off the account.
      final remote = FakeServer();
      final negative = InMemoryAssistantSettingsStore(assistant(updatedAt: -1));
      await coordinator('A', InMemoryLocalRecordStore(), store: negative)
          .run(remote);
      expect(remote.stored(AssistantSettings.recordId), isNull);

      final local = InMemoryLocalRecordStore();
      await local.putRemote(await _sharedCodec.encrypt(DecryptedRecord(
        id: AssistantSettings.recordId,
        kind: RecordKind.assistantSettings,
        updatedAt: 1,
        deviceId: 'B',
        data: assistant(updatedAt: -1).toJson(),
      )));
      final store = InMemoryAssistantSettingsStore(assistant(updatedAt: 0));
      await coordinator('A', local, store: store).applyToStores();
      expect(store.settings!.updatedAt, 0);
    });

    test('a stamp-zero record is refused on apply as well', () async {
      // Both sides, not just the publish one. The stamp comparison refuses a
      // *strictly* older record, so `0 < 0` is false and a stamp-zero record
      // would be adopted by every install still reading zero — which is every
      // one that configured its assistant before this feature existed.
      // Widening the comparison would refuse a legitimate tie; refusing zero
      // by name costs nothing, because no compliant client puts one on the
      // wire (the test above pins that), so two devices cannot tie at it.
      final local = InMemoryLocalRecordStore();
      final configured = InMemoryAssistantSettingsStore(assistant(
        model: 'my-real-model',
        llmApiKeyRef: 'openai',
        apiKeys: const {'openai': 'sk-real'},
        updatedAt: 0,
      ));
      await local.putRemote((await _sharedCodec.encrypt(DecryptedRecord(
        id: AssistantSettings.recordId,
        kind: RecordKind.assistantSettings,
        updatedAt: 0,
        deviceId: 'laptop',
        data: assistant(updatedAt: 0).toJson(),
      )))
          .withSeq(1));

      await coordinator('phone', local, store: configured).applyToStores();

      expect(configured.settings!.model, 'my-real-model',
          reason: 'a stamp-zero record reaching the wire is already a bug; '
              'adopting it over a working configuration is the harm');
      expect(configured.settings!.apiKeys, {'openai': 'sk-real'});
    });

    test('a later edit wins, an unchanged round changes nothing', () async {
      final remote = FakeServer();
      final storeA = InMemoryAssistantSettingsStore(assistant());
      final storeB = InMemoryAssistantSettingsStore();
      await coordinator('A', InMemoryLocalRecordStore(), store: storeA)
          .run(remote);
      await coordinator('B', InMemoryLocalRecordStore(), store: storeB)
          .run(remote);

      storeB.settings = assistant(model: 'gpt-5', updatedAt: 20);
      await coordinator('B', InMemoryLocalRecordStore(), store: storeB)
          .run(remote);
      await coordinator('A', InMemoryLocalRecordStore(), store: storeA)
          .run(remote);
      expect(storeA.settings!.model, 'gpt-5');

      // The timestamp comes from the edit, not from the round, so re-running
      // converges instead of the two devices trading the record forever.
      final pushesBefore = remote.pushedRecords;
      final seqBefore = remote.latestSeq;
      for (var round = 0; round < 3; round++) {
        await coordinator('A', InMemoryLocalRecordStore(), store: storeA)
            .run(remote);
        await coordinator('B', InMemoryLocalRecordStore(), store: storeB)
            .run(remote);
      }
      expect(storeA.settings!.model, 'gpt-5');
      expect(storeB.settings!.model, 'gpt-5');
      expect(storeA.settings!.updatedAt, 20);
      // Not even offered: each round pulls the server's own sequenced copy
      // first, which matches what was collected and clears it. Stamping from
      // the edit rather than from the round is what makes that true — a
      // moving timestamp would win every pull and be pushed every round.
      expect(remote.pushedRecords, pushesBefore);
      expect(remote.latestSeq, seqBefore);
    });

    test('nothing to publish yet is not published', () async {
      // Two fresh installs must not push rival defaults at each other before
      // either has configured anything.
      final remote = FakeServer();
      final local = InMemoryLocalRecordStore();
      await coordinator('A', local, store: InMemoryAssistantSettingsStore())
          .run(remote);
      expect(await local.allRecords(), isEmpty);
      // Both sides: staging and pushing are separate steps, and a record that
      // reached the account without being staged is the same rival default on
      // the account by another route.
      expect(remote.stored(AssistantSettings.recordId), isNull);
    });

    test('a configuration this build could not read is not published',
        () async {
      // The apply side refuses a record with an empty provider as "not a
      // configuration". The same degradation — `fromJson` turning a missing
      // field into '' — can happen to a device's own settings file, and
      // publishing it would park a record no device adopts on the account
      // under this device's stamp, where nothing older can displace it.
      final remote = FakeServer();
      final local = InMemoryLocalRecordStore();
      await coordinator(
        'A',
        local,
        store: InMemoryAssistantSettingsStore(
          assistant().copyWith(providerKind: ''),
        ),
      ).run(remote);
      expect(await local.allRecords(), isEmpty);
      expect(remote.stored(AssistantSettings.recordId), isNull);
    });

    test('a device that has not opted in neither pushes nor adopts', () async {
      final remote = FakeServer();
      final storeA = InMemoryAssistantSettingsStore(assistant());
      await coordinator('A', InMemoryLocalRecordStore(), store: storeA)
          .run(remote);

      // No store means opted out. The record still reaches B's mirror — being
      // opted out is not being blind to it — but there is nothing for the
      // coordinator to apply it into, and B marks nothing dirty of its own, so
      // the account gains no write from a device that never asked to share.
      final local = InMemoryLocalRecordStore();
      final seqBefore = remote.latestSeq;
      // The direct signal beside the indirect one: `latestSeq` only moves
      // when the fake mints a sequence number, so a B that pushed its
      // mirrored copy back would still leave it where it was if the server
      // recognised the record as unchanged.
      final pushesBefore = remote.pushedRecords;
      await coordinator('B', local).run(remote);
      expect(
        (await local.allRecords()).map((r) => r.id),
        contains(AssistantSettings.recordId),
      );
      expect(
        (await local.dirtyRecords()).map((r) => r.id),
        isNot(contains(AssistantSettings.recordId)),
      );
      expect(remote.pushedRecords, pushesBefore);
      expect(remote.latestSeq, seqBefore);
    });

    test('a record with no provider is not a configuration', () async {
      // fromJson degrades a missing field to '' so a record from a newer
      // build stays readable; a provider name is written from an enum and can
      // never legitimately be empty, so an empty one means the payload is not
      // a configuration — and adopting it would leave every device that
      // pulled it with an assistant that answers nothing.
      final local = InMemoryLocalRecordStore();
      await local.putRemote(await _sharedCodec.encrypt(DecryptedRecord(
        id: AssistantSettings.recordId,
        kind: RecordKind.assistantSettings,
        updatedAt: 99,
        deviceId: 'B',
        data: assistant(updatedAt: 99).copyWith(providerKind: '').toJson(),
      )));
      final store = InMemoryAssistantSettingsStore(assistant());
      await coordinator('A', local, store: store).applyToStores();
      expect(store.settings!.providerKind, 'anthropic');
      expect(store.settings!.updatedAt, 10);
      // And it is not marked for pushing onward, which is what would carry a
      // payload this build could not read to every other device.
      expect(
        (await local.dirtyRecords()).map((r) => r.id),
        isNot(contains(AssistantSettings.recordId)),
      );
    });

    test('a pulled record never overwrites a newer local edit', () async {
      // The assistant configuration is edited straight into its store between
      // rounds, so the synced mirror can be older than the store by a whole
      // debounce. A record pulled mid-round wins last-write-wins against that
      // stale mirror while still losing to the store — and applying it would
      // drop the edit, then re-collect and publish the loss.
      final local = InMemoryLocalRecordStore();
      await local.putRemote(await _sharedCodec.encrypt(DecryptedRecord(
        id: AssistantSettings.recordId,
        kind: RecordKind.assistantSettings,
        // Matched to the payload's own stamp, like collectLocal does — the
        // envelope date is derived from it, so a fixture where they disagree
        // is a state production cannot reach.
        updatedAt: 20,
        deviceId: 'B',
        data: assistant(model: 'from-B', updatedAt: 20).toJson(),
      )));
      final store = InMemoryAssistantSettingsStore(
        assistant(model: 'local-edit', updatedAt: 30),
      );

      await coordinator('A', local, store: store).applyToStores();
      expect(store.settings!.model, 'local-edit');
      expect(store.settings!.updatedAt, 30);
    });

    test('a pulled record that ties is still applied', () async {
      // Ties are resolved at the record layer by device id and sequence, so
      // refusing them here would stop two devices ever converging on one.
      final local = InMemoryLocalRecordStore();
      await local.putRemote(await _sharedCodec.encrypt(DecryptedRecord(
        id: AssistantSettings.recordId,
        kind: RecordKind.assistantSettings,
        updatedAt: 30,
        deviceId: 'B',
        data: assistant(model: 'from-B', updatedAt: 30).toJson(),
      )));
      final store = InMemoryAssistantSettingsStore(assistant(updatedAt: 30));

      await coordinator('A', local, store: store).applyToStores();
      expect(store.settings!.model, 'from-B');
    });

    test('a cleared configuration propagates as an edit, not a withdrawal',
        () async {
      // Clearing everything but the provider still publishes, under the new
      // stamp: a store that answered null for it instead would leave the old
      // record standing on the account, and B's next pull would resurrect
      // the model and keys A had just removed.
      final remote = FakeServer();
      final storeA = InMemoryAssistantSettingsStore(assistant());
      await coordinator('A', InMemoryLocalRecordStore(), store: storeA)
          .run(remote);
      final storeB = InMemoryAssistantSettingsStore();
      final localB = InMemoryLocalRecordStore();
      await coordinator('B', localB, store: storeB).run(remote);
      expect(storeB.settings!.model, isNotEmpty);

      // The ref goes with the keys: a cleared configuration that still named
      // one would be a shape no real store produces, since publishing checks
      // that every named key can be read.
      storeA.settings = assistant(
        model: '',
        llmApiKeyRef: '',
        apiKeys: const {},
        updatedAt: 40,
      );
      await coordinator('A', InMemoryLocalRecordStore(), store: storeA)
          .run(remote);
      await coordinator('B', localB, store: storeB).run(remote);

      expect(storeB.settings!.model, '');
      expect(storeB.settings!.apiKeys, isEmpty);
      expect(storeB.settings!.updatedAt, 40);
    });

    test('the keys never reach the server in the clear', () async {
      // The record is the only one that carries API keys, and it carries them
      // whatever `syncSecrets` says — so the seal is the whole protection.
      final remote = FakeServer();
      await coordinator(
        'A',
        InMemoryLocalRecordStore(),
        store: InMemoryAssistantSettingsStore(assistant()),
      ).run(remote);

      final pushed = remote.stored(AssistantSettings.recordId)!;
      final blob = utf8.decode(pushed.blob, allowMalformed: true);
      for (final plaintext in [
        'sk-1',
        'anthropic',
        'claude-haiku-4-5-20251001',
      ]) {
        expect(blob, isNot(contains(plaintext)));
      }
      // And it is the account key that opens it, not something device-local.
      final back = await _sharedCodec.decrypt(pushed);
      expect(back.kind, RecordKind.assistantSettings);
      expect(
        AssistantSettings.fromJson(back.data).apiKeys,
        {'anthropic': 'sk-1'},
      );
    });
  });
}

/// One key for every device in this group: they are one account's devices, so
/// they share a vault key.
final RecordCodec _sharedCodec = RecordCodec(secureRandomBytes(32));

/// A local store that refuses to stage one record, to prove the post-loop
/// re-dating is fail-soft per record like the loop that feeds it.
class _RefusingLocalStore implements LocalRecordStore {
  final LocalRecordStore inner;
  final String refuseId;

  _RefusingLocalStore(this.inner, this.refuseId);

  @override
  Future<void> putLocal(EncryptedRecord record) async {
    if (record.id == refuseId) throw StateError('store is down');
    return inner.putLocal(record);
  }

  @override
  Future<List<EncryptedRecord>> allRecords() => inner.allRecords();
  @override
  Future<EncryptedRecord?> getRecord(String id) => inner.getRecord(id);
  @override
  Future<void> putRemote(EncryptedRecord record) => inner.putRemote(record);
  @override
  Future<List<EncryptedRecord>> dirtyRecords() => inner.dirtyRecords();
  @override
  Future<void> markSynced(String id, int seq) => inner.markSynced(id, seq);
  @override
  Future<int> highWaterSeq() => inner.highWaterSeq();
  @override
  Future<void> setHighWaterSeq(int seq) => inner.setHighWaterSeq(seq);
}

/// A vault whose deletes fail the way a locked OS keyring makes them fail.
class _RefusingVault extends SecretVault {
  int deletesAttempted = 0;

  _RefusingVault(super.store, super.key);

  @override
  Future<void> deleteSecret(String id) async {
    deletesAttempted++;
    throw StateError('keyring locked');
  }
}

/// A store whose keystore read fails the way a real one does — the platform
/// channel behind a locked keyring throws rather than answering null.
class _ThrowingAssistantStore implements AssistantSettingsStore {
  @override
  Future<AssistantSettings?> getAssistantSettings() async =>
      throw StateError('KeyringLocked');

  @override
  Future<int> assistantSettingsUpdatedAt() async => 30;

  @override
  Future<void> putAssistantSettings(AssistantSettings value) async {}
}

/// A store that answers reads but throws on the write, which is what a locked
/// keyring does to the apply path: the stamp comparison in front of it reads
/// fine, and only `putAssistantSettings` reaches the platform channel.
class _ThrowingOnWriteAssistantStore implements AssistantSettingsStore {
  @override
  Future<AssistantSettings?> getAssistantSettings() async => null;

  @override
  Future<int> assistantSettingsUpdatedAt() async => 0;

  @override
  Future<void> putAssistantSettings(AssistantSettings value) async =>
      throw StateError('KeyringLocked');
}

/// A store whose keyring will not answer: the configuration is there and its
/// stamp is real, but nothing can be vouched for this round.
///
/// The in-memory double cannot express this — it returns null only when it has
/// never been set, so its null and its stamp agree — and this combination is
/// exactly the contract [AssistantSettingsStore] documents for a locked
/// keyring. The sibling above is the other half of that contract: a keyring
/// that throws rather than answering at all.
class _WithheldKeyStore implements AssistantSettingsStore {
  _WithheldKeyStore(this.settings);
  AssistantSettings settings;

  @override
  Future<AssistantSettings?> getAssistantSettings() async => null;

  @override
  Future<int> assistantSettingsUpdatedAt() async => settings.updatedAt;

  @override
  Future<void> putAssistantSettings(AssistantSettings value) async =>
      settings = value;
}
