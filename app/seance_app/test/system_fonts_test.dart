import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/system_fonts.dart';

/// The `sfnt` reader behind the terminal's font picker. Driven with fonts
/// assembled here rather than the host's collection, so the cases that matter
/// — a family split per weight, a Macintosh-only name record, a collection, a
/// truncated file — are all reachable and none of them depend on what happens
/// to be installed on the machine running the suite.
void main() {
  /// A minimal single-face font: an sfnt header, a table directory, and the
  /// three tables the reader looks at.
  Uint8List sfnt({
    String? family,
    String? typographicFamily,
    bool fixedPitchFlag = false,
    bool panoseMono = false,
    int platformId = 3,
    int sfntVersion = 0x00010000,
  }) {
    final names = <(int nameId, String value)>[
      if (family != null) (1, family),
      if (typographicFamily != null) (16, typographicFamily),
    ];

    List<int> encode(String value) => platformId == 1
        ? value.codeUnits
        : [
            for (final unit in value.codeUnits) ...[unit >> 8, unit & 0xFF],
          ];

    // name: version, count, storageOffset, records, then the strings.
    final storageOffset = 6 + names.length * 12;
    final strings = <int>[];
    final records = <int>[];
    void u16(List<int> out, int v) => out.addAll([v >> 8, v & 0xFF]);
    for (final (nameId, value) in names) {
      final bytes = encode(value);
      u16(records, platformId);
      u16(records, platformId == 1 ? 0 : 1);
      u16(records, platformId == 1 ? 0 : 0x0409);
      u16(records, nameId);
      u16(records, bytes.length);
      u16(records, strings.length);
      strings.addAll(bytes);
    }
    final name = <int>[];
    u16(name, 0);
    u16(name, names.length);
    u16(name, storageOffset);
    name.addAll(records);
    name.addAll(strings);

    // post: version, italicAngle, underlinePosition, underlineThickness, then
    // isFixedPitch at offset 12.
    final post = List<int>.filled(32, 0);
    post[1] = 0x02; // version 2.0
    if (fixedPitchFlag) post[15] = 1;

    // OS/2: PANOSE is 10 bytes at offset 32 — family type at 0, proportion
    // at 3, so 32 and 35 here.
    final os2 = List<int>.filled(96, 0);
    if (panoseMono) {
      os2[32] = 2; // Latin text
      os2[35] = 9; // monospaced
    }

    final tables = <(String, List<int>)>[
      ('OS/2', os2),
      ('name', name),
      ('post', post),
    ];

    final out = <int>[];
    void u32(List<int> o, int v) =>
        o.addAll([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
    u32(out, sfntVersion);
    u16(out, tables.length);
    u16(out, 0);
    u16(out, 0);
    u16(out, 0);
    var offset = 12 + tables.length * 16;
    for (final (tag, data) in tables) {
      out.addAll(tag.codeUnits);
      u32(out, 0); // checksum, unread
      u32(out, offset);
      u32(out, data.length);
      offset += data.length;
    }
    for (final (_, data) in tables) {
      out.addAll(data);
    }
    return Uint8List.fromList(out);
  }

  /// A `.ttc` wrapping [faces]: the collection header, one offset per face,
  /// then the faces themselves.
  Uint8List ttc(List<Uint8List> faces) {
    final out = <int>[];
    void u16(int v) => out.addAll([v >> 8, v & 0xFF]);
    void u32(int v) => out
        .addAll([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
    out.addAll('ttcf'.codeUnits);
    u16(1);
    u16(0);
    u32(faces.length);
    // A face's table offsets are absolute from the start of the *file*, so a
    // face pasted at [base] needs every offset in its directory shifted by
    // that much — which is what a real collection stores.
    final bases = <int>[];
    var base = 12 + faces.length * 4;
    for (final face in faces) {
      bases.add(base);
      u32(base);
      base += face.length;
    }
    for (var i = 0; i < faces.length; i++) {
      final face = Uint8List.fromList(faces[i]);
      final view = ByteData.sublistView(face);
      final numTables = view.getUint16(4);
      for (var t = 0; t < numTables; t++) {
        final record = 12 + t * 16;
        view.setUint32(record + 8, view.getUint32(record + 8) + bases[i]);
      }
      out.addAll(face);
    }
    return Uint8List.fromList(out);
  }

  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-fonts-');
  });

  tearDown(() => directory.delete(recursive: true));

  Future<List<SystemFontFamily>> read(String fileName, List<int> bytes) async {
    final file = File('${directory.path}/$fileName');
    await file.writeAsBytes(bytes);
    return readSfntFamilies(file);
  }

  group('reading one face', () {
    test('reports the family name', () async {
      expect(
        await read('a.ttf', sfnt(family: 'Iosevka')),
        [
          isA<SystemFontFamily>()
              .having((f) => f.name, 'name', 'Iosevka')
              .having((f) => f.monospaced, 'monospaced', isFalse),
        ],
      );
    });

    test('prefers the typographic family over the per-weight one', () async {
      // The case this exists for: a family with more than four weights splits
      // nameID 1 per subfamily, so "Berkeley Mono Light" and "Berkeley Mono"
      // would list as two unrelated families.
      final families = await read(
        'a.ttf',
        sfnt(family: 'Berkeley Mono Light', typographicFamily: 'Berkeley Mono'),
      );
      expect(families.single.name, 'Berkeley Mono');
    });

    test('reads a Macintosh-only name record as ASCII', () async {
      final families = await read(
        'a.ttf',
        sfnt(family: 'Monaco', platformId: 1),
      );
      expect(families.single.name, 'Monaco');
    });

    test('accepts an OpenType/CFF face', () async {
      final families = await read(
        'a.otf',
        // 'OTTO'
        sfnt(family: 'Fira Code', sfntVersion: 0x4F54544F),
      );
      expect(families.single.name, 'Fira Code');
    });

    test('marks fixed pitch from post.isFixedPitch', () async {
      final families = await read(
        'a.ttf',
        sfnt(family: 'JetBrains Mono', fixedPitchFlag: true),
      );
      expect(families.single.monospaced, isTrue);
    });

    test('marks fixed pitch from a monospaced PANOSE proportion', () async {
      // The fallback for faces that leave post.isFixedPitch at zero.
      final families = await read(
        'a.ttf',
        sfnt(family: 'Menlo', panoseMono: true),
      );
      expect(families.single.monospaced, isTrue);
    });
  });

  group('reading a collection', () {
    test('reports every face in a .ttc', () async {
      final families = await read(
        'a.ttc',
        ttc([
          sfnt(family: 'Menlo', fixedPitchFlag: true),
          sfnt(family: 'Helvetica'),
        ]),
      );
      expect(families.map((f) => f.name), ['Menlo', 'Helvetica']);
      expect(families.first.monospaced, isTrue);
      expect(families.last.monospaced, isFalse);
    });
  });

  group('malformed input', () {
    test('one bad face does not discard the rest of a collection', () async {
      // A .ttc holds dozens of faces; letting one throw reach the caller
      // would discard the ones already read.
      final good = sfnt(family: 'Menlo', fixedPitchFlag: true);
      final collection = Uint8List.fromList(ttc([good, sfnt(family: 'Gone')]));
      // Truncate the second face's table directory by pointing it past EOF.
      final view = ByteData.sublistView(collection);
      view.setUint32(16, collection.length + 4096);
      expect(
        (await read('a.ttc', collection)).map((f) => f.name),
        ['Menlo'],
      );
    });

    test('an absurd name table length is refused, not allocated', () async {
      // The length is an untrusted uint32; reading one as declared would try
      // to allocate gigabytes before any field was inspected.
      final bytes = sfnt(family: 'Iosevka');
      final view = ByteData.sublistView(bytes);
      // The table directory starts at 12; entries are 16 bytes, and 'name' is
      // the second of the three this builder writes.
      for (var i = 0; i < 3; i++) {
        final record = 12 + i * 16;
        final tag = String.fromCharCodes(bytes.sublist(record, record + 4));
        if (tag == 'name') view.setUint32(record + 12, 0xFFFFFFF0);
      }
      expect(await read('a.ttf', bytes), isEmpty);
    });

    test('a truncated font yields nothing rather than throwing', () async {
      final full = sfnt(family: 'Iosevka');
      expect(await read('a.ttf', full.sublist(0, full.length ~/ 2)), isEmpty);
    });

    test('a file that is not a font at all yields nothing', () async {
      expect(await read('a.ttf', List.filled(400, 0x41)), isEmpty);
    });

    test('an empty file yields nothing', () async {
      expect(await read('a.ttf', const []), isEmpty);
    });

    test('an implausible face count is refused', () async {
      final bytes = sfnt(family: 'Iosevka');
      // numTables lives at offset 4; 0xFFFF tables is not a font.
      bytes[4] = 0xFF;
      bytes[5] = 0xFF;
      expect(await read('a.ttf', bytes), isEmpty);
    });
  });

  group('scanning a directory', () {
    test('collapses faces of one family and marks it mono if any face is',
        () async {
      await File('${directory.path}/regular.ttf').writeAsBytes(
        sfnt(family: 'Hack'),
      );
      await File('${directory.path}/bold.ttf').writeAsBytes(
        sfnt(family: 'Hack', fixedPitchFlag: true),
      );
      final nested = await Directory('${directory.path}/nested').create();
      await File('${nested.path}/other.otf').writeAsBytes(
        sfnt(family: 'Cantarell'),
      );
      // Deliberately a *readable font* under a non-font extension, so this
      // proves the file is skipped for its name rather than for failing to
      // parse — with plain text inside, both behaviours look identical.
      await File('${directory.path}/notes.txt').writeAsBytes(
        sfnt(family: 'Invisible'),
      );

      final fonts = SfntSystemFonts(roots: [directory]);
      expect(fonts.isSupported, isTrue);
      final families = await fonts.families();
      expect(families.map((f) => f.name), ['Cantarell', 'Hack']);
      expect(families.last.monospaced, isTrue);
    });

    test('a font installed as a symlink is found', () async {
      // Not exotic: a manual `ln -s` into ~/.fonts, a distro linking into a
      // package store, and on Nix essentially every font. Unfollowed they
      // arrive as Link rather than File and vanish from the picker.
      final store = await Directory('${directory.path}/store').create();
      await File('${store.path}/real.ttf').writeAsBytes(sfnt(family: 'Hack'));
      final visible = await Directory('${directory.path}/fonts').create();
      await Link('${visible.path}/link.ttf').create('${store.path}/real.ttf');

      final fonts = SfntSystemFonts(roots: [visible]);
      expect((await fonts.families()).map((f) => f.name), ['Hack']);
    });

    test('a link that points at an ancestor does not rescan the tree',
        () async {
      // Following links means a cycle is reachable; each real file must still
      // be parsed once, or one loop would spend the whole file budget on
      // fonts already seen.
      await File('${directory.path}/a.ttf').writeAsBytes(sfnt(family: 'Hack'));
      await File('${directory.path}/b.ttf').writeAsBytes(
        sfnt(family: 'Cantarell'),
      );
      await Link('${directory.path}/loop').create(directory.path);

      final fonts = SfntSystemFonts(roots: [directory]);
      final families = await fonts.families();
      expect(families.map((f) => f.name), ['Cantarell', 'Hack']);
    });

    test('the same root twice is walked once', () async {
      // XDG_DATA_HOME set to its own default makes this the normal case.
      await File('${directory.path}/a.ttf').writeAsBytes(sfnt(family: 'Hack'));
      final fonts = SfntSystemFonts(roots: [directory, directory]);
      expect((await fonts.families()).length, 1);
    });

    test('one family spelled two ways collapses to one entry', () async {
      // The list sorts case-insensitively, so keying by exact spelling would
      // leave two rows that look identical sitting next to each other.
      await File('${directory.path}/a.ttf').writeAsBytes(
        sfnt(family: 'JetBrains Mono'),
      );
      await File('${directory.path}/b.ttf').writeAsBytes(
        sfnt(family: 'JETBRAINS MONO', fixedPitchFlag: true),
      );
      final families = await SfntSystemFonts(roots: [directory]).families();
      expect(families.length, 1);
      expect(
        families.single.monospaced,
        isTrue,
        reason: 'any face declaring fixed pitch marks the family',
      );
    });

    test('one unreadable file does not cost the rest of the scan', () async {
      // The result is cached for the life of the process, so an error escaping
      // here would leave the picker empty until the app restarted.
      await File('${directory.path}/good.ttf').writeAsBytes(
        sfnt(family: 'Hack'),
      );
      await File('${directory.path}/bad.ttf').writeAsBytes(
        List.filled(400, 0x41),
      );
      final fonts = SfntSystemFonts(roots: [directory]);
      expect((await fonts.families()).map((f) => f.name), ['Hack']);
      // And the cached future is a value, not a stored error.
      expect((await fonts.families()).map((f) => f.name), ['Hack']);
    });

    test('no roots means unsupported and an empty list', () async {
      final fonts = SfntSystemFonts(roots: const []);
      expect(fonts.isSupported, isFalse);
      expect(await fonts.families(), isEmpty);
    });

    test('the scan runs once per instance', () async {
      final file = File('${directory.path}/a.ttf');
      await file.writeAsBytes(sfnt(family: 'Hack'));
      final fonts = SfntSystemFonts(roots: [directory]);
      expect((await fonts.families()).single.name, 'Hack');
      // A font installed afterwards is deliberately not picked up: the result
      // is read on every rebuild of the settings screen.
      await File('${directory.path}/b.ttf').writeAsBytes(
        sfnt(family: 'Cantarell'),
      );
      expect((await fonts.families()).map((f) => f.name), ['Hack']);
    });

    test('NoSystemFonts reports nothing', () async {
      const fonts = NoSystemFonts();
      expect(fonts.isSupported, isFalse);
      expect(await fonts.families(), isEmpty);
    });
  });
}
