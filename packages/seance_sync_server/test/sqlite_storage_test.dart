import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:test/test.dart';

/// Exercises the real SQLite storage backend (libsqlite3 is available in CI and
/// on dev machines). Verifies the same contract the in-memory store satisfies,
/// plus durability across a close/reopen.
void main() {
  Account account(String user) => Account(
        username: user,
        authVerifierHash: 'hash',
        verifierSalt: 'salt',
        argonSalt: 'asalt',
        argonParams: const Argon2Params(),
      );

  EncryptedRecord rec(String id, int seq, int updatedAt) => EncryptedRecord(
        id: id,
        updatedAt: updatedAt,
        deviceId: 'd',
        deleted: false,
        seq: seq,
        blob: Uint8List.fromList([1, 2, 3, seq]),
      );

  test('account, token, and record round-trips in :memory:', () async {
    final s = SqliteStorage.open(':memory:');
    await s.createAccount(account('alice'));
    expect((await s.getAccount('alice'))!.argonSalt, 'asalt');

    final token = await s.createToken('alice');
    expect(await s.usernameForToken(token), 'alice');

    expect(await s.nextSeq('alice'), 1);
    expect(await s.nextSeq('alice'), 2);

    await s.putRecord('alice', rec('a', 1, 10));
    await s.putRecord('alice', rec('b', 2, 11));
    final since0 = await s.recordsSince('alice', 0);
    expect(since0.map((r) => r.id), ['a', 'b']);
    final since1 = await s.recordsSince('alice', 1);
    expect(since1.map((r) => r.id), ['b']);
    expect((await s.getRecord('alice', 'a'))!.blob, [1, 2, 3, 1]);

    await s.deleteAccount('alice');
    expect(await s.getAccount('alice'), isNull);
    expect(await s.recordsSince('alice', 0), isEmpty);
    s.close();
  });

  test('upsert replaces an existing record in place', () async {
    final s = SqliteStorage.open(':memory:');
    await s.createAccount(account('bob'));
    await s.putRecord('bob', rec('x', 1, 10));
    await s.putRecord('bob', rec('x', 2, 20)); // same id, newer
    final all = await s.recordsSince('bob', 0);
    expect(all, hasLength(1));
    expect(all.single.seq, 2);
    expect(all.single.updatedAt, 20);
    s.close();
  });

  test('data persists across a close and reopen', () async {
    final dir = Directory.systemTemp.createTempSync('seance_sqlite_test');
    final path = '${dir.path}/seance.sqlite';
    try {
      final s1 = SqliteStorage.open(path);
      await s1.createAccount(account('carol'));
      final seq = await s1.nextSeq('carol'); // advance the counter like _push
      await s1.putRecord('carol', rec('r', seq, 42));
      s1.close();

      // Reopen the same file in a fresh instance.
      final s2 = SqliteStorage.open(path);
      expect((await s2.getAccount('carol'))!.username, 'carol');
      final records = await s2.recordsSince('carol', 0);
      expect(records.single.id, 'r');
      expect(records.single.updatedAt, 42);
      // Sequence counter also survived.
      expect(await s2.latestSeq('carol'), 1);
      s2.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
