import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';

/// What gets drawn on a server's badge: one of the app's built-in glyphs, an
/// emoji, or an imported image.
///
/// A [ServerConfig] stores the three possibilities in three independent
/// optional fields rather than as one tagged value, and this resolves them.
/// The reason is forward compatibility, which the protocol takes seriously
/// because records sync between versions in both directions: a build that has
/// never heard of `iconImage` ignores the key and goes on drawing the glyph
/// named in `icon`, which every mark keeps set as its stand-in. A tag inside
/// the existing `icon` field would instead have failed that build's name
/// lookup and left it with the default badge, losing the choice rather than
/// approximating it.
sealed class ServerMark {
  const ServerMark();

  /// The mark [ServerConfig] resolves its fields to. Later kinds win, so a
  /// server that has an image *and* a remembered glyph shows the image; the
  /// glyph stays stored as what an older build, or a device that cannot decode
  /// the image, falls back to.
  factory ServerMark.resolve({
    ServerIcon? icon,
    String? emoji,
    String? image,
  }) {
    if (image != null) {
      // Trimmed, then straight to the decoder — not through the normalizer,
      // which would re-run the whole validation (a base64Decode of up to
      // kMaxServerIconImageBytes) on every call. This runs on every build of
      // every badge row, so that decode landed per frame per badge and was
      // thrown away, only for the decoder to answer from its cache. The
      // decoder validates the same trimmed string internally, so what is
      // accepted here is unchanged and a cache hit now costs nothing.
      final trimmed = image.trim();
      final png = trimmed.isEmpty ? null : decodeServerIconImage(trimmed);
      if (png != null) return ServerImageMark(png, fallback: icon);
    }
    final normalized = normalizeServerEmoji(emoji);
    if (normalized != null) {
      return ServerEmojiMark(normalized, fallback: icon);
    }
    return ServerGlyphMark(icon);
  }

  /// The built-in glyph to draw when this mark cannot be rendered — the same
  /// value an older build would have read out of `icon`.
  ServerIcon? get fallback;

  /// The three field values a [ServerConfig] stores for this mark.
  ///
  /// The inverse of [ServerMark.resolve], so an editor can hold one mark and
  /// write the fields from it without knowing the precedence — and so a mark
  /// that round-trips through a record comes back as itself. An image whose
  /// bytes will not encode (too large for
  /// [kMaxServerIconImageBytes]) stores nothing rather than a truncated
  /// value, leaving the glyph beside it to be drawn.
  ({ServerIcon? icon, String? emoji, String? image}) get stored;
}

/// One of the app's built-in glyphs, or null for the default one.
class ServerGlyphMark extends ServerMark {
  final ServerIcon? icon;
  const ServerGlyphMark(this.icon);

  @override
  ServerIcon? get fallback => icon;

  @override
  ({ServerIcon? icon, String? emoji, String? image}) get stored =>
      (icon: icon, emoji: null, image: null);

  @override
  bool operator ==(Object other) =>
      other is ServerGlyphMark && other.icon == icon;

  @override
  int get hashCode => Object.hash('glyph', icon);
}

/// A single emoji. Stored as text, so it needs no asset and costs the sync
/// layer nothing beyond a few bytes — and renders on any device whose system
/// font covers it, which is the one failure mode (see [ServerMark.fallback]).
class ServerEmojiMark extends ServerMark {
  final String emoji;
  @override
  final ServerIcon? fallback;

  const ServerEmojiMark(this.emoji, {this.fallback});

  @override
  ({ServerIcon? icon, String? emoji, String? image}) get stored =>
      (icon: fallback, emoji: normalizeServerEmoji(emoji), image: null);

  @override
  bool operator ==(Object other) =>
      other is ServerEmojiMark &&
      other.emoji == emoji &&
      other.fallback == fallback;

  @override
  int get hashCode => Object.hash('emoji', emoji, fallback);
}

/// An imported image, as the bytes of a PNG.
class ServerImageMark extends ServerMark {
  /// A validated PNG within [kMaxServerIconImageBytes], and immutable.
  ///
  /// A const constructor cannot normalize, so the invariant rests on the
  /// caller: [ServerMark.resolve] is the supported way to build one of these
  /// and hands over the decoder cache's unmodifiable view. Bytes that are
  /// mutated later break `==`; bytes past the ceiling render here and then
  /// vanish on save, because [stored] refuses them.
  final Uint8List png;
  @override
  final ServerIcon? fallback;

  const ServerImageMark(this.png, {this.fallback});

