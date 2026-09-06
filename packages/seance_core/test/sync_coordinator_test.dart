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
      String device,
    ) =>
        SyncCoordinator(
          configStore: configs,
          hostKeyStore: InMemoryHostKeyStore(),
          codec: codec,
          local: InMemoryLocalRecordStore(),
          deviceId: device,
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

    test('the retraction is dated at the exclusion, not at the round',
        () async {
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

      await SyncCoordinator(
        configStore: configs,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'A',
        syncSecrets: true,
        secretVault: vault,
      ).applyToStores();

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
      // …and a second device that has not seen it yet, still pushing a
      // copy of its own.
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
      await coord(codec, cfgA, 'A').run(remote);
      await coord(codec, cfgB, 'B').run(remote);
      expect(await cfgB.getServer('s1'), isNull);
      expect((await cfgA.getServer('s1'))!.label, 'alpha');
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

      final coordinator = SyncCoordinator(
        configStore: configs,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'A',
      );
      // 'good' is revived even though 'bad' threw, and the count reports only
      // what actually landed — the caller spends its extra push round on a
      // real re-dating rather than on a batch that failed.
      expect(await coordinator.applyToStores(), 1);
      expect((await configs.getServer('good'))!.updatedAt, 21);
      expect(await local.getRecord('good'), isNotNull);
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

      await SyncCoordinator(
        configStore: configs,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'A',
      ).applyToStores();

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

      final coordinator = SyncCoordinator(
        configStore: configs,
        hostKeyStore: InMemoryHostKeyStore(),
        codec: codec,
        local: local,
        deviceId: 'A',
      );
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
}

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
