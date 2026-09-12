import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_core/src/sync/push_batcher.dart';
import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

EncryptedRecord rec(String id, {int blobBytes = 0}) => EncryptedRecord(
      id: id,
      updatedAt: 10,
      deviceId: 'device-A',
      deleted: false,
      seq: null,
      blob: Uint8List(blobBytes),
    );

/// The body the server would measure for [batch].
int bodyBytes(List<EncryptedRecord> batch) =>
    utf8.encode(jsonEncode(PushRequest(records: batch).toJson())).length;

List<String> idsOf(List<List<EncryptedRecord>> batches) =>
    [for (final batch in batches) ...batch.map((r) => r.id)];

void main() {
  group('batchForPush', () {
    test('an empty dirty set produces no requests', () {
      expect(batchForPush(const [], const PushLimits()), isEmpty);
    });

    test('a dirty set within both limits stays one request', () {
      final records = [rec('a'), rec('b'), rec('c')];
      expect(batchForPush(records, const PushLimits()), [records]);
    });

    test('batches stay under the body limit and keep every record once', () {
      const limits = PushLimits(maxBodyBytes: 4096);
      final records = [
        for (var i = 0; i < 25; i++) rec('r$i', blobBytes: 100 * (i % 7 + 1)),
      ];

      final batches = batchForPush(records, limits);

      expect(batches.length, greaterThan(1));
      for (final batch in batches) {
        expect(batch, isNotEmpty);
        expect(bodyBytes(batch), lessThanOrEqualTo(limits.maxBodyBytes));
      }
      expect(idsOf(batches), records.map((r) => r.id).toList(),
          reason: 'order is preserved and nothing is dropped or duplicated');
    });

    test('a batch is filled up to the body limit, not merely under it', () {
      // Three records that fit together and a fourth that does not: the split
      // has to fall after the third, or batching would waste round trips.
      final records = [for (var i = 0; i < 4; i++) rec('r$i', blobBytes: 300)];
      final limits =
          PushLimits(maxBodyBytes: bodyBytes(records.take(3).toList()));

      final batches = batchForPush(records, limits);

      expect(batches.map((b) => b.length), [3, 1]);
    });

    test('batches stay under the record-count limit', () {
      const limits = PushLimits(maxRecordsPerPush: 4);
      final records = [for (var i = 0; i < 9; i++) rec('r$i')];

      expect(batchForPush(records, limits).map((b) => b.length), [4, 4, 1]);
    });

    test('whichever limit binds first splits the batch', () {
      // Ten records that would fit the body budget but not the count cap.
      const limits = PushLimits(maxBodyBytes: 1024 * 1024, maxRecordsPerPush: 2);
      final records = [for (var i = 0; i < 5; i++) rec('r$i', blobBytes: 8)];

      expect(batchForPush(records, limits).map((b) => b.length), [2, 2, 1]);
    });

    test('a record too large for any body is sent alone and last', () {
      final records = [
        rec('huge', blobBytes: 8192),
        rec('small-1'),
        rec('small-2'),
      ];
      const limits = PushLimits(maxBodyBytes: 2048);

      final batches = batchForPush(records, limits);

      // The server is the authority on its own limits, so the record is still
      // offered rather than dropped — but after the records that do fit, so a
      // rejection cannot hold them up.
      expect(idsOf(batches), ['small-1', 'small-2', 'huge']);
      expect(batches.last.single.id, 'huge');
    });

    test('a record past the blob cap is sent alone and last', () {
      // A blob past the cap fits the body budget comfortably, so nothing about
      // the body arithmetic separates it — and the server answers it with a
      // 413 for the whole push. Batched beside records that would have been
      // accepted, it takes every one of them down, identically every round.
      final records = [
        rec('small-1'),
        rec('fat', blobBytes: 4096),
        rec('small-2'),
      ];
      const limits = PushLimits(maxBodyBytes: 1 << 20, maxBlobBytes: 1024);

      final batches = batchForPush(records, limits);

      expect(idsOf(batches), ['small-1', 'small-2', 'fat']);
      expect(batches.last.single.id, 'fat');
    });

    test('the blob cap is measured on the blob, not the encoded record', () {
      // base64 costs a third more than the bytes it encodes, and the envelope
      // around it costs more again — measuring the encoded record would refuse
      // blobs the server accepts and split batches that did not need it.
      final record = rec('exact', blobBytes: 1024);
      const limits = PushLimits(maxBlobBytes: 1024);

      expect(record.encodedJsonBytes(), greaterThan(1024),
          reason: 'the encoded record is the larger number, so a batcher '
              'comparing it would reject this record');
      final batches = batchForPush([record, rec('after')], limits);
      expect(batches.map((b) => b.map((r) => r.id).toList()),
          [['exact', 'after']],
          reason: 'a blob of exactly the cap is accepted, so it batches '
              'normally rather than being isolated last');
    });

    test('absurd limits still place every record in some batch', () {
      // A misconfigured deployment must not produce an empty batch (a request
      // carrying nothing, forever) or silently swallow a record.
      const limits = PushLimits(maxBodyBytes: 0, maxRecordsPerPush: 0);
      final records = [rec('a'), rec('b')];

      final batches = batchForPush(records, limits);

      expect(batches.every((b) => b.isNotEmpty), isTrue);
      expect(idsOf(batches)..sort(), ['a', 'b']);
    });
  });
}
