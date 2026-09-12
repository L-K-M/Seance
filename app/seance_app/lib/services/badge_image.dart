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

/// Largest source accepted, measured on the bytes as handed over.
///
/// A first, cheap gate, and only that: this function receives a `Uint8List`,
/// so the file has already been read by the time it applies. It does *not*
/// bound what decoding will allocate either — that is
/// [kMaxBadgeSourcePixels]'s job — because a file's compressed size says
/// almost nothing about its pixel count.
const int kMaxBadgeSourceBytes = 24 * 1024 * 1024;

/// Largest decoded image accepted, in pixels: 4096² is 16.7 MP, about 67 MB
/// of RGBA.
///
/// This is the guard that matters. A decoded image costs width × height × 4
/// whatever the file weighed: a 48 MP phone photo is a 5–10 MB JPEG and a
/// ~190 MB allocation, and a flat-colour PNG can declare enormous dimensions
/// in a few hundred bytes. Since the picker hands over whatever the user
/// chose, the dimensions have to be read and refused *before* the decode, or
/// the most ordinary action in this flow — picking a recent photo — can be an
/// out-of-memory kill on a phone.
const int kMaxBadgeSourcePixels = 4096 * 4096;

/// Why an import could not be used, for a message the user can act on.
enum BadgeImageFailure {
  /// Bigger than [kMaxBadgeSourceBytes] on disk, or more pixels than
  /// [kMaxBadgeSourcePixels] once its header is read.
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
  final ui.Image decoded;
  try {
    // Through an ImageDescriptor rather than `instantiateImageCodec` so the
    // dimensions can be read from the header and refused before the pixel
    // buffer is ever allocated. The codec API offers no way back from a decode
    // that is already too big.
    // The buffer holds a native copy of the source bytes — up to
    // [kMaxBadgeSourceBytes] of them — and the descriptor retains the data
    // itself, so this can be released as soon as the decode is done. Disposed
    // in an outer finally so every path frees it deterministically rather than
    // waiting on a finalizer: the success path, the tooLarge early return, and
    // an `encoded` that throws before there is a descriptor at all.
    final buffer = await ui.ImmutableBuffer.fromUint8List(source);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        // The budget is the product; the per-side comparisons only keep it
        // from overflowing, by holding each factor below the budget so their
        // product cannot exceed its square. They reject nothing the budget
        // would have allowed — a side above 16.7 million pixels is already
        // past it on its own — so ordinary wide sources still pass: a
        // 6000x1000 panorama is 6 MP and accepted.
        //
        // Not reachable through a PNG in any case: its dimensions cap at
        // 2^31-1, whose square still fits int64, and the engine rejects a
        // larger header before this runs (measured: `encoded` throws
        // "Invalid image data" for a 0xFFFFFFFF square). One comparison to
        // stop the guard this file calls load-bearing depending on that.
        if (descriptor.width > kMaxBadgeSourcePixels ||
            descriptor.height > kMaxBadgeSourcePixels ||
            descriptor.width * descriptor.height > kMaxBadgeSourcePixels) {
          return (image: null, failure: BadgeImageFailure.tooLarge);
        }
        final codec = await descriptor.instantiateCodec();
        try {
          decoded = (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
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
    //
    // Read off the decoded image rather than the file header, which is what
    // makes a phone photo come out upright: the engine applies EXIF
    // orientation, so a portrait shot stored as landscape-plus-a-rotation-flag
    // decodes already rotated. Measured on this engine — a JPEG whose SOF
    // says 6000x4000 with Orientation=6 reports 4000x6000 from *both*
    // `ImageDescriptor.encoded` and the decoded frame. So no rotation belongs
    // here, and the pixel guard above is unaffected either way because it
    // compares the product.
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
  } on Exception {
    // Mirrors the decode phase. Without this an engine failure in `_render`
    // would be thrown past a caller that is pattern-matching the record, so
    // the import would crash instead of showing a message.
    return (image: null, failure: BadgeImageFailure.undecodable);
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
      if (data == null) return null;
      // The view's own offset and length, not the whole backing buffer: a
      // ByteData is not contractually a view over the entire buffer from zero,
      // and taking it as one would store a wrong-length or shifted PNG.
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      scaled.dispose();
    }
  } finally {
    picture.dispose();
  }
}
