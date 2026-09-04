import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  Terminal terminalWith(String text, {int width = 80}) => Terminal()
    ..resize(width, 5)
    ..write(text);

  test('finds web URLs without surrounding prose punctuation', () {
    const text = 'See (https://example.com/a_(b)?x=1#c).';
    final terminal = terminalWith(text);
    expect(
      terminal.buffer.getLinkAt(const CellOffset(12, 0)).toString(),
      'https://example.com/a_(b)?x=1#c',
    );
    expect(terminal.buffer.getLinkAt(const CellOffset(0, 0)), isNull);
    expect(terminal.buffer.getLinkAt(CellOffset(text.length - 1, 0)), isNull);
  });

  test('supports HTTP, mixed case, ports and multiple links', () {
    final terminal = terminalWith(
      'HTTP://localhost:8080/a https://example.org',
    );
    expect(
      terminal.buffer.getLinkAt(const CellOffset(5, 0)),
      Uri.parse('http://localhost:8080/a'),
    );
    expect(
      terminal.buffer.getLinkAt(const CellOffset(30, 0)),
      Uri.parse('https://example.org'),
    );
  });

  test('joins soft wraps but not hard newlines', () {
    final terminal = terminalWith('https://example.com/long/path', width: 12);
    expect(
      terminal.buffer.getLinkAt(const CellOffset(2, 1)),
      Uri.parse('https://example.com/long/path'),
    );

    final hard = terminalWith('https://one.test\r\nhttps://two.test');
    expect(
      hard.buffer.getLinkAt(const CellOffset(2, 1)),
      Uri.parse('https://two.test'),
    );
  });

  test('uses cell positions after wide and non-BMP characters', () {
    final terminal = terminalWith('界😀 https://example.com');
    expect(
      terminal.buffer.getLinkAt(const CellOffset(5, 0)),
      Uri.parse('https://example.com'),
    );
    expect(terminal.buffer.getLinkAt(const CellOffset(4, 0)), isNull);
  });

  test('reads painted text through ANSI styles and scrollback', () {
    final terminal = terminalWith('\x1b[31mhttps://example.com\x1b[0m');
    terminal.write('\r\n1\r\n2\r\n3\r\n4\r\n5');
    expect(
      terminal.buffer.getLinkAt(const CellOffset(2, 0)),
      Uri.parse('https://example.com'),
    );
  });

  test('bounds scanning of unbroken remote output', () {
    final terminal = terminalWith('https://example.com/${'a' * 20000}');
    expect(terminal.buffer.getLinkAt(const CellOffset(2, 0)), isNull);
  });

  test(
    'rejects unsafe schemes, credentials, malformed URLs and empty cells',
    () {
      for (final text in [
        'file:///tmp/a',
        'javascript:alert(1)',
        'ssh://example.com',
        'https://',
        'https://user:password@example.com',
        'https://[invalid',
      ]) {
        final terminal = terminalWith(text);
        expect(
          terminal.buffer.getLinkAt(const CellOffset(2, 0)),
          isNull,
          reason: text,
        );
      }
      final terminal = terminalWith('https://example.com');
      for (final cell in [
        const CellOffset(-1, 0),
        const CellOffset(80, 0),
        const CellOffset(0, -1),
        const CellOffset(0, 5),
        const CellOffset(40, 0),
      ]) {
        expect(terminal.buffer.getLinkAt(cell), isNull);
      }
    },
  );
}
