import 'package:seance_protocol/seance_protocol.dart';

/// Splits [records] into pushes that fit [limits], preserving the order of
/// every record that fits a body at all (the rest are deferred to the end, as
/// described below).
///
/// Greedy: records accumulate into a batch until the next one would take the
/// encoded body past [PushLimits.maxBodyBytes] or the batch past
/// [PushLimits.maxRecordsPerPush], at which point the batch is closed and a new
/// one starts. Both bounds matter — record sizes span orders of magnitude, so
/// neither a byte budget nor a record count alone bounds the other.
///
/// A record the server will refuse whatever it is batched with cannot be
/// batched into compliance: one that alone exceeds the body budget, and one
/// whose sealed blob exceeds [PushLimits.maxBlobBytes]. Both are answered with
/// a 413 for the *whole* push, so each is sent alone and last. Sent, because
/// the server is the authority on its own limits (the client may be working
/// from defaults, or from an advertisement an operator has since raised), so
/// refusing to send would risk permanently withholding a record the server
/// would have taken, while dropping it silently would lose data. Alone and
/// last, so its near-certain rejection costs only itself and not the records
/// that do fit — otherwise one record past a cap stops the whole account's
/// sync, identically every round, since the batching is deterministic.
List<List<EncryptedRecord>> batchForPush(
  List<EncryptedRecord> records,
  PushLimits limits,
) {
  final batches = <List<EncryptedRecord>>[];
  final unbatchable = <EncryptedRecord>[];
  var batch = <EncryptedRecord>[];
  var batchRecordBytes = 0;

  for (final record in records) {
    final recordBytes = record.encodedJsonBytes();
    final bodyAlone = PushRequest.bodyBytesFor(
      recordCount: 1,
      recordBytes: recordBytes,
    );
    // The blob cap is measured on the *decoded* blob, which is what the server
    // measures — not on the record's encoded size, which carries the base64
    // expansion and the envelope around it.
    if (bodyAlone > limits.maxBodyBytes ||
        record.blob.length > limits.maxBlobBytes) {
      unbatchable.add(record);
      continue;
    }

    final bodyWithRecord = PushRequest.bodyBytesFor(
      recordCount: batch.length + 1,
      recordBytes: batchRecordBytes + recordBytes,
    );
    final full = bodyWithRecord > limits.maxBodyBytes ||
        batch.length + 1 > limits.maxRecordsPerPush;
    // The emptiness check is what guarantees progress: a batch is never closed
    // empty, so every record lands in exactly one batch however the limits are
    // configured.
    if (full && batch.isNotEmpty) {
      batches.add(batch);
      batch = <EncryptedRecord>[];
      batchRecordBytes = 0;
    }
    batch.add(record);
    batchRecordBytes += recordBytes;
  }
  if (batch.isNotEmpty) batches.add(batch);

  for (final record in unbatchable) {
    batches.add([record]);
  }
  return batches;
}
