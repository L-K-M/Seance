import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// In-memory stand-in for the server (same as sync_test's), reused here.
class FakeServer implements SyncApi {
  final Map<String, EncryptedRecord> _store = {};
  int _seq = 0;
  int pushedRecords = 0;

  @override
  Future<PullResponse> pull({required int since}) async {
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
        for (final record in await local.allRecords()) record.id: record.deleted,
      };
    }

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
        SyncCoordinator(
          configStore: configs,
          hostKeyStore: InMemoryHostKeyStore(),
          codec: codec,
          local: local,
          deviceId: 'A',
        ),
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

    test('the retraction is dated at the exclusion, not at the round', () async {
      final codec = RecordCodec(secureRandomBytes(32));
      final configs = InMemoryConfigStore();
      final local = InMemoryLocalRecordStore();
      await configs.putServer(
        server('local-only', 'beta', 4242)
            .copyWith(excludeFromSync: true, updatedAt: 4243),
      );
      final coordinator = SyncCoordinator(
        configStore: configs,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'A',
      );

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
      SyncCoordinator coordinator(LocalRecordStore local) => SyncCoordinator(
            configStore: configs,
            hostKeyStore: InMemoryHostKeyStore(),
            codec: codec,
            local: local,
            deviceId: 'A',
            syncSecrets: true,
            secretVault: vault,
          );

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
    });

    test('an excluded server keeps its credential while others lose theirs',
        () async {
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
        server('excluded', 'alpha', 20)
            .copyWith(secretRef: 'sec-kept', excludeFromSync: true, updatedAt: 21),
      );
      final local = InMemoryLocalRecordStore();
      // This device's own retraction, and one from a device whose server the
      // matching config tombstone has already removed — a retraction only
      // honoured for the local device would leave that one orphaned forever.
      for (final (id, from) in [
        ('secret:sec-kept', 'A'),
        ('secret:sec-orphan', 'B'),
      ]) {
        await local.putRemote(await codec.encrypt(DecryptedRecord(
          id: id,
          kind: RecordKind.secret,
          updatedAt: 20,
          deviceId: from,
          deleted: true,
        )));
      }

      await SyncCoordinator(
        configStore: configs,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'A',
        syncSecrets: true,
        secretVault: vault,
      ).applyToStores();

      // Still referenced by the local-only server, so it stays — this device
      // has to keep working.
      expect((await vault.getSecret('sec-kept'))?.value, 'local-only');
      // Nothing names it any more, so it goes rather than lingering as an
      // orphan no server list can show.
      expect(await vault.getSecret('sec-orphan'), isNull);
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

      await SyncCoordinator(
        configStore: configs,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'A',
        syncSecrets: true,
        secretVault: vault,
      ).applyToStores();

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
      expect(
        synced.copyWith(excludeFromSync: true, updatedAt: 11).excludeFromSync,
        isTrue,
      );
      // Restating the value it already has is not a change and needs nothing.
      expect(synced.copyWith(excludeFromSync: false).excludeFromSync, isFalse);
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
        excluded.copyWith(excludeFromSync: false, updatedAt: 12).excludeFromSync,
        isFalse,
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
      SyncCoordinator coordinator(LocalRecordStore local) => SyncCoordinator(
            configStore: configs,
            hostKeyStore: InMemoryHostKeyStore(),
            codec: codec,
            local: local,
            deviceId: 'A',
            syncSecrets: true,
            secretVault: vault,
          );

      final local = InMemoryLocalRecordStore();
      final collectedRecords = await collected(coordinator(local), local);
      // Pushed live for the server that still syncs, not tombstoned for the
      // one that no longer does: a tombstone dated at the exclusion would beat
      // that server's own push of the same id every round, ending credential
      // sync for a server the user never excluded.
      expect(collectedRecords['secret:shared'], isFalse);

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
        SyncCoordinator(
          configStore: configs,
          hostKeyStore: hostKeys,
          codec: codec,
          local: local,
          deviceId: 'A',
        ),
        local,
      );
      expect(records.containsKey('hostkey:beta.example.com:22'), isTrue);

      // Drop the syncing server and the same pin is withheld.
      await configs.deleteServer('shared');
      final second = InMemoryLocalRecordStore();
      records = await collected(
        SyncCoordinator(
          configStore: configs,
          hostKeyStore: hostKeys,
          codec: codec,
          local: second,
          deviceId: 'A',
        ),
        second,
      );
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

      // This device's own retraction, come back from the server sequenced…
      await local.putRemote(await codec.encrypt(const DecryptedRecord(
        id: 'local-only',
        kind: RecordKind.serverConfig,
        updatedAt: 20,
        deviceId: 'A',
        deleted: true,
      )));
      // …and a second device that has not seen it yet, still pushing its copy.
      await local.putRemote(await codec.encrypt(DecryptedRecord(
        id: 'local-only',
        kind: RecordKind.serverConfig,
        updatedAt: 99,
        deviceId: 'B',
        data: server('local-only', 'renamed-elsewhere', 99).toJson(),
      )));

      final rescheduled = await SyncCoordinator(
        configStore: configs,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'A',
      ).applyToStores();

      final after = await configs.getServer('local-only');
      expect(after, isNotNull, reason: 'the retraction must not delete it here');
      expect(after!.label, 'beta');
      expect(after.excludeFromSync, isTrue);

      // The copy at 99 could only get here by beating the tombstone dated 21,
      // so the retraction is re-dated to outrank it instead of being re-minted
      // at the same losing date every round.
      expect(rescheduled, 1);
      final staged = await codec.decrypt((await local.getRecord('local-only'))!);
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
      SyncCoordinator coord(ConfigStore configs, String device) =>
          SyncCoordinator(
            configStore: configs,
            hostKeyStore: InMemoryHostKeyStore(),
            codec: codec,
            local: InMemoryLocalRecordStore(),
            deviceId: device,
          );

      await cfgA.putServer(server('s1', 'alpha', 10));
      await coord(cfgA, 'A').run(remote);
      await coord(cfgB, 'B').run(remote);

      // B renames it, stamping a timestamp A's clock has not reached yet.
      await cfgB.putServer(server('s1', 'renamed', 5000));
      await coord(cfgB, 'B').run(remote);

      // A excludes it before pulling that rename: 31 is A's honest "now".
      await cfgA.putServer(
        server('s1', 'alpha', 30).copyWith(excludeFromSync: true, updatedAt: 31),
      );
      await coord(cfgA, 'A').run(remote);

      // A keeps its own copy, and B loses it on its next round all the same.
      expect((await cfgA.getServer('s1'))!.excludeFromSync, isTrue);
      await coord(cfgB, 'B').run(remote);
      expect(await cfgB.getServer('s1'), isNull);

      // And it settles there: nothing re-dates once no live copy comes back.
      await coord(cfgA, 'A').run(remote);
      await coord(cfgB, 'B').run(remote);
      expect(await cfgB.getServer('s1'), isNull);
      expect((await cfgA.getServer('s1'))!.label, 'alpha');
    });

    test('re-including a server supersedes its tombstone', () async {
      // The one transition where a tombstone is already staged locally: the
      // live record has to replace it rather than be skipped for being deleted.
      final remote = FakeServer();
      final codec = RecordCodec(secureRandomBytes(32));

      final cfgA = InMemoryConfigStore();
      final cfgB = InMemoryConfigStore();
      SyncCoordinator coord(ConfigStore configs, String device) =>
          SyncCoordinator(
            configStore: configs,
            hostKeyStore: InMemoryHostKeyStore(),
            codec: codec,
            local: InMemoryLocalRecordStore(),
            deviceId: device,
          );

      await cfgA.putServer(server('s1', 'alpha', 10)
          .copyWith(excludeFromSync: true, updatedAt: 11));
      await coord(cfgA, 'A').run(remote);
      await coord(cfgB, 'B').run(remote);
      expect(await cfgB.getServer('s1'), isNull);

      await cfgA.putServer((await cfgA.getServer('s1'))!
          .copyWith(excludeFromSync: false, updatedAt: 30));
      await coord(cfgA, 'A').run(remote);
      await coord(cfgB, 'B').run(remote);

      final revived = await cfgB.getServer('s1');
      expect(revived, isNotNull, reason: 're-including must beat the tombstone');
      expect(revived!.label, 'alpha');
      expect(revived.excludeFromSync, isFalse);
    });

    test('a vault that refuses a tombstone does not abandon the batch',
        () async {
      // The vault throws when the OS keyring is locked, and the tombstone
      // stays pending on the server, so an unguarded delete would fail every
      // round from then on — sync would look permanently broken.
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
      expect(vault.deletesAttempted, 1);
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
        server('s1', 'alpha', 30).copyWith(excludeFromSync: true, updatedAt: 31),
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
