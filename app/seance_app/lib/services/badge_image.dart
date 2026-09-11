/// Turns a picked image file into the bytes a server badge can carry.
///
/// Done with `dart:ui` rather than an image-processing dependency: the engine
/// already decodes every format the platform knows (so a user's PNG, JPEG,
/// WebP or HEIC all arrive), and drawing one image into another is a canvas
/// operation, which is a few lines. The result is always a square PNG, because
/// a badge is square and a stored image that needed cropping at paint time
/// would mean every device having to agree on how — while the bytes are the
/// one thing that actually syncs.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

/// The side the badge image is stored at.
///
/// Set by the largest badge the app ever draws, which is the 64-pixel preview
/// in the mark picker: 192 physical pixels on a 3× display. This clears that
/// with headroom and is a round power of two. Going further would be paid for
/// in every sync round to store detail nothing displays.
const int kBadgeImageSide = 256;

/// Sides tried in order until the PNG fits [maxBytes].
///
/// Measured PNG cost at 256 px is about 1 KiB for a flat logo, 53 KiB for a
/// photograph and 154 KiB for pure noise, against a ceiling of 192 KiB — so
/// every one of those is stored at full size and these fallbacks are for
/// content that compresses worse than noise. They are kept because the
/// alternative to stepping down is refusing the import.
const List<int> _sideAttempts = [kBadgeImageSide, 192, 128, 96];

/// Largest source file accepted, before decoding.
///
/// A decoded image costs width × height × 4 bytes whatever its file size, so
/// the guard has to be on the way in: a 100 MP photograph is a 400 MB
/// allocation, and the picker will hand over whatever the user chose.
const int kMaxBadgeSourceBytes = 24 * 1024 * 1024;

/// Why an import could not be used, for a message the user can act on.
enum BadgeImageFailure {
  /// Bigger than [kMaxBadgeSourceBytes].
  tooLarge,

  /// Not an image this platform can decode.
  undecodable,

  /// Decoded, but would not compress small enough at any attempted size.
  incompressible,
}

/// A successful import: the PNG bytes, square and at most
/// [kBadgeImageSide] a side.
class BadgeImage {
  final Uint8List png;
  final int side;

  const BadgeImage({required this.png, required this.side});
}

/// Encodes [source] as a badge image of at most [maxBytes], or reports why it
/// could not be.
///
/// Non-square input is centre-cropped rather than letterboxed: the badge draws
/// the image edge to edge, and bars down its sides read as a broken image.
/// Nothing is ever scaled *up* — a 40-pixel favicon stays 40 pixels rather
/// than being blown up into a blurry 128.
Future<({BadgeImage? image, BadgeImageFailure? failure})> encodeBadgeImage(
  Uint8List source, {
  required int maxBytes,
}) async {
  if (source.lengthInBytes > kMaxBadgeSourceBytes) {
    return (image: null, failure: BadgeImageFailure.tooLarge);
  }
  ui.Image decoded;
  try {
    final codec = await ui.instantiateImageCodec(source);
    try {
      decoded = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } on Exception {
    // The engine's codecs throw a plain Exception for anything they cannot
    // read, which includes "this is not an image".
    return (image: null, failure: BadgeImageFailure.undecodable);
  }

  try {
    if (decoded.width <= 0 || decoded.height <= 0) {
      return (image: null, failure: BadgeImageFailure.undecodable);
    }
    // The largest square the source can fill, centred.
    final crop =
        decoded.width < decoded.height ? decoded.width : decoded.height;
    final cropRect = ui.Rect.fromLTWH(
      (decoded.width - crop) / 2,
      (decoded.height - crop) / 2,
      crop.toDouble(),
      crop.toDouble(),
    );

    int? lastSide;
    for (final attempt in _sideAttempts) {
      final side = attempt < crop ? attempt : crop;
      // A source between two steps clamps both of them to its own size, and
      // re-rendering the same pixels to weigh them again would say nothing new.
      if (side == lastSide) continue;
      lastSide = side;
      final png = await _render(decoded, cropRect, side);
      if (png == null) {
        return (image: null, failure: BadgeImageFailure.undecodable);
      }
      if (png.lengthInBytes <= maxBytes) {
        return (image: BadgeImage(png: png, side: side), failure: null);
      }
      // Already at the source's own size: shrinking further is the next
      // attempt's job, and if the source was smaller than the next step there
      // is nothing left to try.
      if (side == crop && side <= _sideAttempts.last) break;
    }
    return (image: null, failure: BadgeImageFailure.incompressible);
  } finally {
    decoded.dispose();
  }
}

/// Draws [source] of [image] into a [side]×[side] PNG.
Future<Uint8List?> _render(
  ui.Image image,
  ui.Rect source,
  int side,
) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    source,
    ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final picture = recorder.endRecording();
  try {
    final scaled = await picture.toImage(side, side);
    try {
      final data = await scaled.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      scaled.dispose();
    }
  } finally {
    picture.dispose();
  }
}
