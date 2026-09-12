import 'package:characters/characters.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

/// A server's mark: a built-in glyph, an emoji, or an imported image. The
/// values sync between versions in both directions, so what matters most here
/// is what a build does with a mark it does not fully understand.
void main() {
  /// The smallest thing that passes for a PNG: the signature, an IHDR chunk
  /// declaring 8x8, and padding. The protocol checks the signature, the size
  /// and the declared dimensions, never the pixels — it is not an image
  /// decoder, and the app re-encodes every import anyway.
  Uint8List pngHeader({
    int width = 8,
    int height = 8,
    int tail = 64,
    String chunk = 'IHDR',
    int chunkLength = 13,
  }) =>
      Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        (chunkLength >> 24) & 0xFF, (chunkLength >> 16) & 0xFF,
        (chunkLength >> 8) & 0xFF, chunkLength & 0xFF,
        ...chunk.codeUnits,
        (width >> 24) & 0xFF, (width >> 16) & 0xFF,
        (width >> 8) & 0xFF, width & 0xFF,
        (height >> 24) & 0xFF, (height >> 16) & 0xFF,
        (height >> 8) & 0xFF, height & 0xFF,
        ...List.filled(tail, 0),
      ]);
  final png = pngHeader();

  ServerConfig config({
    ServerIcon? icon,
    String? iconEmoji,
    String? iconImage,
  }) => ServerConfig(
        id: 'a',
        label: 'box',
        host: 'h.example.com',
        username: 'deploy',
        icon: icon,
        iconEmoji: iconEmoji,
        iconImage: iconImage,
        createdAt: 1,
        updatedAt: 1,
      );

  group('precedence', () {
    test('an image wins over an emoji, which wins over a glyph', () {
      final all = config(
        icon: ServerIcon.rocket,
        iconEmoji: '\u{1F680}',
        iconImage: base64Encode(png),
      );
      expect(all.mark, isA<ServerImageMark>());
      expect(all.mark.fallback, ServerIcon.rocket);

      expect(
        config(icon: ServerIcon.rocket, iconEmoji: '\u{1F680}').mark,
        ServerEmojiMark('\u{1F680}', fallback: ServerIcon.rocket),
      );
      expect(
        config(icon: ServerIcon.rocket).mark,
        const ServerGlyphMark(ServerIcon.rocket),
      );
      expect(config().mark, const ServerGlyphMark(null));
    });

    test('a richer mark keeps a glyph beside it as its fallback', () {
      // The reason the three are separate fields: a build that has never heard
      // of iconEmoji ignores the key and draws the glyph, which approximates
      // the choice rather than losing it.
      final json = config(icon: ServerIcon.cluster, iconEmoji: '\u{1F433}').toJson();
      expect(json['icon'], 'cluster');
      expect(json['iconEmoji'], '\u{1F433}');
    });

    test('an unusable image falls through to the emoji', () {
      // Not "shows nothing": a device that cannot carry the bytes still knows
      // what the server was marked with.
      final broken = config(iconEmoji: '\u{1F525}', iconImage: 'not base64 at all');
      expect(broken.mark, ServerEmojiMark('\u{1F525}'));
    });
  });

  group('emoji validation', () {
    test('accepts one grapheme cluster, however many code points', () {
      // The astronaut is four code points and one choice, which is what the
      // badge has room for.
      for (final emoji in [
        '\u{1F680}',
        '\u{1F469}\u{1F3FD}\u{200D}\u{1F680}',
        '\u{1F1E8}\u{1F1ED}',
        '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}',
        '☕',
        'A',
      ]) {
        expect(normalizeServerEmoji(emoji), emoji, reason: emoji);
      }
    });

    test('refuses more than one cluster', () {
      expect(normalizeServerEmoji('\u{1F680}\u{1F680}'), isNull);
      expect(normalizeServerEmoji('ab'), isNull);
    });

    test('trims, and treats blank as none', () {
      expect(normalizeServerEmoji(' \u{1F680} '), '\u{1F680}');
      expect(normalizeServerEmoji('   '), isNull);
      expect(normalizeServerEmoji(''), isNull);
      expect(normalizeServerEmoji(null), isNull);
    });

    test('refuses control characters and unbounded joiner chains', () {
      expect(normalizeServerEmoji('\u0000'), isNull);
      expect(normalizeServerEmoji('\u0007'), isNull);
      // One cluster can be extended with joiners indefinitely; a record from
      // elsewhere must not be able to park a kilobyte of them in a config.
      final chain = List.filled(40, '\u{1F469}').join('\u200D');
      expect(chain.characters.length, 1);
      expect(chain.length, greaterThan(64));
      expect(normalizeServerEmoji(chain), isNull);
    });

    test('refuses invisible and bidi formatting characters', () {
      // Each is a single grapheme cluster, so the cluster rule lets it in;
      // each renders as nothing, and the bidi ones reorder the text around
      // wherever the badge's label is drawn.
      for (final invisible in [
        '\u00AD', // soft hyphen
        '\u061C', // Arabic letter mark
        '\u200B', // zero-width space
        '\u200E', // left-to-right mark
        '\u200F', // right-to-left mark
        '\u202E', // right-to-left override
        '\u2060', // word joiner
        '\u2069', // pop directional isolate
        '\uFEFF', // byte order mark
      ]) {
        expect(
          normalizeServerEmoji(invisible),
          isNull,
          reason: 'U+${invisible.codeUnitAt(0).toRadixString(16)}',
        );
      }
    });

    test('refuses unpaired surrogates', () {
      // Ill-formed UTF-16: one grapheme cluster, under the length ceiling,
      // and tofu wherever it is drawn.
      expect(normalizeServerEmoji('\uD800'), isNull);
      expect(normalizeServerEmoji('\uDBFF'), isNull);
      expect(normalizeServerEmoji('\uDC00'), isNull);
      expect(normalizeServerEmoji('\uDFFF'), isNull);
    });

    test('refuses the blank-rendering Hangul fillers', () {
      // Each is one cluster that draws nothing; U+3164 is the well-known
      // invisible-username character.
      for (final filler in ['\u115F', '\u1160', '\u3164', '\uFFA0']) {
        expect(
          normalizeServerEmoji(filler),
          isNull,
          reason: 'U+${filler.codeUnitAt(0).toRadixString(16)}',
        );
      }
    });

    test('refuses the zero-width non-joiner', () {
      // Invisible, one cluster, and no RGI sequence uses it — they join with
      // U+200D, which stays allowed.
      expect(normalizeServerEmoji('\u200C'), isNull);
    });

    test('refuses a cluster that is nothing but a joiner or a mark', () {
      // The character-by-character rules above cannot reach these. U+200D is
      // deliberately allowed, because it is what holds a multi-part emoji
      // together — but alone it is a cluster with nothing to join and the
      // badge draws nothing. The same holds for every combining character: it
      // renders only as part of the character before it, and here there is
      // none.
      // Escaped rather than written literally, like the tests above: an
      // invisible literal is one editor "cleanup" away from being a different
      // test, and a reviewer cannot see which character it is.
      for (final baseless in [
        '\u200D', // zero-width joiner, the carve-out the loop cannot re-catch
        '\uFE0F', // variation selector-16 (emoji presentation)
        '\uFE0E', // variation selector-15 (text presentation)
        '\u0301', // combining acute accent
        '\u034F', // combining grapheme joiner
        '\u20E3', // combining enclosing keycap, without its keycap
        '\uFE20', // combining ligature left half
        // These attach to what *follows* (UAX #29 GB9b) rather than to
        // what precedes, so a probe on one side only reads them as a clean
        // break. Every one is an invisible format character.
        '\u0600', // Arabic number sign
        '\u0605', // Arabic number mark above
        '\u070F', // Syriac abbreviation mark
        '\u0890', // Arabic pound mark above
        '\u{110BD}', // Kaithi number sign
        // Visible on its own, and refused anyway: a spacing mark decorates
        // a character that is not here.
        '\u0903', // Devanagari sign visarga
      ]) {
        expect(
          normalizeServerEmoji(baseless),
          isNull,
          reason: 'U+${baseless.runes.first.toRadixString(16)}',
        );
      }
    });

    test('refuses a lone plane-14 formatting character', () {
      // The whole block is invisible formatting and the code-unit loop cannot
      // see it: every value there is a surrogate pair, and the loop compares
      // BMP units.
      for (final formatting in [
        '\u{E0001}', // language tag
        '\u{E0041}', // tag character 'A'
        '\u{E007F}', // cancel tag
        '\u{E0100}', // variation selector-17
      ]) {
        expect(normalizeServerEmoji(formatting), isNull);
      }
    });

    test('keeps a subdivision flag, whose tail is tag characters', () {
      // The same block, but after a visible base — so the rule has to look at
      // the cluster's first code point only.
      const england = '\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}'
          '\u{E006E}\u{E0067}\u{E007F}';
      expect(england.characters.length, 1);
      expect(normalizeServerEmoji(england), england);
    });

    test('keeps the joiners and modifiers real emoji are built from', () {
      // The filter above must not catch these: U+200D holds a multi-part
      // emoji together, and the rest are how the common ones are spelled.
      for (final emoji in [
        '\u{1F469}\u200D\u{1F692}', // woman firefighter (ZWJ)
        '\u{1F469}\u{1F3FD}', // skin-tone modifier
        '\u2764\uFE0F', // variation selector 16
        '1\uFE0F\u20E3', // keycap sequence
        '\u{1F1E8}\u{1F1ED}', // regional indicator flag
        '\u{1F3F3}\uFE0F\u200D\u{1F308}', // rainbow flag
      ]) {
        expect(normalizeServerEmoji(emoji), emoji);
      }
    });
  });

  group('image validation', () {
    test('round-trips through the stored form', () {
      final stored = encodeServerIconImage(png);
      expect(stored, isNotNull);
      expect(decodeServerIconImage(stored!), png);
    });

    test('the same stored value decodes to the same list', () {
      // Load-bearing, not an optimization: a badge reads `mark` on every build,
      // and Flutter's MemoryImage keys its cache on the identity of the bytes
      // it is handed — a fresh list per build would re-decode the PNG every
      // frame. The list is also shared, so it must not be writable.
      final stored = encodeServerIconImage(png)!;
      final first = decodeServerIconImage(stored);
      expect(identical(decodeServerIconImage(stored), first), isTrue);
      expect(() => first![0] = 0, throwsUnsupportedError);
    });

    test('refuses bytes that are not a PNG', () {
      // Imports are re-encoded to PNG, so anything else did not come from
      // this app, and the alternative to checking is handing arbitrary bytes
      // to an image decoder.
      expect(encodeServerIconImage(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(decodeServerIconImage(base64Encode(List.filled(64, 0x41))), isNull);
      expect(decodeServerIconImage('%%not base64%%'), isNull);
      expect(decodeServerIconImage(''), isNull);
    });

    test('refuses dimensions no badge could need', () {
      // The byte ceiling does not bound what a decoder allocates: PNG
      // compresses a flat colour so well that this header is 24 bytes and
      // asks for a 65535x65535 RGBA buffer at paint time.
      expect(decodeServerIconImage(base64Encode(pngHeader(
        width: 65535,
        height: 65535,
        tail: 0,
      ))), isNull);
      // Zero is not a picture either.
      expect(decodeServerIconImage(base64Encode(pngHeader(width: 0))), isNull);
      expect(decodeServerIconImage(base64Encode(pngHeader(height: 0))), isNull);
      // Truncated before IHDR's dimensions are even readable.
      expect(
        decodeServerIconImage(base64Encode(png.sublist(0, 20))),
        isNull,
      );
      // A plausible size still passes, so the bound is not simply refusing.
      expect(
        decodeServerIconImage(base64Encode(pngHeader(width: 256, height: 256))),
        isNotNull,
      );
    });

    test('resolve accepts exactly what the normalizer accepts', () {
      // base64Decode throws on whitespace, so a padded value the normalizer
      // trims and accepts must not be dropped by resolve instead.
      final padded = '  ${encodeServerIconImage(png)!}\n';
      expect(normalizeServerIconImage(padded), isNotNull);
      expect(ServerMark.resolve(image: padded), isA<ServerImageMark>());
    });

    test('refuses a PNG that does not lead with IHDR', () {
      // The dimension guard reads fixed offsets, which only address the
      // dimensions when IHDR really is the first chunk. A file leading with
      // something else would otherwise be measured on whatever bytes happen
      // to sit there while its real IHDR, further in, declares anything.
      expect(
        decodeServerIconImage(base64Encode(pngHeader(chunk: 'gAMA'))),
        isNull,
      );
      // Right tag, wrong declared length: also not the chunk this assumes.
      expect(
        decodeServerIconImage(base64Encode(pngHeader(chunkLength: 9))),
        isNull,
      );
    });

    test('refuses anything past the record ceiling', () {
      final huge = pngHeader(tail: kMaxServerIconImageBytes);
      expect(encodeServerIconImage(huge), isNull);
      // And the base64 is refused on its length, before it is expanded — a
      // megabyte of text should not become a megabyte of bytes first.
      expect(decodeServerIconImage(base64Encode(huge)), isNull);
    });
  });

  group('records', () {
    test('a mark survives a round trip through JSON', () {
      for (final mark in <ServerMark>[
        const ServerGlyphMark(null),
        const ServerGlyphMark(ServerIcon.dataCenter),
        ServerEmojiMark('\u{1F427}', fallback: ServerIcon.server),
        ServerImageMark(png, fallback: ServerIcon.cloud),
      ]) {
        final fields = mark.stored;
        final restored = ServerConfig.fromJson(
          config(
            icon: fields.icon,
            iconEmoji: fields.emoji,
            iconImage: fields.image,
          ).toJson(),
        );
        expect(restored.mark, mark, reason: '$mark');
      }
    });

    test('a value this build refuses is not re-published', () {
      // Otherwise a device would pass on a mark it could not draw as though it
      // had accepted it, and the refusal on read would be pointless.
      final json = config(icon: ServerIcon.lab).toJson()
        ..['iconEmoji'] = 'far too many characters for one badge'
        ..['iconImage'] = 'not base64';
      final read = ServerConfig.fromJson(json);
      expect(read.iconEmoji, isNull);
      expect(read.iconImage, isNull);
      expect(read.toJson().containsKey('iconEmoji'), isFalse);
      expect(read.toJson().containsKey('iconImage'), isFalse);
      expect(read.mark, const ServerGlyphMark(ServerIcon.lab));
    });

    test('a glyph this build has never heard of decodes to the default', () {
      final json = config(icon: ServerIcon.rocket).toJson()
        ..['icon'] = 'holodeck';
      expect(ServerConfig.fromJson(json).mark, const ServerGlyphMark(null));
    });

    test('separately built marks with the same content are equal', () {
      // The editor shows its "use the default mark" button on
      // `_mark != _defaultMark`, so identity comparison there would show it
      // for a server that already has no mark.
      expect(const ServerGlyphMark(null), ServerGlyphMark(serverIconFromName(
        'nothing-by-this-name',
      )));
      expect(ServerMark.resolve(), const ServerGlyphMark(null));
      expect(
        ServerEmojiMark('\u{1F433}', fallback: ServerIcon.cloud),
        ServerEmojiMark('\u{1F433}', fallback: ServerIcon.cloud),
      );
      expect(
        ServerImageMark(Uint8List.fromList(png), fallback: ServerIcon.web),
        ServerImageMark(Uint8List.fromList(png), fallback: ServerIcon.web),
      );
    });

    test('a mark field of the wrong type costs the field, not the server', () {
      // A record can arrive from a device this one does not control. A cast
      // would throw out of fromJson and drop the whole server, including the
      // fields that were fine.
      for (final bad in [5, <String>[], <String, Object?>{}, true]) {
        final json = config(icon: ServerIcon.rocket).toJson()
          ..['icon'] = bad
          ..['iconEmoji'] = bad
          ..['iconImage'] = bad;
        final decoded = ServerConfig.fromJson(json);
        expect(decoded.mark, const ServerGlyphMark(null));
        expect(decoded.host, config().host, reason: 'the rest survives');
      }
    });

    test('copyWith clears each mark field independently', () {
      final marked = config(
        icon: ServerIcon.rocket,
        iconEmoji: '\u{1F680}',
        iconImage: base64Encode(png),
      );
      expect(
        marked.copyWith(clearIconImage: true).mark,
        ServerEmojiMark('\u{1F680}', fallback: ServerIcon.rocket),
      );
      expect(
        marked.copyWith(clearIconImage: true, clearIconEmoji: true).mark,
        const ServerGlyphMark(ServerIcon.rocket),
      );
      // And carries them when nothing says otherwise, which is what
      // duplicating a server relies on.
      expect(marked.copyWith(label: 'copy').mark, marked.mark);
    });
  });

  group('the glyph vocabulary', () {
    test('the sixteen original names keep their spelling', () {
      // The names are the wire format: renaming one would silently drop the
      // icon from every record that used it.
      expect(ServerIcon.values.take(16).map((i) => i.name), [
        'server',
        'cloud',
        'database',
        'web',
        'terminal',
        'shield',
        'home',
        'work',
        'lab',
        'device',
        'router',
        'mail',
        'container',
        'rocket',
        'star',
        'bug',
      ]);
    });

    test('every name decodes back to itself', () {
      for (final icon in ServerIcon.values) {
        expect(serverIconFromName(icon.name), icon, reason: icon.name);
      }
      expect(serverIconFromName('nonesuch'), isNull);
      expect(serverIconFromName(null), isNull);
    });
  });
}
