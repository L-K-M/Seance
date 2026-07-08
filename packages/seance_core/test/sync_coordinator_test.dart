import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// In-memory stand-in for the server (same as sync_test's), reused here.
class FakeServer implements SyncApi {
  final Map<String, EncryptedRecord> _store = {};
  int _seq = 0;

  @override
  Future<PullResponse> pull({required int since}) async {
    final records = _store.values.where((r) => (r.seq ?? 0) > since).toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return PullResponse(records: records, latestSeq: _seq);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
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
}