  @override
  ({ServerIcon? icon, String? emoji, String? image}) get stored =>
      (icon: fallback, emoji: null, image: encodeServerIconImage(png));

  @override
  bool operator ==(Object other) =>
      other is ServerImageMark &&
      other.fallback == fallback &&
      _sameBytes(other.png, png);

  @override
  int get hashCode => Object.hash('image', png.length, fallback);

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The largest image a badge may carry, decoded.
///
/// An imported image is stored inside the server's own config record, which is
/// simple (it syncs with the setting it belongs to, needs no second record
/// kind, and cannot arrive without the server it marks) at the cost of making
/// that record bigger. So the ceiling answers two questions at once: how much
/// detail a badge can use, and how big that makes a record.
///
/// Detail sets the *side* the app stores at ([kBadgeImageSide]); this sets the
/// bytes that side is allowed to cost. It is deliberately generous enough that
/// realistic content never trips the step-down: measured PNG sizes at 256 px
/// are about 1 KiB for a flat logo, 53 KiB for a photograph, and 154 KiB for
/// pure noise, so at 192 KiB even the pathological case is stored at full size
/// and the fallbacks exist for content worse than noise.
///
/// What bounds it is the sync server's per-record ceiling of a megabyte,
/// measured on the *decoded* sealed blob. A record carries the image
/// base64-encoded inside sealed JSON, so a config at this cap with every other
/// field at its longest seals to about 258 KiB — a quarter of what is allowed.
/// `record_size_test.dart` in the server package asserts that against the
/// server's real limit rather than against this arithmetic.
///
/// The app re-encodes every import rather than trusting its size, stepping the
/// dimensions down until the PNG fits; this is the backstop for a record
/// arriving from somewhere else.
const int kMaxServerIconImageBytes = 192 * 1024;

/// A PNG's first eight bytes. Imports are re-encoded to PNG, so a mark that is
/// not one did not come from this app, and the alternative to checking is
/// handing arbitrary bytes to an image decoder.
const List<int> _pngSignature = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
];

/// Byte offsets of IHDR's dimensions: the 8-byte signature, then the chunk's
/// 4-byte length and 4-byte type, then width and height as big-endian uint32.
const int _ihdrLength = 8;
const int _ihdrType = 12;
const int _ihdrWidth = 16;
const int _ihdrHeight = 20;
const int _ihdrEnd = 24;

/// `IHDR` as a big-endian uint32, and the chunk's fixed data length.
const int _ihdrTypeTag = 0x49484452;
const int _ihdrDataLength = 13;

/// The largest side an image mark may declare.
///
/// Not a quality limit — the app re-encodes every import to badge size, far
/// below this. It is the bound on what a decoder can be
/// asked to allocate by a record that did not come from this app's import
/// path: a corrupt or hostile one, or a future code path that sets the field
/// directly. Generous enough that no plausible legitimate value trips it.
const int _maxIconImageSide = 1024;

/// The stored form of an emoji mark: trimmed, and null when it is not one.
///
/// Exactly one grapheme cluster, because the badge has room for one character
/// and a cluster is what a user means by "an emoji" — 👩🏽‍🚀 is four code points
/// and one choice. The code-unit ceiling is a separate guard: a cluster can be
/// extended with joiners indefinitely, and a record from elsewhere should not
/// be able to park a kilobyte of them in a config.
String? normalizeServerEmoji(String? emoji) {
  if (emoji == null) return null;
  final trimmed = emoji.trim();
  if (trimmed.isEmpty || trimmed.length > 64) return null;
  if (trimmed.characters.length != 1) return null;
  // Plane 14 holds nothing but formatting: the language tag, the tag
  // characters behind subdivision flags, and the variation selectors
  // supplement. Every one has grapheme class Extend, so alone it is a single
  // cluster of two code units and the loop below — which compares UTF-16 code
  // *units*, all of them BMP — cannot see it. Only the cluster's first code
  // point is tested, because a subdivision flag is a visible base followed by
  // tag characters and must keep working.
  final first = trimmed.runes.first;
  if (first >= 0xE0000 && first <= 0xE0FFF) return null;
  // Control and invisible formatting characters are not marks, and a record
  // could carry one: the bidi controls in particular (the overrides and
  // isolates, and the plain LRM/RLM/ALM marks) would reorder the text around
  // wherever the badge's label is rendered, and the zero-width ones would
  // render an empty badge. U+200D is deliberately absent — it is the joiner
  // that holds a multi-part emoji together.
  final units = trimmed.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    // An unpaired surrogate is ill-formed UTF-16: one grapheme cluster by the
    // cluster rule, under the length ceiling, and rendered as tofu on every
    // platform. A well-formed pair is how every emoji outside the BMP is
    // spelled, so the low half is stepped over rather than rejected.
    if (unit >= 0xD800 && unit <= 0xDFFF) {
      final next = i + 1 < units.length ? units[i + 1] : 0;
      if (unit > 0xDBFF || next < 0xDC00 || next > 0xDFFF) return null;
      i++;
      continue;
    }
    if (unit < 0x20 ||
        (unit >= 0x7F && unit <= 0x9F) ||
        unit == 0x00AD || // soft hyphen
        unit == 0x061C || // Arabic letter mark
        unit == 0x115F || // Hangul choseong filler
        unit == 0x1160 || // Hangul jungseong filler
        unit == 0x3164 || // Hangul filler, the invisible-username character
        unit == 0xFFA0 || // halfwidth Hangul filler
        unit == 0x200B || // zero-width space
        unit == 0x200C || // zero-width non-joiner
        (unit >= 0x200E && unit <= 0x200F) || // LRM, RLM
        (unit >= 0x202A && unit <= 0x202E) || // embeddings and overrides
        (unit >= 0x2060 && unit <= 0x2064) || // word joiner, invisible ops
        unit == 0x180E || // Mongolian vowel separator
        (unit >= 0x2066 && unit <= 0x206F) || // isolates, deprecated Cf
        unit == 0xFEFF) {
      return null;
    }
  }
  return trimmed;
}

