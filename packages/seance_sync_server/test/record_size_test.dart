import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:test/test.dart';

/// A server's imported badge image rides inside its own config record, so the
/// size the client will accept and the size this server will store are one
/// decision split across two packages. Asserted here rather than reasoned
/// about, because the expansion between them is not obvious: the image is
/// base64-encoded into JSON, that JSON is sealed, and it is the *decoded*
/// sealed blob the server measures.
void main() {
  test('a maximum-size badge image fits the per-record limit', () async {
    // A PNG-shaped payload of exactly the size the protocol allows: the
    // signature, an IHDR declaring the 256 px square the app stores at, then
    // incompressible filler. Incompressible is the honest case for a ceiling —
    // a real 256 px photograph measures around 53 KiB.
    const header = [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
      0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, // chunk length 13, "IHDR"
      0, 0, 1, 0, // width 256
      0, 0, 1, 0, // height 256
    ];
    final image = Uint8List(kMaxServerIconImageBytes)..setAll(0, header);
    // From the header's own length: filler that started at a stale literal
    // would either overwrite it or leave a run of compressible zeros, which
    // would quietly make this measurement optimistic.
    for (var i = header.length; i < image.length; i++) {
      image[i] = (i * 2654435761) & 0xFF;
    }
    final stored = encodeServerIconImage(image);
    expect(stored, isNotNull, reason: 'the cap must admit its own maximum');

    final config = ServerConfig(
      id: 'srv-1',
      // Long values throughout, so the rest of the record is measured at its
      // worst rather than at its tidiest.
      label: 'x' * 200,
      host: '${'h' * 200}.example.com',
      username: 'y' * 100,
      group: 'g' * 100,
      icon: ServerIcon.dataCenter,
      iconEmoji: '\u{1F433}',
      iconImage: stored,
      loginScript: 'z' * 1000,
      identityFilePath: '/${'p' * 200}/id_ed25519',
      createdAt: 1,
      updatedAt: 2,
    );

    final record = await RecordCodec(secureRandomBytes(32)).encrypt(
      DecryptedRecord(
        id: 'serverConfig:${config.id}',
        kind: RecordKind.serverConfig,
        updatedAt: config.updatedAt,
        deviceId: 'device-1',
        data: config.toJson(),
      ),
    );

    // The limit the server actually enforces, on the value it actually
    // measures (`server.dart` compares `incoming.blob.length`).
    const settings = ServerSettings();
    expect(
      record.blob.length,
      lessThan(settings.maxBlobBytes),
      reason: 'a record at the image cap must be pushable to a default server',
    );
    // And with room to spare, so a later field cannot quietly close the gap.
    expect(record.blob.length, lessThan(settings.maxBlobBytes ~/ 2));
  });
}
