import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('a repeated target keeps one id', () {
    final links = Hyperlinks();
    final id = links.open('https://a.test');
    expect(id, isNot(noHyperlink));
    expect(links.open('https://a.test'), id);
    expect(links[id], Uri.parse('https://a.test'));
  });

  test('drops the least recently opened target instead of reusing its id', () {
    final links = Hyperlinks(capacity: 2);
    final a = links.open('https://a.test');
    final b = links.open('https://b.test');
    expect(links.open('https://a.test'), a, reason: 'reopening refreshes it');
    final c = links.open('https://c.test');

    expect({a, b, c}, hasLength(3), reason: 'ids are never handed out twice');
    expect(links[b], isNull, reason: 'an evicted cell resolves to nothing');
    expect(links[a], Uri.parse('https://a.test'));
    expect(links[c], Uri.parse('https://c.test'));
  });

  test('refuses targets the terminal would not open', () {
    final links = Hyperlinks();
    for (final target in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'ssh://example.com',
      'https://',
      'https://user:password@example.com',
      'https://example.com/${'a' * maxHyperlinkTargetLength}',
      '',
    ]) {
      expect(links.open(target), noHyperlink, reason: target);
    }
    expect(links[noHyperlink], isNull);
  });

  test('clear forgets every target', () {
    final links = Hyperlinks();
    final id = links.open('https://a.test');
    links.clear();
    expect(links[id], isNull);
  });

  test('an id fits beside the style flags in a cell', () {
    final style = CursorStyle()
      ..setBold()
      ..hyperlinkId = maxHyperlinkId;
    expect(style.hyperlinkId, maxHyperlinkId);
    expect(style.isBold, isTrue);

    style.reset();
    expect(style.isBold, isFalse);
    expect(
      style.hyperlinkId,
      maxHyperlinkId,
      reason: 'SGR 0 resets the style, not the hyperlink',
    );

    style.hyperlinkId = noHyperlink;
    expect(style.attrs, 0);
  });
}
