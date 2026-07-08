import 'dart:convert';
import 'dart:typed_data';

/// The category of a synced record. The kind travels *inside* the encrypted
/// payload, not in the envelope, so the server cannot even tell a server-config
/// from a stored secret.
enum RecordKind { serverConfig, hostKey, secret, snippet }

RecordKind recordKindFromName(String name) =>
    RecordKind.values.firstWhere((k) => k.name == name,
        orElse: () => RecordKind.serverConfig);

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
