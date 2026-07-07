import 'dart:typed_data';

import '../crypto/vault.dart';
import 'record.dart';

/// Encrypts [DecryptedRecord]s into [EncryptedRecord]s and back, using the
/// device's vault key. This is the only bridge between plaintext application
/// data and what the sync server ever sees.
///
/// A freshly encrypted record has `seq == null`: the sequence number is
/// assigned by the server on upsert, and the client's sync engine tracks the
/// high-water mark separately from the record itself.
class RecordCodec {
  final List<int> vaultKey;
  const RecordCodec(this.vaultKey);

  Future<EncryptedRecord> encrypt(DecryptedRecord record) async {
    // Tombstones carry no payload — nothing to encrypt or leak.
    final Uint8List blob = record.deleted
        ? Uint8List(0)
        : await VaultCrypto.sealJson(vaultKey, {
            'kind': record.kind.name,
            'data': record.data,
          });
    return EncryptedRecord(
      id: record.id,
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      deleted: record.deleted,
      seq: null,
      blob: blob,
    );
  }

  Future<DecryptedRecord> decrypt(EncryptedRecord record) async {
    if (record.deleted || record.blob.isEmpty) {
      return DecryptedRecord(
        id: record.id,
        kind: RecordKind.serverConfig, // unknown; irrelevant for a tombstone
        updatedAt: record.updatedAt,
        deviceId: record.deviceId,
        deleted: true,
      );
    }
    final payload = await VaultCrypto.openJson(vaultKey, record.blob);
    return DecryptedRecord(
      id: record.id,
      kind: recordKindFromName(payload['kind'] as String),
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      deleted: false,
      data: (payload['data'] as Map).cast<String, dynamic>(),
    );
  }
}