/// The stored form of an image mark: base64 of a PNG within
/// [kMaxServerIconImageBytes], or null when it is neither.
///
/// Validated on the way in *and* on the way out (see [ServerConfig.fromJson]
/// and [ServerConfig.toJson]), so a record this build refuses is never
/// re-published as though it had been accepted.
String? normalizeServerIconImage(String? base64Png) {
  if (base64Png == null) return null;
  final trimmed = base64Png.trim();
  if (trimmed.isEmpty) return null;
  // Validated without touching the cache. This runs on the *write* path —
  // `stored` calls it on every `toJson` — and inserting there would charge the
  // byte budget for images nothing is displaying, then clear the whole cache
  // when it tripped, evicting the badges currently on screen and re-decoding
  // every one of them on the next frame. Exactly the jank the cache exists to
  // prevent, caused by a path that never renders.
  return _validateIconImage(trimmed) == null ? null : trimmed;
}

/// Decoded image marks, keyed by the stored form they came from.
///
/// Not an optimization for the base64 pass, which is cheap. [ServerConfig.mark]
/// is read on every build of every row that shows a badge, and Flutter's
/// `MemoryImage` keys its cache on the *identity* of the byte list it is given
/// — so handing out a fresh list each time would re-decode the PNG on every
/// frame rather than merely re-running base64. Returning the same list keeps
/// the image cached.
///
/// Bounded, and cleared wholesale rather than evicted one at a time. The
/// binding bound is the byte budget, not the entry count: it admits about 42
/// images at the size cap, or around 150 photograph-sized ones. Both are above
/// any plausible number of image-marked servers, and a cache that does not
/// trip in practice does not need an eviction policy — a fleet past that point
/// re-decodes on the reads after a clear, which costs frames rather than
/// correctness.
final Map<String, Uint8List> _decodedIconImages = {};
const int _decodedIconImageLimit = 256;

/// Total bytes the cache may retain. The entry count alone is not a bound:
/// 256 entries at [kMaxServerIconImageBytes] would be 48 MB held statically
/// for the life of the process, which on a phone is not a cache but a leak.
const int _decodedIconImageByteLimit = 8 * 1024 * 1024;
int _decodedIconImageBytes = 0;

/// The bytes behind an image mark, or null when the value is not a PNG this
/// build will carry.
///
/// The result is an unmodifiable view: it is shared between every caller that
/// passes the same stored value (see [_decodedIconImages]), so writing through
/// it would reach all of them.
Uint8List? decodeServerIconImage(String base64Png) {
  final cached = _decodedIconImages[base64Png];
  if (cached != null) return cached;
  final bytes = _validateIconImage(base64Png);
  if (bytes == null) return null;
  if (_decodedIconImages.length >= _decodedIconImageLimit ||
      _decodedIconImageBytes + bytes.length > _decodedIconImageByteLimit) {
    _decodedIconImages.clear();
    _decodedIconImageBytes = 0;
  }
  _decodedIconImageBytes += bytes.length;
  return _decodedIconImages[base64Png] = bytes.asUnmodifiableView();
}

