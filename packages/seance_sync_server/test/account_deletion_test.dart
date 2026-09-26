import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const _username = 'alice';

Future<String> _seed(
  SqliteStorage storage, {
  String username = _username,
}) async {
  await storage.createAccount(
    Account(
      username: username,
      authVerifierHash: 'hash',
      verifierSalt: 'salt',
      argonSalt: 'argon',
      argonParams: const Argon2Params(),
    ),
  );
  await storage.pushRecords(username, [
    EncryptedRecord(
      id: 'record',
      updatedAt: 1,
      deviceId: 'device',
      deleted: false,
      seq: null,
      blob: Uint8List.fromList([1, 2, 3]),
    ),
  ]);
  return storage.createToken(username);
}

Future<void> _expectAccountIntact(
  SqliteStorage storage,
  String token, {
  String username = _username,
}) async {
  expect(await storage.getAccount(username), isNotNull);
  expect(await storage.usernameForToken(token), username);
  expect(await storage.latestSeq(username), 1);
  final records = await storage.recordsSince(username, 0);
  expect(records.single.id, 'record');
  expect(records.single.blob, [1, 2, 3]);
}

Future<void> _expectAccountDeleted(SqliteStorage storage, String token) async {
  expect(await storage.getAccount(_username), isNull);
  expect(await storage.usernameForToken(token), isNull);
  expect(await storage.latestSeq(_username), 0);
  expect(await storage.recordsSince(_username, 0), isEmpty);
}

void main() {
  for (final table in ['accounts', 'tokens', 'records', 'seqs']) {
    test('failed $table deletion rolls back every account row', () async {
      final database = sqlite3.openInMemory();
      final storage = SqliteStorage(database);
      addTearDown(storage.close);
      final token = await _seed(storage);
      database.execute('''
        CREATE TRIGGER fail_delete BEFORE DELETE ON $table
        BEGIN SELECT RAISE(ABORT, 'injected deletion failure'); END;
      ''');

      await expectLater(
        storage.deleteAccount(_username),
        throwsA(isA<SqliteException>()),
      );
      await _expectAccountIntact(storage, token);
      expect(database.autocommit, isTrue);

      final response =
          await SyncServer(
            storage: storage,
            settings: ServerSettings(),
          ).handler(
            Request(
              'DELETE',
              Uri.parse('http://localhost/v1/account'),
              headers: {'authorization': 'Bearer $token'},
            ),
          );
      expect(response.statusCode, 500);
      final error = jsonDecode(await response.readAsString());
      expect(error['error'], 'internal_error');
      expect(error.toString(), isNot(contains('injected deletion failure')));
      await _expectAccountIntact(storage, token);

      database.execute('DROP TRIGGER fail_delete');
      await storage.deleteAccount(_username);
      await _expectAccountDeleted(storage, token);
    });
  }

  test(
    'successful deletion survives reopen and leaves other accounts intact',
    () async {
      final directory = Directory.systemTemp.createTempSync('seance-delete-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/sync.sqlite';
      var storage = SqliteStorage.open(path);
      addTearDown(() => storage.close());
      final token = await _seed(storage);
      final otherToken = await _seed(storage, username: 'bob');
      await storage.deleteAccount(_username);
      storage.close();
      storage = SqliteStorage.open(path);

      await _expectAccountDeleted(storage, token);
      await _expectAccountIntact(storage, otherToken, username: 'bob');
    },
  );

  test(
    'contended deletion returns 503, preserves data and succeeds on retry',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'seance-delete-busy-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/sync.sqlite';
      final storage = SqliteStorage.open(path);
      addTearDown(storage.close);
      final token = await _seed(storage);
      final writer = sqlite3.open(path);
      addTearDown(writer.dispose);
      writer.execute('BEGIN IMMEDIATE');
      final handler = SyncServer(
        storage: storage,
        settings: ServerSettings(),
      ).handler;
      Future<Response> delete() async => handler(
        Request(
          'DELETE',
          Uri.parse('http://localhost/v1/account'),
          headers: {'authorization': 'Bearer $token'},
        ),
      );

      final blocked = await delete();
      expect(blocked.statusCode, 503);
      expect(jsonDecode(await blocked.readAsString())['error'], 'storage_busy');
      await _expectAccountIntact(storage, token);

      writer.execute('ROLLBACK');
      expect((await delete()).statusCode, 200);
      await _expectAccountDeleted(storage, token);
      expect((await delete()).statusCode, 401);
    },
  );
}
