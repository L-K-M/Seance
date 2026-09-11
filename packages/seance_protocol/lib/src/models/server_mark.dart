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
      final png = decodeServerIconImage(image);
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
/// A badge is 32 logical pixels, so this is far more than it can show; what
/// bounds it is the record it travels in. An imported image is stored inside
/// the server's own config record, which is simple (it syncs with the setting
/// it belongs to, needs no second record kind, and cannot arrive without the
/// server it marks) at the cost of making that record bigger.
///
/// Two server-side ceilings set the number, and it is the second that binds.
/// Per record the sync server allows a megabyte, which 32 KiB — about 43 KiB
/// once base64-encoded — clears by a wide margin. But a push sends every dirty
/// record in **one** request, against a body limit of 8 MiB, so the real
/// question is how many marked servers can be pushed at once: at this size,
/// around 190 of them all carrying a maximum-size image, which is far past any
/// real collection. (Batching that push by size is the structural fix and is a
/// change to the sync engine, not to this constant.)
///
/// The app re-encodes every import rather than trusting its size, stepping the
/// dimensions down until the PNG fits; this is the backstop for a record
/// arriving from somewhere else.
const int kMaxServerIconImageBytes = 32 * 1024;

/// A PNG's first eight bytes. Imports are re-encoded to PNG, so a mark that is
/// not one did not come from this app, and the alternative to checking is
/// handing arbitrary bytes to an image decoder.
const List<int> _pngSignature = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
];

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
  // Control characters are not marks, and a record could carry one.
  for (final unit in trimmed.codeUnits) {
    if (unit < 0x20 || (unit >= 0x7F && unit <= 0x9F)) return null;
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
  return decodeServerIconImage(trimmed) == null ? null : trimmed;
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
/// Bounded, and cleared wholesale rather than evicted one at a time: the cap is
/// far above the number of servers anyone configures, so in practice it never
/// trips, and a cache that never trips does not need a policy.
final Map<String, Uint8List> _decodedIconImages = {};
const int _decodedIconImageLimit = 256;

/// The bytes behind an image mark, or null when the value is not a PNG this
/// build will carry.
///
/// The result is an unmodifiable view: it is shared between every caller that
/// passes the same stored value (see [_decodedIconImages]), so writing through
/// it would reach all of them.
Uint8List? decodeServerIconImage(String base64Png) {
  final cached = _decodedIconImages[base64Png];
  if (cached != null) return cached;
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
  if (bytes.length < _pngSignature.length) return null;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return null;
  }
  if (_decodedIconImages.length >= _decodedIconImageLimit) {
    _decodedIconImages.clear();
  }
  return _decodedIconImages[base64Png] = bytes.asUnmodifiableView();
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
ServerIcon? serverIconFromName(String? name) {
  if (name == null) return null;
  for (final i in ServerIcon.values) {
    if (i.name == name) return i;
  }
  return null;
}