/// Every rule a stored image must satisfy, with no cache involvement.
///
/// Split out so the write path can validate without charging the render
/// cache — see [normalizeServerIconImage].
Uint8List? _validateIconImage(String base64Png) {
  // A base64 length ceiling before decoding, so a megabyte of text is refused
  // without being expanded first.
  if (base64Png.length > (kMaxServerIconImageBytes + 2) ~/ 3 * 4 + 4) {
    return null;
  }
  final Uint8List bytes;
  try {
    bytes = base64Decode(base64Png);
  } on FormatException {
    return null;
  }
  if (bytes.length > kMaxServerIconImageBytes) return null;
  if (bytes.length < _ihdrEnd) return null;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return null;
  }
  // The byte ceiling above does not bound what a decoder will *allocate*: PNG
  // compresses a flat colour so well that a few hundred bytes can declare
  // 65535x65535, which is a multi-gigabyte RGBA buffer at the moment a badge
  // paints. IHDR is required to be the first chunk, so the dimensions sit at
  // fixed offsets and can be refused before anything decodes them.
  final header = ByteData.sublistView(bytes);
  // Checked rather than assumed: the fixed offsets only address the dimensions
  // if IHDR really is first. A file that leads with some other chunk would
  // otherwise be measured on whatever bytes happen to sit there, and could
  // carry a real IHDR declaring anything further in.
  if (header.getUint32(_ihdrLength) != _ihdrDataLength ||
      header.getUint32(_ihdrType) != _ihdrTypeTag) {
    return null;
  }
  final width = header.getUint32(_ihdrWidth);
  final height = header.getUint32(_ihdrHeight);
  if (width == 0 || height == 0) return null;
  if (width > _maxIconImageSide || height > _maxIconImageSide) return null;
  return bytes;
}

/// Base64 for storing [png] as an image mark, or null when it is too big or
/// not a PNG. The encoder side of [decodeServerIconImage], so a value this
/// produces always survives a round trip.
String? encodeServerIconImage(Uint8List png) {
  final encoded = base64Encode(png);
  return normalizeServerIconImage(encoded);
}

/// A server's icon, again as a name from a closed set.
///
/// Beyond the sync argument above, Flutter's `--tree-shake-icons` build step
/// only keeps glyphs it can see referenced by a *const* `IconData`. Storing an
/// arbitrary codepoint and rendering `Icon(IconData(stored))` compiles fine and
/// then ships a release build with blank squares where the icons were. A name
/// mapped to a const `IconData` in the app keeps the whole feature
/// tree-shakable.
/// The names are the wire format, so the sixteen this shipped with keep their
/// spelling forever; anything new is appended. The app maps each to a glyph and
/// files it under a heading for the picker (see its `ServerAppearance`), and
/// neither of those is part of the protocol — a later version may draw
/// `database` differently without that being a change to what syncs.
enum ServerIcon {
  server,
  cloud,
  database,
  web,
  terminal,
  shield,
  home,
  work,
  lab,
  device,
  router,
  mail,
  container,
  rocket,
  star,
  bug,
  // Infrastructure.
  cluster,
  vm,
  desktop,
  laptop,
  network,
  vpn,
  files,
  backup,
  archive,
  dataCenter,
  satellite,
  sensor,
  printer,
  power,
  // Services.
  api,
  dashboard,
  monitoring,
  analytics,
  chat,
  forum,
  feed,
  media,
  music,
  photos,
  game,
  voice,
  camera,
  shop,
  billing,
  calendar,
  docs,
  wiki,
  ai,
  // Building.
  code,
  git,
  build,
  plugin,
  construction,
  speed,
  // Access.
  lock,
  key,
  admin,
  verified,
  // Places.
  office,
  plant,
  cottage,
  public,
  favourite,
  pets,
  coffee,
  anchor,
  eco,
  // Status.
  bolt,
  hot,
  frozen,
  watch,
  caution,
  magic,
  bot,
  layers,
  widgets,
}

/// Decode a [ServerIcon] name, or null when absent *or unrecognized*.
///
/// Deliberately without a fallback value: a newer device may have tagged a
/// server with a glyph this build has never heard of, and showing the wrong
/// glyph is worse than showing the default. Round-tripping is lossy for that
/// record, which is the record layer's existing behaviour for any added field
/// and costs a picture rather than a credential.
ServerIcon? serverIconFromName(String? name) =>
    name == null ? null : _iconsByName[name];

/// Built once. This decodes per record and again on every rebuild of a list
/// that draws badges, and the enum is long enough that walking it to compare
/// `.name` each time is measurable.
final Map<String, ServerIcon> _iconsByName = ServerIcon.values.asNameMap();
