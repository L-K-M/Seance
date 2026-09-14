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

  test('finds visible links after more than a screen of scrollback', () {
    final terminal = terminalWith('${'\r\n' * 10}see https://example.com now');
    expect(terminal.buffer.height, terminal.buffer.lines.length);
    expect(terminal.buffer.scrollBack, greaterThan(terminal.viewHeight));
    expect(terminal.buffer.getLinkAt(const CellOffset(7, 10)),
        Uri.parse('https://example.com'));
  });

  test('joins wrapped URLs at absolute rows beyond the viewport height', () {
    final terminal =
        terminalWith('${'\r\n' * 10}https://example.com/long/path', width: 12);
    for (final row in [10, 11, 12]) {
      expect(terminal.buffer.getLinkAt(CellOffset(2, row)),
          Uri.parse('https://example.com/long/path'));
    }
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

  group('OSC 8 hyperlinks', () {
    const authUrl = 'https://accounts.google.com/signin/continue?sarp=1&scc=1'
        '&continue=https://developers.google.com/gemini-code-assist/auth/'
        'auth_success_gemini&plt=AKgnsbvMnFUSEQgw6JBfDTqw0Qr';

    String link(String target, String text) =>
        '\x1b]8;;$target\x1b\\$text\x1b]8;;\x1b\\';

    test('opens the whole target when the program wrapped the link text', () {
      // What the Antigravity CLI prints on login: one hyperlink whose text is
      // the URL, broken across the CLI's own hard newlines. Reading the text
      // can recover no more than the first line of it.
      final terminal = terminalWith(link(
        authUrl,
        'https://accounts.google.com/signin/continue?sarp=1&scc=1\r\n'
        '&continue=https://developers.google.com/gemini-code-assist/auth/\r\n'
        'auth_success_gemini&plt=AKgnsbvMnFUSEQgw6JBfDTqw0Qr',
      ));
      for (final row in [0, 1, 2]) {
        expect(
          terminal.buffer.getLinkAt(CellOffset(4, row)),
          Uri.parse(authUrl),
          reason: 'row $row',
        );
      }
    });

    test('links text that is not a URL at all', () {
      final terminal = terminalWith(
        '${link('https://example.com/auth', 'Click here to authenticate')} '
        'plain',
      );
      expect(
        terminal.buffer.getLinkAt(const CellOffset(6, 0)),
        Uri.parse('https://example.com/auth'),
      );
      expect(terminal.buffer.getLinkAt(const CellOffset(28, 0)), isNull);
    });

    test('a closing sequence ends the link, a new target replaces it', () {
      final terminal = terminalWith(
        '\x1b]8;;https://one.test\x1b\\one'
        '\x1b]8;;https://two.test\x1b\\two'
        '\x1b]8;;\x1b\\after',
      );
      expect(
        terminal.buffer.getLinkAt(const CellOffset(0, 0)),
        Uri.parse('https://one.test'),
      );
      expect(
        terminal.buffer.getLinkAt(const CellOffset(3, 0)),
        Uri.parse('https://two.test'),
      );
      expect(terminal.buffer.getLinkAt(const CellOffset(7, 0)), isNull);
    });

    test('SGR resets inside a link do not close it', () {
      final terminal = terminalWith(
        link('https://example.com/x', '\x1b[34mblue\x1b[0mplain'),
      );
      for (final x in [0, 6]) {
        expect(
          terminal.buffer.getLinkAt(CellOffset(x, 0)),
          Uri.parse('https://example.com/x'),
          reason: 'cell $x',
        );
      }
    });

    test('ignores the id parameter and keeps semicolons in the target', () {
      final terminal =
          terminalWith('\x1b]8;id=42;https://example.com/a;b=c\x1b\\text');
      expect(
        terminal.buffer.getLinkAt(const CellOffset(1, 0)),
        Uri.parse('https://example.com/a;b=c'),
      );
    });

    test('accepts the BEL terminator', () {
      final terminal = terminalWith('\x1b]8;;https://example.com/bel\x07text');
      expect(
        terminal.buffer.getLinkAt(const CellOffset(1, 0)),
        Uri.parse('https://example.com/bel'),
      );
    });

    test('refuses targets this terminal would not open', () {
      for (final target in [
        'file:///etc/passwd',
        'javascript:alert(1)',
        'ssh://example.com',
        'https://',
        'https://user:password@example.com',
        'https://example.com/${'a' * maxHyperlinkTargetLength}',
      ]) {
        final terminal = terminalWith(link(target, 'text'));
        expect(
          terminal.buffer.getLinkAt(const CellOffset(1, 0)),
          isNull,
          reason: target,
        );
      }
    });

    test('the target wins over a URL in the link text', () {
      // The phishing shape: text that reads like one site, a target that is
      // another. The attached target is what a click follows.
      final terminal =
          terminalWith(link('https://real.test/auth', 'https://decoy.test'));
      expect(
        terminal.buffer.getLinkAt(const CellOffset(4, 0)),
        Uri.parse('https://real.test/auth'),
      );
    });

    test('falls back to a URL in the text when the target is refused', () {
      final terminal =
          terminalWith(link('file:///etc/passwd', 'https://example.com'));
      expect(
        terminal.buffer.getLinkAt(const CellOffset(2, 0)),
        Uri.parse('https://example.com'),
      );
    });

    test('covers both cells of a wide character', () {
      final terminal = terminalWith(link('https://example.com/wide', '界x'));
      for (final x in [0, 1, 2]) {
        expect(
          terminal.buffer.getLinkAt(CellOffset(x, 0)),
          Uri.parse('https://example.com/wide'),
          reason: 'cell $x',
        );
      }
    });

    test('an erased cell carries no link', () {
      final terminal = terminalWith('\x1b]8;;https://example.com\x1b\\link me');
      // The redraw a full-screen program does while a hyperlink is open must
      // not leave a row of clickable blanks behind.
      terminal.write('\r\x1b[2K');
      expect(terminal.buffer.getLinkAt(const CellOffset(1, 0)), isNull);
    });

    test('survives soft wraps beyond the viewport height', () {
      final terminal = terminalWith(
        '${'\r\n' * 10}${link('https://example.com/deep', 'a' * 20)}',
        width: 12,
      );
      for (final row in [10, 11]) {
        expect(
          terminal.buffer.getLinkAt(CellOffset(2, row)),
          Uri.parse('https://example.com/deep'),
          reason: 'row $row',
        );
      }
    });
  });
}
