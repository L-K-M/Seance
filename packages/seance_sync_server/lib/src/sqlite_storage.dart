import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import 'storage.dart';

enum _TransactionMode { read, write }

/// SQLite-backed [Storage] for production. Single file, no server process — the
/// whole deployment is this binary plus a `.sqlite` file. All record blobs are
/// already end-to-end encrypted; this layer only shuffles opaque bytes.
class SqliteStorage implements Storage {
  final Database _connection;
  StorageUnavailableException? _failure;

  SqliteStorage(this._connection) {
    _migrate();
  }

  Database get _db {
    final failure = _failure;
    if (failure != null) throw failure;
    return _connection;
  }

  /// Open (or create) the database at [path]. Use `:memory:` for ephemeral.
  factory SqliteStorage.open(String path) =>
      SqliteStorage(sqlite3.open(path));

  void _migrate() {
    _db.execute('PRAGMA journal_mode=WAL;');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS accounts (
        username TEXT PRIMARY KEY,
        auth_verifier_hash TEXT NOT NULL,
        verifier_salt TEXT NOT NULL,
        argon_salt TEXT NOT NULL,
        argon_params TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tokens (
        token TEXT PRIMARY KEY,
        username TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS records (
        username TEXT NOT NULL,
        id TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        device_id TEXT NOT NULL,
        deleted INTEGER NOT NULL,
        seq INTEGER NOT NULL,
        blob BLOB NOT NULL,
        PRIMARY KEY (username, id)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS seqs (
        username TEXT PRIMARY KEY,
        value INTEGER NOT NULL
      );
    ''');
    _db.execute(
        'CREATE INDEX IF NOT EXISTS records_seq ON records(username, seq);');
  }

  @override
  Future<Account?> getAccount(String username) async {
    final rows = _db
        .select('SELECT * FROM accounts WHERE username = ?', [username]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Account(
      username: r['username'] as String,
      authVerifierHash: r['auth_verifier_hash'] as String,
      verifierSalt: r['verifier_salt'] as String,
      argonSalt: r['argon_salt'] as String,
      argonParams: Argon2Params.fromJson(
          (jsonDecode(r['argon_params'] as String) as Map).cast()),
    );
  }

  @override
  Future<void> createAccount(Account account) async {
    _db.execute(
      'INSERT INTO accounts (username, auth_verifier_hash, verifier_salt, argon_salt, argon_params) VALUES (?, ?, ?, ?, ?)',
      [
        account.username,
        account.authVerifierHash,
        account.verifierSalt,
        account.argonSalt,
        jsonEncode(account.argonParams.toJson()),
      ],
    );
    _db.execute('INSERT OR IGNORE INTO seqs (username, value) VALUES (?, 0)',
        [account.username]);
  }

  @override
  Future<void> deleteAccount(String username) async {
    _db.execute('DELETE FROM accounts WHERE username = ?', [username]);
    _db.execute('DELETE FROM tokens WHERE username = ?', [username]);
    _db.execute('DELETE FROM records WHERE username = ?', [username]);
    _db.execute('DELETE FROM seqs WHERE username = ?', [username]);
  }

  @override
  Future<String> createToken(String username) async {
    final token = base64Url.encode(secureRandomBytes(32));
    _db.execute('INSERT INTO tokens (token, username) VALUES (?, ?)',
        [token, username]);
    return token;
  }

  @override
  Future<String?> usernameForToken(String token) async {
    final rows =
        _db.select('SELECT username FROM tokens WHERE token = ?', [token]);
    return rows.isEmpty ? null : rows.first['username'] as String;
  }

  @override
  Future<PushResponse> pushRecords(
      String username, List<EncryptedRecord> records) async =>
      _transaction(_TransactionMode.write, () {
        final results = <PushResult>[];
        for (final incoming in records) {
          final existing = _getRecord(username, incoming.id);
          if (existing != null &&
              !identical(Lww.resolve(existing, incoming), incoming)) {
            results.add(PushResult(
                id: incoming.id, seq: existing.seq ?? 0, accepted: false));
            continue;
          }

          final seq = _nextSeq(username);
          _putRecord(username, incoming.withSeq(seq));
          results.add(PushResult(id: incoming.id, seq: seq, accepted: true));
        }
        return PushResponse(results: results, latestSeq: _latestSeq(username));
      });

  @override
  Future<PullResponse> pullSnapshot(String username, int since) async =>
      _transaction(_TransactionMode.read, () {
        final watermark = _latestSeq(username);
        return PullResponse(
          records: _recordsSince(username, since, through: watermark),
          latestSeq: watermark,
        );
      });

  T _transaction<T>(_TransactionMode mode, T Function() action) {
    // No awaits while the connection owns a transaction. Acquire the write
    // lock before comparing LWW so another process cannot commit a stale winner.
    _begin(mode);
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (e) {
      _rollback(e);
      final failure = _failure;
      if (failure != null) throw failure;
      if (_isBusy(e)) throw const StorageBusyException();
      rethrow;
    }
  }

  void _begin(_TransactionMode mode) {
    try {
      _db.execute(mode == _TransactionMode.write ? 'BEGIN IMMEDIATE' : 'BEGIN');
    } on SqliteException catch (e) {
      if (_isBusy(e)) throw const StorageBusyException();
      rethrow;
    }
  }

  static bool _isBusy(Object error) => error is SqliteException &&
      (error.resultCode == SqlError.SQLITE_BUSY ||
          error.resultCode == SqlError.SQLITE_LOCKED);

  static String _diagnosticCause(Object error) => error is SqliteException
      ? 'SQLite ${error.extendedResultCode}'
      : error.runtimeType.toString();

  void _rollback(Object cause) {
    final Object cleanupCause;
    try {
      // SQLite may already have rolled back after a trigger or storage error.
      if (!_db.autocommit) _db.execute('ROLLBACK');
      return;
    } catch (e) {
      cleanupCause = e;
    }

    // Never reuse a connection whose transaction state is uncertain.
    _failure = StorageUnavailableException(cause: cause);
    try {
      // Log types/codes, not SQL, parameters, messages or ciphertext.
      stderr.writeln('Transaction failed (${_diagnosticCause(cause)}); '
          'cleanup failed (${_diagnosticCause(cleanupCause)}). $_failure');
    } catch (_) {
      // Diagnostics must not replace the original failure.
    }

    try {
      _connection.dispose();
    } catch (_) {
      // Preserve the original write/commit failure, not a cleanup exception.
    }
  }

  @override
  Future<EncryptedRecord?> getRecord(String username, String id) async =>
      _getRecord(username, id);

  EncryptedRecord? _getRecord(String username, String id) {
    final rows = _db.select(
        'SELECT * FROM records WHERE username = ? AND id = ?', [username, id]);
    return rows.isEmpty ? null : _rowToRecord(rows.first);
  }

  @override
  Future<void> putRecord(String username, EncryptedRecord record) async =>
      _putRecord(username, record);

  void _putRecord(String username, EncryptedRecord record) {
    _db.execute(
      '''INSERT INTO records (username, id, updated_at, device_id, deleted, seq, blob)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(username, id) DO UPDATE SET
           updated_at=excluded.updated_at, device_id=excluded.device_id,
           deleted=excluded.deleted, seq=excluded.seq, blob=excluded.blob''',
      [
        username,
        record.id,
        record.updatedAt,
        record.deviceId,
        record.deleted ? 1 : 0,
        record.seq ?? 0,
        record.blob,
      ],
    );
  }

  @override
  Future<List<EncryptedRecord>> recordsSince(
          String username, int since) async =>
      _recordsSince(username, since);

  List<EncryptedRecord> _recordsSince(String username, int since,
      {int? through}) {
    final rows = _db.select(
        through == null
            ? 'SELECT * FROM records WHERE username = ? AND seq > ? '
                'ORDER BY seq ASC'
            : 'SELECT * FROM records WHERE username = ? AND seq > ? '
                'AND seq <= ? ORDER BY seq ASC',
        [username, since, if (through != null) through]);
    return rows.map(_rowToRecord).toList();
  }

  @override
  Future<int> nextSeq(String username) async => _nextSeq(username);

  int _nextSeq(String username) {
    _db.execute(
      '''INSERT INTO seqs (username, value) VALUES (?, 1)
         ON CONFLICT(username) DO UPDATE SET value = value + 1''',
      [username],
    );
    final rows =
        _db.select('SELECT value FROM seqs WHERE username = ?', [username]);
    return rows.first['value'] as int;
  }

  @override
  Future<int> latestSeq(String username) async => _latestSeq(username);

  int _latestSeq(String username) {
    final rows =
        _db.select('SELECT value FROM seqs WHERE username = ?', [username]);
    return rows.isEmpty ? 0 : rows.first['value'] as int;
  }

  EncryptedRecord _rowToRecord(Row r) => EncryptedRecord(
        id: r['id'] as String,
        updatedAt: r['updated_at'] as int,
        deviceId: r['device_id'] as String,
        deleted: (r['deleted'] as int) != 0,
        seq: r['seq'] as int,
        blob: r['blob'] is Uint8List
            ? r['blob'] as Uint8List
            : Uint8List.fromList((r['blob'] as List).cast<int>()),
      );

  void close() => _connection.dispose();
}
