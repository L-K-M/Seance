import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One installed family, and whether it looked fixed-pitch.
class SystemFontFamily implements Comparable<SystemFontFamily> {
  final String name;

  /// The font declared itself fixed-pitch (`post.isFixedPitch`, or a PANOSE
  /// proportion of "monospaced"). Advisory: a family with several faces is
  /// monospaced here if *any* face said so.
  final bool monospaced;

  const SystemFontFamily({required this.name, required this.monospaced});

  /// Case-insensitive by name, so the picker's order does not depend on
  /// whether a foundry capitalized its family.
  @override
  int compareTo(SystemFontFamily other) =>
      name.toLowerCase().compareTo(other.name.toLowerCase());

  @override
  String toString() => monospaced ? '$name (mono)' : name;
}

/// The font families installed on the host, so the terminal's font can be
/// picked from a list instead of typed from memory.
///
/// Read straight out of the font files rather than through a platform channel
/// or a plugin dependency: every desktop keeps its fonts in a handful of known
/// directories, in the one container format (`sfnt` — `.ttf`/`.otf`/`.ttc`)
/// whose `name` table carries the family name the OS itself advertises. That
/// is the name Flutter needs, because `TextStyle.fontFamily` is handed to the
/// platform's font manager unchanged — which is how `SeanceTheme.monoFallback`
/// can already name Menlo and Consolas without bundling either.
///
/// Nothing here is authoritative about what will *render*: a family the OS has
/// registered but the engine declines is still listed. That is why the
/// settings field stays free text — the picker is a convenience over it, not a
/// replacement for it.
///
/// Injectable so the settings UI can be tested without the host's fonts.
abstract interface class SystemFonts {
  /// Whether this platform has font directories worth scanning. False on
  /// Android and iOS: an app there sees the system faces it is given, not a
  /// user-managed collection, so a picker would list a handful of names that
  /// are already in the fallback stack.
  bool get isSupported;

  /// The installed families, deduplicated and sorted. Empty when unsupported
  /// or when nothing could be read.
  Future<List<SystemFontFamily>> families();
}

/// Reports nothing. The default wherever scanning is not supported, and the
/// stand-in in tests that must not touch the host.
class NoSystemFonts implements SystemFonts {
  const NoSystemFonts();

  @override
  bool get isSupported => false;

  @override
  Future<List<SystemFontFamily>> families() async => const [];
}

/// Scans the host's font directories. The result is cached for the process:
/// fonts are not installed while a dialog is open, and re-reading a few
/// hundred file headers on every rebuild would be felt.
class SfntSystemFonts implements SystemFonts {
  /// Stop after this many font files. A pathological collection should not
  /// turn opening Settings into a directory walk without end; 4000 is an order
  /// of magnitude past a heavily loaded designer's machine.
  static const int maxFiles = 4000;

  static const _extensions = {'.ttf', '.otf', '.ttc', '.otc'};

  final List<Directory> _roots;
  Future<List<SystemFontFamily>>? _cached;

  SfntSystemFonts({List<Directory>? roots})
      : _roots = roots ?? _platformRoots();

  @override
  bool get isSupported => _roots.isNotEmpty;

  @override
  Future<List<SystemFontFamily>> families() => _cached ??= _scan();

  /// Where each desktop keeps fonts. Ordered system-first, so a user copy of a
  /// family does not change the name reported for it.
  static List<Directory> _platformRoots() {
    final env = Platform.environment;
    final home = env['HOME'] ?? '';
    if (Platform.isLinux) {
      final dataHome = env['XDG_DATA_HOME'];
      return _existing([
        '/usr/share/fonts',
        '/usr/local/share/fonts',
        if (dataHome != null && dataHome.isNotEmpty) '$dataHome/fonts',
        if (home.isNotEmpty) '$home/.local/share/fonts',
        if (home.isNotEmpty) '$home/.fonts',
      ]);
    }
    if (Platform.isMacOS) {
      return _existing([
        '/System/Library/Fonts',
        '/Library/Fonts',
        if (home.isNotEmpty) '$home/Library/Fonts',
      ]);
    }
    if (Platform.isWindows) {
      final windir = env['WINDIR'] ?? r'C:\Windows';
      final localAppData = env['LOCALAPPDATA'];
      return _existing([
        '$windir\\Fonts',
        // Per-user installs since Windows 10 1809, which never reach the
        // system directory.
        if (localAppData != null && localAppData.isNotEmpty)
          '$localAppData\\Microsoft\\Windows\\Fonts',
      ]);
    }
    return const [];
  }

