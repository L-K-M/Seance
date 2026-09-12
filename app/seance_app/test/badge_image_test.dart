import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/badge_image.dart';
import 'package:seance_core/seance_core.dart';

/// Importing an image for a server badge. The encoder is what stands between a
/// picked file and a synced record, so what it produces has to be square, small
/// and within the ceiling the protocol enforces.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A [width]×[height] PNG: a solid field with a centred circle, so a
  /// centre-cropped result stays recognisable beyond its bare dimensions.
  Future<Uint8List> png(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF3366CC),
    );
    canvas.drawCircle(
      ui.Offset(width / 2, height / 2),
      width / 4,
      ui.Paint()..color = const ui.Color(0xFFFFCC00),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    image.dispose();
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// A [side]×[side] PNG of deterministic noise. Flat colour compresses to
  /// almost nothing, so the size ceiling can only be exercised with an image
  /// that genuinely resists it — which is also the realistic worst case (a
  /// photograph, a screenshot of text).
  Future<Uint8List> noisePng(int side) async {
    final pixels = Uint8List(side * side * 4);
    // A small linear congruential generator rather than Random: the suite
    // must not have a test that fails one run in fifty.
    var seed = 0x2545F491;
    for (var i = 0; i < pixels.length; i += 4) {
      // One draw per channel, taken from the high bits: an LCG's low bits have
      // a short period (bits 0-7 repeat every 256 draws), so reading three
      // channels out of one draw would give a red channel identical in every
      // row — noise that compresses far better than the real thing.
      for (var channel = 0; channel < 3; channel++) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        pixels[i + channel] = (seed >> 16) & 0xFF;
      }
      pixels[i + 3] = 0xFF;
    }
    final image = await _imageFromPixels(pixels, side, side);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<ui.Image> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  test('a square source is scaled to the stored side', () async {
    final result = await encodeBadgeImage(
      await png(512, 512),
      maxBytes: kMaxServerIconImageBytes,
    );
    expect(result.failure, isNull);
    final image = await decode(result.image!.png);
    addTearDown(image.dispose);
    expect(image.width, kBadgeImageSide);
    expect(image.height, kBadgeImageSide);
  });

  test('a source far larger than the badge still lands at badge size',
      () async {
    // The decode is bounded to 2x the stored side rather than the source's
    // own 4000x3000 (46 MB of RGBA against 1.3 MB, measured). The result must
    // be indistinguishable: same side, square, and a real PNG.
    final big = await png(4000, 3000);
    final result = await encodeBadgeImage(big, maxBytes: 192 * 1024);
    expect(result.failure, isNull);
    expect(result.image!.side, kBadgeImageSide);
    final image = await decode(result.image!.png);
    addTearDown(image.dispose);
    expect(image.width, kBadgeImageSide);
    expect(image.height, kBadgeImageSide);
  });

  test('a wide source is cropped square, not squashed', () async {
    // The badge draws its image edge to edge, so bars down the sides would
    // read as a broken image; the shape has to be fixed here, where the bytes
    // are made, not at paint time on each device.
    final result = await encodeBadgeImage(
      await png(600, 200),
      maxBytes: kMaxServerIconImageBytes,
    );
    expect(result.failure, isNull);
    final image = await decode(result.image!.png);
    addTearDown(image.dispose);
    expect(image.width, image.height);

    // Squareness alone cannot tell a centre crop from a squash — both end up
    // square. The fixture's circle has radius width/4 = 150, so the centred
    // 200x200 crop lies entirely inside it: a crop is solid circle colour to
    // the corners, while a squash maps the circle to a narrow ellipse and
    // leaves the surrounding field visible there.
    final data = (await image.toByteData())!;
    final pixels =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    bool circleAt(int x, int y) {
      final offset = (y * image.width + x) * 4;
      return pixels[offset] > 0x80 &&
          pixels[offset + 1] > 0x80 &&
          pixels[offset + 2] < 0x80;
    }

    expect(circleAt(2, 2), isTrue, reason: 'cropped, not squashed');
    expect(
      circleAt(image.width - 3, image.height - 3),
      isTrue,
      reason: 'cropped, not squashed',
    );
  });

  test('a source between steps is stored at its own size', () async {
    // A 150-pixel source clamps the 256 and 192 steps to its own size, so
    // without deduplication the same pixels would be encoded three times to
    // weigh them. Observable only as the size that comes back, which must be
    // the source's own rather than a step below it.
    final result = await encodeBadgeImage(
      await png(150, 150),
      maxBytes: kMaxServerIconImageBytes,
    );
    expect(result.failure, isNull);
    expect(result.image!.side, 150);
  });

  test('a source smaller than the stored side is not blown up', () async {
    final result = await encodeBadgeImage(
      await png(40, 40),
      maxBytes: kMaxServerIconImageBytes,
    );
    expect(result.failure, isNull);
    expect(result.image!.side, 40);
    final image = await decode(result.image!.png);
    addTearDown(image.dispose);
    expect(image.width, 40);
  });

  test('the result is a PNG the protocol will carry', () async {
    final result = await encodeBadgeImage(
      await png(512, 512),
      maxBytes: kMaxServerIconImageBytes,
    );
    // The whole point of the ceiling: whatever this produces has to survive
    // the validation a record goes through, or an import would be accepted
    // here and dropped on the next read.
    expect(result.failure, isNull);
    final stored = encodeServerIconImage(result.image!.png);
    expect(stored, isNotNull);
    expect(decodeServerIconImage(stored!), result.image!.png);
  });

  test('a tight ceiling steps the size down instead of failing', () async {
    final source = await noisePng(256);
    // What the full size costs, measured against a ceiling high enough that it
    // cannot itself force a step down — the point here is the *fallback*, and
    // deriving the ceiling from the real encode keeps the test independent of
    // how well any particular PNG encoder does.
    final full = await encodeBadgeImage(source, maxBytes: 1024 * 1024);
    // Named before it is unwrapped: a regression here should report which
    // BadgeImageFailure it hit, not a null-check error.
    expect(full.failure, isNull);
    expect(full.image!.side, kBadgeImageSide);
    final ceiling = full.image!.png.lengthInBytes ~/ 2;

    final result = await encodeBadgeImage(source, maxBytes: ceiling);
    expect(result.failure, isNull);
    expect(result.image!.png.lengthInBytes, lessThanOrEqualTo(ceiling));
    expect(result.image!.side, lessThan(kBadgeImageSide));
  });

  test('a ceiling nothing fits is reported, not approximated', () async {
    final result = await encodeBadgeImage(await noisePng(256), maxBytes: 16);
    expect(result.image, isNull);
    expect(result.failure, BadgeImageFailure.incompressible);
  });

  test('bytes that are not an image are reported', () async {
    final result = await encodeBadgeImage(
      Uint8List.fromList(List.filled(2048, 0x41)),
      maxBytes: kMaxServerIconImageBytes,
    );
    expect(result.image, isNull);
    expect(result.failure, BadgeImageFailure.undecodable);
  });

  test('an image claiming too many pixels is refused before decoding', () async {
    // The file-size gate cannot catch this: PNG stores a flat colour in almost
    // nothing, so a handful of bytes can ask for a multi-gigabyte buffer. A
    // phone photo is the same shape of problem at realistic sizes — a few
    // megabytes of JPEG, a couple of hundred megabytes of RGBA.
    final claimed = declaringSize(await png(8, 8), 20000, 20000);
    final result = await encodeBadgeImage(
      claimed,
      maxBytes: kMaxServerIconImageBytes,
    );
    expect(result.image, isNull);
    expect(
      result.failure,
      BadgeImageFailure.tooLarge,
      reason: 'refused for its dimensions, not merely undecodable',
    );

    // …and a large-but-allowed image still gets through the same gate, so the
    // test is not passing because everything is refused.
    final fine = declaringSize(await png(8, 8), 8, 8);
    expect((await encodeBadgeImage(fine, maxBytes: kMaxServerIconImageBytes))
        .failure, isNull);
  });

  test('an oversized file is refused before it is decoded', () async {
    // Decoding costs width × height × 4 whatever the file size, so the guard
    // has to come first: the picker hands over whatever the user chose.
    final result = await encodeBadgeImage(
      Uint8List(kMaxBadgeSourceBytes + 1),
      maxBytes: kMaxServerIconImageBytes,
    );
    expect(result.image, isNull);
    expect(result.failure, BadgeImageFailure.tooLarge);
  });
}

/// [ui.decodeImageFromPixels] with a future instead of a callback.
Future<ui.Image> _imageFromPixels(Uint8List pixels, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Rewrites [source]'s IHDR to declare [width] x [height], fixing the chunk's
/// CRC so the header still parses.
///
/// The pixel data is left alone and no longer matches, which is the point:
/// what a PNG *claims* is what a decoder allocates from, and that claim has to
/// be refused before any of it is read.
Uint8List declaringSize(Uint8List source, int width, int height) {
  final bytes = Uint8List.fromList(source);
  final view = ByteData.sublistView(bytes);
  // signature(8) + chunk length(4) + type(4), then two big-endian uint32s.
  view.setUint32(16, width);
  view.setUint32(20, height);
  // The CRC covers the chunk's type and data: offsets 12 through 12+4+13.
  view.setUint32(29, _crc32(bytes.sublist(12, 29)));
  return bytes;
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
