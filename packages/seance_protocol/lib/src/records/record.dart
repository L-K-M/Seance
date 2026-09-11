import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:logging/logging.dart';

const String _recordLoggerName = 'seance_protocol.records';

final Logger _log = Logger(_recordLoggerName);

/// The category of a synced record. The kind travels *inside* the encrypted
/// payload, not in the envelope, so the server cannot even tell a server-config
/// from a stored secret.
/// A build that does not know a kind name resolves it to [unknown] through
/// [recordKindFromName], and every apply path skips such a record rather than
/// deleting or rewriting it — which is what lets a new kind roll out before
/// every device is upgraded. Matched by name, never by `index`: a kind added
/// in the middle renumbers everything after it, so an ordinal persisted
/// anywhere would decode as a different kind.
enum RecordKind {
  serverConfig,
  hostKey,
  secret,
  snippet,
  bookmark,
  assistantSettings,
  unknown,
}

RecordKind recordKindFromName(String name) => RecordKind.values.firstWhere(
  (k) => k.name == name,
  orElse: () {
    final message =
        'recordKindFromName: unknown kind "$name" '
        '(legacy or newer-schema record)';

    // Keep the library stream testable and surface it in Séance diagnostics.
    _log.fine(message);
    developer.log(message, name: _recordLoggerName, level: Level.FINE.value);
    return RecordKind.unknown;
  },
);

/// A record after decryption: application-level data the client works with.
class DecryptedRecord {
  final String id;
  final RecordKind kind;
  final int updatedAt;
  final String deviceId;
  final bool deleted;
  final Map<String, dynamic> data;

  const DecryptedRecord({
    required this.id,
    required this.kind,
    required this.updatedAt,
    required this.deviceId,
    this.deleted = false,
    this.data = const {},
  });

  DecryptedRecord tombstone({required int updatedAt, required String deviceId}) =>
      DecryptedRecord(
        id: id,
        kind: kind,
        updatedAt: updatedAt,
        deviceId: deviceId,
        deleted: true,
        data: const {},
      );
}

/// A record as it lives on the wire and in the server's database: an opaque,
/// end-to-end-encrypted [blob] plus the minimum metadata needed to sync and
/// resolve conflicts. [seq] is assigned by the server on upsert and is null for
/// a record the client has not yet pushed.
class EncryptedRecord {
  final String id;
  final int updatedAt;
  final String deviceId;
  final bool deleted;
  final int? seq;

  /// `nonce || ciphertext || mac`. Empty for a tombstone.
  final Uint8List blob;

  const EncryptedRecord({
    required this.id,
    required this.updatedAt,
    required this.deviceId,
    required this.deleted,
    required this.seq,
    required this.blob,
  });

  /// A tombstone: the deletion of [id], carrying no payload. Identity and date
  /// are all a delete needs — [RecordCodec] leaves the empty [blob] unsealed, so
  /// no vault key is required to mint one — and [seq] stays null until the
  /// server assigns one on push.
  EncryptedRecord.tombstone({
    required this.id,
    required this.updatedAt,
    required this.deviceId,
  })  : deleted = true,
        seq = null,
        blob = Uint8List(0);

  EncryptedRecord withSeq(int newSeq) => EncryptedRecord(
        id: id,
        updatedAt: updatedAt,
        deviceId: deviceId,
        deleted: deleted,
        seq: newSeq,
        blob: blob,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'updatedAt': updatedAt,
        'deviceId': deviceId,
        'deleted': deleted,
        if (seq != null) 'seq': seq,
        'blob': base64.encode(blob),
      };

  factory EncryptedRecord.fromJson(Map<String, dynamic> json) =>
      EncryptedRecord(
        id: json['id'] as String,
        updatedAt: (json['updatedAt'] as num).toInt(),
        deviceId: json['deviceId'] as String,
        deleted: json['deleted'] as bool? ?? false,
        seq: (json['seq'] as num?)?.toInt(),
        blob: base64.decode(json['blob'] as String? ?? ''),
      );
}