  static List<Directory> _existing(List<String> paths) {
    final dirs = <Directory>[];
    for (final path in paths) {
      final dir = Directory(path);
      // A missing or unreadable root is normal (no ~/.fonts, a locked-down
      // /Library), so it is skipped rather than reported.
      try {
        if (dir.existsSync()) dirs.add(dir);
      } on FileSystemException {
        continue;
      }
    }
    return dirs;
  }

  Future<List<SystemFontFamily>> _scan() async {
    // Name -> monospaced, so several faces of one family collapse to one entry
    // and any fixed-pitch face marks the family.
    final found = <String, bool>{};
    var files = 0;
    for (final root in _roots) {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      ).handleError((_) {}, test: (e) => e is FileSystemException)) {
        if (files >= maxFiles) break;
        if (entity is! File) continue;
        final dot = entity.path.lastIndexOf('.');
        if (dot < 0) continue;
        if (!_extensions.contains(entity.path.substring(dot).toLowerCase())) {
          continue;
        }
        files++;
        for (final face in await readSfntFamilies(entity)) {
          found[face.name] = (found[face.name] ?? false) || face.monospaced;
        }
      }
    }
    final families = [
      for (final entry in found.entries)
        SystemFontFamily(name: entry.key, monospaced: entry.value),
    ]..sort();
    return List.unmodifiable(families);
  }
}

/// The families [file] declares — several for a `.ttc` collection, one
/// otherwise. Empty for anything that does not parse; a font collection always
/// holds some file this build cannot read, and one of them must not cost the
/// rest of the list.
Future<List<SystemFontFamily>> readSfntFamilies(File file) async {
  RandomAccessFile? handle;
  try {
    handle = await file.open();
    return await _readCollection(handle);
  } on FileSystemException {
    return const [];
  } on _MalformedFont {
    return const [];
  } finally {
    await handle?.close();
  }
}

/// Signals a font whose structure does not hold up. Thrown rather than
/// returned so the byte readers below can stay expression-shaped.
class _MalformedFont implements Exception {
  const _MalformedFont();
}

const int _ttcfTag = 0x74746366; // 'ttcf'

Future<List<SystemFontFamily>> _readCollection(RandomAccessFile handle) async {
  final head = await _readAt(handle, 0, 12);
  if (head.getUint32(0) == _ttcfTag) {
    final numFonts = head.getUint32(8);
    // A collection with an implausible font count is a file that is not one.
    if (numFonts == 0 || numFonts > 1024) return const [];
    final offsets = await _readAt(handle, 12, numFonts * 4);
    final families = <SystemFontFamily>[];
    for (var i = 0; i < numFonts; i++) {
      final face = await _readFace(handle, offsets.getUint32(i * 4));
      if (face != null) families.add(face);
    }
    return families;
  }
  final face = await _readFace(handle, 0);
  return face == null ? const [] : [face];
}

/// One sfnt font, starting at [base].
Future<SystemFontFamily?> _readFace(
  RandomAccessFile handle,
  int base,
) async {
  final header = await _readAt(handle, base, 12);
  final numTables = header.getUint16(4);
  if (numTables == 0 || numTables > 512) return null;
  final directory = await _readAt(handle, base + 12, numTables * 16);

  int? nameOffset, nameLength, postOffset, os2Offset;
  for (var i = 0; i < numTables; i++) {
    final record = i * 16;
    final tag = _tag(directory, record);
    final offset = directory.getUint32(record + 8);
    final length = directory.getUint32(record + 12);
    switch (tag) {
      case 'name':
        nameOffset = offset;
        nameLength = length;
      case 'post':
        postOffset = offset;
      case 'OS/2':
        os2Offset = offset;
    }
  }
  if (nameOffset == null || nameLength == null || nameLength < 6) return null;

  final name = _familyName(await _readAt(handle, nameOffset, nameLength));
  if (name == null) return null;
  return SystemFontFamily(
    name: name,
    monospaced: await _isFixedPitch(handle, postOffset, os2Offset),
  );
}

