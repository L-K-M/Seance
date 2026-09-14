import 'package:xterm/src/utils/hash_values.dart';

class CellData {
  CellData({
    required this.foreground,
    required this.background,
    required this.flags,
    required this.content,
  });

  factory CellData.empty() {
    return CellData(
      foreground: 0,
      background: 0,
      flags: 0,
      content: 0,
    );
  }

  int foreground;

  int background;

  int flags;

  int content;

  int getHash() {
    // [seance fork] The hyperlink id shares the attribute word but changes
    // nothing about how a cell is painted. Masking it out keeps the paragraph
    // cache at one entry per glyph and style instead of one per link.
    return hashValues(
      foreground,
      background,
      flags & CellAttr.styleMask,
      content,
    );
  }

  @override
  String toString() {
    return 'CellData{foreground: $foreground, background: $background, flags: $flags, content: $content}';
  }
}

abstract class CellAttr {
  static const bold = 1 << 0;
  static const faint = 1 << 1;
  static const italic = 1 << 2;
  static const underline = 1 << 3;
  static const blink = 1 << 4;
  static const inverse = 1 << 5;
  static const invisible = 1 << 6;
  static const strikethrough = 1 << 7;

  /// [seance fork] Style flags occupy the low byte of a cell's attribute word;
  /// the rest carries the id of the OSC 8 hyperlink the cell belongs to (0 for
  /// none). Packing it here rather than adding a fifth word per cell leaves
  /// the scrollback's memory untouched and makes every path that already
  /// copies a cell (`setCell`, `copyFrom`, the reflow) carry the link along.
  static const styleMask = (1 << 8) - 1;

  static const hyperlinkShift = 8;

  static const hyperlinkMask = 0xFFFFFF << hyperlinkShift;
}

abstract class CellColor {
  static const valueMask = 0xFFFFFF;

  static const typeShift = 25;
  static const typeMask = 3 << typeShift;

  static const normal = 0 << typeShift;
  static const named = 1 << typeShift;
  static const palette = 2 << typeShift;
  static const rgb = 3 << typeShift;
}

abstract class CellContent {
  static const codepointMask = 0x1fffff;

  static const widthShift = 22;
  // static const widthMask = 3 << widthShift;
}
