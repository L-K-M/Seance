import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/hyperlinks.dart';

class CursorStyle {
  int foreground;

  int background;

  int attrs;

  CursorStyle({this.foreground = 0, this.background = 0, this.attrs = 0});

  static final empty = CursorStyle();

  void setBold() {
    attrs |= CellAttr.bold;
  }

  void setFaint() {
    attrs |= CellAttr.faint;
  }

  void setItalic() {
    attrs |= CellAttr.italic;
  }

  void setUnderline() {
    attrs |= CellAttr.underline;
  }

  void setBlink() {
    attrs |= CellAttr.blink;
  }

  void setInverse() {
    attrs |= CellAttr.inverse;
  }

  void setInvisible() {
    attrs |= CellAttr.invisible;
  }

  void setStrikethrough() {
    attrs |= CellAttr.strikethrough;
  }

  void unsetBold() {
    attrs &= ~CellAttr.bold;
  }

  void unsetFaint() {
    attrs &= ~CellAttr.faint;
  }

  void unsetItalic() {
    attrs &= ~CellAttr.italic;
  }

  void unsetUnderline() {
    attrs &= ~CellAttr.underline;
  }

  void unsetBlink() {
    attrs &= ~CellAttr.blink;
  }

  void unsetInverse() {
    attrs &= ~CellAttr.inverse;
  }

  void unsetInvisible() {
    attrs &= ~CellAttr.invisible;
  }

  void unsetStrikethrough() {
    attrs &= ~CellAttr.strikethrough;
  }

  /// [seance fork] Id of the OSC 8 hyperlink that cells written with this
  /// style belong to, [noHyperlink] when there is none. It lives in the high
  /// bits of [attrs] so that writing a cell carries it without a second field.
  int get hyperlinkId =>
      (attrs & CellAttr.hyperlinkMask) >> CellAttr.hyperlinkShift;

  set hyperlinkId(int id) {
    assert(id >= noHyperlink && id <= maxHyperlinkId);
    attrs = (attrs & CellAttr.styleMask) | (id << CellAttr.hyperlinkShift);
  }

  bool get isBold => (attrs & CellAttr.bold) != 0;

  bool get isFaint => (attrs & CellAttr.faint) != 0;

  bool get isItalis => (attrs & CellAttr.italic) != 0;

  bool get isUnderline => (attrs & CellAttr.underline) != 0;

  bool get isBlink => (attrs & CellAttr.blink) != 0;

  bool get isInverse => (attrs & CellAttr.inverse) != 0;

  bool get isInvisible => (attrs & CellAttr.invisible) != 0;

  void setForegroundColor16(int color) {
    foreground = color | CellColor.named;
  }

  void setForegroundColor256(int color) {
    foreground = color | CellColor.palette;
  }

  void setForegroundColorRgb(int r, int g, int b) {
    foreground = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetForegroundColor() {
    foreground = 0; // | CellColor.normal;
  }

  void setBackgroundColor16(int color) {
    background = color | CellColor.named;
  }

  void setBackgroundColor256(int color) {
    background = color | CellColor.palette;
  }

  void setBackgroundColorRgb(int r, int g, int b) {
    background = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetBackgroundColor() {
    background = 0; // | CellColor.normal;
  }

  void reset() {
    foreground = 0;
    background = 0;
    // [seance fork] SGR 0 resets the style, not the hyperlink: OSC 8 is a
    // state of its own, closed only by `OSC 8 ; ; ST`. Programs reset colors
    // inside a link routinely — clearing it here would drop the target
    // halfway through the text it belongs to.
    attrs &= CellAttr.hyperlinkMask;
  }
}

class CursorPosition {
  int x;

  int y;

  CursorPosition(this.x, this.y);
}
