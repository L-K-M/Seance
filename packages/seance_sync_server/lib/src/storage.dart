import 'dart:convert';

import 'package:seance_protocol/seance_protocol.dart';

/// A registered account. The server holds only a salted *hash* of the auth
/// verifier plus the non-secret KDF salt/params a new device needs. It never
/// sees the vault key or any plaintext.
class Account {
  final String username;
  final String authVerifierHash; // base64 of sha256(verifierSalt || verifier)
  final String verifierSalt; // base64
  final String argonSalt; // base64, echoed back at prelogin
  final Argon2Params argonParams;

  const Account({
    required this.username,
    required this.authVerifierHash,
    required this.verifierSalt,
    required this.argonSalt,
    required this.argonParams,
  });

  Map<String, dynamic> toJson() => {
        'username': username,
        'authVerifierHash': authVerifierHash,
        'verifierSalt': verifierSalt,
        'argonSalt': argonSalt,
        'argonParams': argonParams.toJson(),
      };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        username: json['username'] as String,
        authVerifierHash: json['authVerifierHash'] as String,
        verifierSalt: json['verifierSalt'] as String,
        argonSalt: json['argonSalt'] as String,
        argonParams:
            Argon2Params.fromJson((json['argonParams'] as Map).cast()),
      );
}

/// Persistence for the server. Records are stored as opaque [EncryptedRecord]s
/// (their `blob` is end-to-end encrypted and their `seq` is server-assigned).
/// Implemented in memory (tests) and over SQLite (production).
abstract class Storage {
  Future<Account?> getAccount(String username);
  Future<void> createAccount(Account account);
  Future<void> deleteAccount(String username);

  /// Create and persist a bearer token for [username]; returns the token.
  Future<String> createToken(String username);
  Future<String?> usernameForToken(String token);

  Future<EncryptedRecord?> getRecord(String username, String id);

  /// Store [record] (which must have a non-null seq) as the current version.
  Future<void> putRecord(String username, EncryptedRecord record);

  /// Records with seq strictly greater than [since], in ascending seq order.
  Future<List<EncryptedRecord>> recordsSince(String username, int since);

  /// Allocate the next monotonic sequence number for [username].
  Future<int> nextSeq(String username);
  Future<int> latestSeq(String username);
}

class InMemoryStorage implements Storage {
  final Map<String, Account> _accounts = {};
  final Map<String, String> _tokens = {}; // token -> username
  final Map<String, Map<String, EncryptedRecord>> _records = {};
  final Map<String, int> _seq = {};

  @override
  Future<Account?> getAccount(String username) async => _accounts[username];

  @override
  Future<void> createAccount(Account account) async {
    _accounts[account.username] = account;
    _records[account.username] = {};
    _seq[account.username] = 0;
  }

  @override
  Future<void> deleteAccount(String username) async {
    _accounts.remove(username);
    _records.remove(username);
    _seq.remove(username);
    _tokens.removeWhere((_, u) => u == username);
  }

  @override
  Future<String> createToken(String username) async {
    final token = base64Url.encode(secureRandomBytes(32));
    _tokens[token] = username;
    return token;
  }

  @override
  Future<String?> usernameForToken(String token) async => _tokens[token];

  @override
  Future<EncryptedRecord?> getRecord(String username, String id) async =>
      _records[username]?[id];

  @override
  Future<void> putRecord(String username, EncryptedRecord record) async {
    (_records[username] ??= {})[record.id] = record;
  }

  @override
  Future<List<EncryptedRecord>> recordsSince(String username, int since) async {
    final all = _records[username]?.values ?? const <EncryptedRecord>[];
    final list = all.where((r) => (r.seq ?? 0) > since).toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return list;
  }

  @override
  Future<int> nextSeq(String username) async {
    final next = (_seq[username] ?? 0) + 1;
    _seq[username] = next;
    return next;
  }

  @override
  Future<int> latestSeq(String username) async => _seq[username] ?? 0;
}