String _tag(ByteData data, int offset) => String.fromCharCodes([
  data.getUint8(offset),
  data.getUint8(offset + 1),
  data.getUint8(offset + 2),
  data.getUint8(offset + 3),
]);

/// The family name from a `name` table.
///
/// Prefers nameID 16 (typographic family) over nameID 1 (family), because for
/// a family with more than four weights nameID 1 is split per subfamily —
/// "Roboto Light" and "Roboto" would otherwise list as unrelated families,
/// while nameID 16 says "Roboto" for both. Within a nameID, a Windows/Unicode
/// record (UTF-16BE) wins over a Macintosh one, which is read as ASCII.
String? _familyName(ByteData name) {
  final count = name.getUint16(2);
  final storage = name.getUint16(4);
  String? typographic;
  String? family;
  for (var i = 0; i < count; i++) {
    final record = 6 + i * 12;
    // A count that overruns the table is a malformed font, not a short read.
    if (record + 12 > name.lengthInBytes) break;
    final nameId = name.getUint16(record + 6);
    if (nameId != 1 && nameId != 16) continue;
    final platformId = name.getUint16(record);
    final length = name.getUint16(record + 8);
    final offset = storage + name.getUint16(record + 10);
    if (length == 0 || offset + length > name.lengthInBytes) continue;
    final value = _decodeName(name, platformId, offset, length);
    if (value == null || value.isEmpty) continue;
    if (nameId == 16) {
      typographic ??= value;
      if (platformId == 3 || platformId == 0) typographic = value;
    } else {
      family ??= value;
      if (platformId == 3 || platformId == 0) family = value;
    }
  }
  return typographic ?? family;
}

String? _decodeName(ByteData name, int platformId, int offset, int length) {
  // Platform 1 is Macintosh: one byte per character. Only the ASCII range is
  // read, which every Latin family name lives in; a MacRoman accent would
  // decode wrong, and those files carry a platform 0 or 3 record too.
  if (platformId == 1) {
    final bytes = <int>[];
    for (var i = 0; i < length; i++) {
      final byte = name.getUint8(offset + i);
      if (byte >= 0x80) return null;
      bytes.add(byte);
    }
    return ascii.decode(bytes).trim();
  }
  // Platforms 0 (Unicode) and 3 (Windows) are UTF-16BE.
  if (length.isOdd) return null;
  final units = <int>[];
  for (var i = 0; i < length; i += 2) {
    units.add(name.getUint16(offset + i));
  }
  return String.fromCharCodes(units).trim();
}

/// Whether the face declares itself fixed-pitch.
///
/// `post.isFixedPitch` is the direct answer and is what fontconfig and
/// DirectWrite consult first. PANOSE is the fallback: a proportion of 9
/// ("monospaced") on a Latin-text family. Measuring advance widths would be
/// more certain and would mean reading `hmtx` for every face in the
/// collection; the flag is what the foundries set and what the OS believes.
Future<bool> _isFixedPitch(
  RandomAccessFile handle,
  int? postOffset,
  int? os2Offset,
) async {
  if (postOffset != null) {
    // version(4) italicAngle(4) underlinePosition(2) underlineThickness(2)
    // then isFixedPitch at 12.
    final post = await _readAt(handle, postOffset, 16);
    if (post.getUint32(12) != 0) return true;
  }
  if (os2Offset != null) {
    // PANOSE is 10 bytes at offset 32; byte 0 is the family type and byte 3
    // the proportion.
    final os2 = await _readAt(handle, os2Offset, 42);
    if (os2.getUint8(32) == 2 && os2.getUint8(35) == 9) return true;
  }
  return false;
}

/// Exactly [length] bytes at [offset]. A short read means the file is not the
/// font its table directory claims.
Future<ByteData> _readAt(
  RandomAccessFile handle,
  int offset,
  int length,
) async {
  if (offset < 0 || length <= 0) throw const _MalformedFont();
  await handle.setPosition(offset);
  final bytes = await handle.read(length);
  if (bytes.length < length) throw const _MalformedFont();
  return ByteData.sublistView(Uint8List.fromList(bytes));
}
