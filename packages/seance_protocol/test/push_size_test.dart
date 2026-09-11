import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

/// The client batches a push against the server's byte limit using sizes it
/// computes instead of encoding (see `src/json_size.dart`). A count that drifts
/// from what `jsonEncode` actually produces is invisible until a real push is
/// rejected whole, so every size here is pinned against the encoder.
int actualBodyBytes(PushRequest request) =>
    utf8.encode(jsonEncode(request.toJson())).length;

int actualRecordBytes(EncryptedRecord record) =>
    utf8.encode(jsonEncode(record.toJson())).length;

EncryptedRecord record({
  String id = 'record-id',
  int updatedAt = 1,
  String deviceId = 'device-A',
  bool deleted = false,
  int? seq,
  int blobBytes = 0,
}) =>
    EncryptedRecord(
      id: id,
      updatedAt: updatedAt,
      deviceId: deviceId,
      deleted: deleted,
      seq: seq,
      blob: Uint8List.fromList(List.generate(blobBytes, (i) => i % 256)),
    );

void main() {
  group('EncryptedRecord.encodedJsonBytes', () {
    final cases = <String, EncryptedRecord>{
      'unsequenced record': record(),
      'sequenced record': record(seq: 42),
      'tombstone': EncryptedRecord.tombstone(
          id: 'gone', updatedAt: 7, deviceId: 'device-B'),
      'large blob': record(blobBytes: 64 * 1024),
      // Base64 pads to a multiple of four; cover each remainder.
      'blob length 1 mod 3': record(blobBytes: 10),
      'blob length 2 mod 3': record(blobBytes: 11),
      'blob length 0 mod 3': record(blobBytes: 12),
      'non-ASCII device name': record(deviceId: 'Lukas’ Séance — büro'),
      'escaped characters in id': record(id: 'quote:" backslash:\\ tab:\t'),
      'control characters in id':
          record(id: 'bell:\u0007 null:\u0000 unit-sep:\u001f'),
      'astral plane in id': record(id: 'ghost:\u{1F47B}'),
      'large timestamp and seq':
          record(updatedAt: 1893456000000, seq: 987654321),
      'negative timestamp': record(updatedAt: -1),
    };

    cases.forEach((name, value) {
      test('matches jsonEncode for a $name', () {
        expect(value.encodedJsonBytes(), actualRecordBytes(value));
      });
    });
  });

  group('PushRequest body size', () {
    test('matches jsonEncode for an empty push', () {
      final request = PushRequest(records: const []);
      expect(request.encodedSizeBytes(), actualBodyBytes(request));
    });

    test('matches jsonEncode for a single record', () {
      final request = PushRequest(records: [record(blobBytes: 100)]);
      expect(request.encodedSizeBytes(), actualBodyBytes(request));
    });

    test('matches jsonEncode for many mixed records', () {
      final request = PushRequest(records: [
        record(id: 'a', blobBytes: 3),
        record(id: 'b', seq: 12, blobBytes: 4096),
        EncryptedRecord.tombstone(id: 'c', updatedAt: 9, deviceId: 'device-C'),
        record(id: 'd', deleted: true, deviceId: 'Séance', blobBytes: 7),
      ]);
      expect(request.encodedSizeBytes(), actualBodyBytes(request));
    });

    test('bodyBytesFor composes from per-record sizes', () {
      final records = [
        record(id: 'a', blobBytes: 1000),
        record(id: 'b', blobBytes: 2000),
      ];
      final composed = PushRequest.bodyBytesFor(
        recordCount: records.length,
        recordBytes:
            records.fold(0, (sum, r) => sum + r.encodedJsonBytes()),
      );
      expect(composed, actualBodyBytes(PushRequest(records: records)));
    });

    test('randomized records of every batch size match jsonEncode', () {
      // The table above varies one dimension at a time. The framing arithmetic
      // is the one part that depends on how many records a body holds (the
      // commas between them), so sweep record counts with everything else
      // varying at once. Fixed seed: a failure has to be reproducible.
      final random = Random(20260911);
      for (var recordCount = 0; recordCount < 24; recordCount++) {
        final request = PushRequest(records: [
          for (var i = 0; i < recordCount; i++)
            record(
              id: 'id-$i-\u0001"\\ ${'é' * random.nextInt(4)}',
              // Epoch-millisecond scale (13 digits), both signs: nextInt
              // caps at 2^32, so compose the value from two draws.
              updatedAt: (random.nextInt(1 << 31) * 1000 +
                      random.nextInt(1000)) *
                  (random.nextBool() ? 1 : -1),
              deviceId: 'device-${random.nextInt(1000)}',
              deleted: random.nextBool(),
              seq: random.nextBool() ? random.nextInt(1 << 32) : null,
              blobBytes: random.nextInt(300),
            ),
        ]);
        expect(request.encodedSizeBytes(), actualBodyBytes(request),
            reason: 'body holding $recordCount records');
      }
    });

    test('a non-default protocol version is counted', () {
      final request = PushRequest(
          protocolVersion: 1234, records: [record(blobBytes: 8)]);
      expect(request.encodedSizeBytes(), actualBodyBytes(request));
    });
  });

  group('PushLimits', () {
    test('defaults match the limits the server ships with', () {
      const limits = PushLimits();
      expect(limits.maxBodyBytes, 8 * 1024 * 1024);
      expect(limits.maxRecordsPerPush, 1000);
    });

    test('round-trips through JSON', () {
      const limits = PushLimits(maxBodyBytes: 1234, maxRecordsPerPush: 7);
      expect(PushLimits.fromJson(limits.toJson()), limits);
    });

    test('an advertisement missing a field keeps the default for it', () {
      final decoded = PullResponse.fromJson({
        'records': <Object>[],
        'latestSeq': 1,
        'limits': {'maxBodyBytes': 4096},
      });
      expect(decoded.limits,
          const PushLimits(maxBodyBytes: 4096));
    });

    test('a pull response carries the limits when the server advertises', () {
      const limits = PushLimits(maxBodyBytes: 4096, maxRecordsPerPush: 5);
      final decoded = PullResponse.fromJson(
          PullResponse(records: const [], latestSeq: 3, limits: limits)
              .toJson());
      expect(decoded.limits, limits);
    });

    test('a pull response from a server that does not advertise has none', () {
      final decoded = PullResponse.fromJson(
          const PullResponse(records: [], latestSeq: 3).toJson());
      expect(decoded.limits, isNull);
    });

    test('a malformed limits value degrades to the fallback, not a crash', () {
      // `limits` is advisory and has a documented fallback, so a proxy-mangled
      // or buggy value must not take the records and watermark down with it.
      for (final malformed in <Object>[
        'garbage',
        42,
        <String>['nope'],
        // A well-shaped object whose fields are not numbers: the shape that
        // a container-type check alone lets through into the `as num?` cast.
        {'maxBodyBytes': '8MB'},
        {'maxRecordsPerPush': 'many'},
        {'maxBodyBytes': 4096, 'maxRecordsPerPush': <String>[]},
        // Numeric shapes that pass a type check and then break: the JSON
        // number 1e999 decodes to infinity, whose toInt() throws, and 2^53 is
        // where a double stops representing integers exactly.
        {'maxBodyBytes': 1e999},
        {'maxRecordsPerPush': double.nan},
        {'maxBodyBytes': 1e300},
        // Caps no push could satisfy, which the server refuses to start on.
        {'maxRecordsPerPush': 0},
        {'maxBodyBytes': -1},
      ]) {
        final decoded = PullResponse.fromJson({
          'records': <Object>[],
          'latestSeq': 3,
          'limits': malformed,
        });
        expect(decoded.limits, isNull, reason: 'limits: $malformed');
        expect(decoded.latestSeq, 3);
      }
    });
  });
}
