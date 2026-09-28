import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

Snippet _s(String body) =>
    Snippet(id: '1', title: 't', body: body, createdAt: 0, updatedAt: 0);

void main() {
  group('Snippet placeholders', () {
    test('parses distinct names in first-appearance order, trimming space', () {
      expect(_s('cp {{ src }} {{dst}} && echo {{src}}').placeholders,
          ['src', 'dst']);
    });

    test('no placeholders yields an empty list', () {
      expect(_s('ls -la').placeholders, isEmpty);
    });

    test('fill substitutes values and leaves unfilled placeholders intact', () {
      final s = _s('tail -f {{file}} | grep {{pattern}}');
      expect(s.fill({'file': '/var/log/syslog', 'pattern': 'error'}),
          'tail -f /var/log/syslog | grep error');
      expect(s.fill({'file': '/x'}), 'tail -f /x | grep {{pattern}}');
    });

    test('json round-trips', () {
      final s = _s('echo {{a}}');
      final back = Snippet.fromJson(s.toJson());
      expect(back.title, 't');
      expect(back.body, 'echo {{a}}');
      expect(back.placeholders, ['a']);
    });
  });

  group('SnippetSource', () {
    const source = SnippetSource(
      id: 'team',
      name: 'Team',
      url: 'https://example.com/snippets.json',
      tokenRef: 'ref-1',
      createdAt: 1,
      updatedAt: 2,
    );

    test('json round-trips, token reference included', () {
      expect(SnippetSource.fromJson(source.toJson()).toJson(), source.toJson());
    });

    test('a source without a token omits the reference', () {
      final open = source.copyWith(clearTokenRef: true);
      expect(open.tokenRef, isNull);
      expect(open.toJson(), isNot(contains('tokenRef')));
      expect(SnippetSource.fromJson(open.toJson()).tokenRef, isNull);
    });

    test('copyWith keeps the reference unless told to clear it', () {
      expect(source.copyWith(name: 'Renamed').tokenRef, 'ref-1');
    });
  });
}
