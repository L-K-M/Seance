import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/editor_syntax.dart';

List<SyntaxToken> _ofType(List<SyntaxToken> tokens, SyntaxTokenType type) =>
    tokens.where((token) => token.type == type).toList();

String _slice(String text, SyntaxToken token) =>
    text.substring(token.start, token.end);

void main() {
  group('language detection', () {
    test('resolves well-known extensions', () {
      expect(syntaxLanguageFor('/srv/deploy.py')?.id, 'python');
      expect(syntaxLanguageFor('/etc/nginx/nginx.conf')?.id, 'ini');
      expect(syntaxLanguageFor('/tmp/data.json')?.id, 'json');
      expect(syntaxLanguageFor('compose.yaml')?.id, 'yaml');
      expect(syntaxLanguageFor('main.go')?.id, 'c-family');
      expect(syntaxLanguageFor('query.sql')?.id, 'sql');
      expect(syntaxLanguageFor('notes.xyz'), isNull);
      expect(syntaxLanguageFor('README'), isNull);
    });

    test('resolves well-known basenames before extensions', () {
      expect(syntaxLanguageFor('/app/Dockerfile')?.id, 'dockerfile');
      expect(syntaxLanguageFor('Dockerfile.prod')?.id, 'dockerfile');
      expect(syntaxLanguageFor('/home/user/.bashrc')?.id, 'shell');
      expect(syntaxLanguageFor('/home/user/.ssh/config')?.id, 'ini');
      expect(syntaxLanguageFor('/etc/ssh/sshd_config')?.id, 'ini');
      expect(syntaxLanguageFor('Makefile')?.id, 'shell');
    });

    test('falls back to the shebang line', () {
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/deploy',
          firstLine: '#!/usr/bin/env bash',
        )?.id,
        'shell',
      );
      expect(
        syntaxLanguageFor('/usr/local/bin/tool', firstLine: '#!/usr/bin/python3')
            ?.id,
        'python',
      );
      expect(
        syntaxLanguageFor('/usr/local/bin/x', firstLine: 'not a shebang'),
        isNull,
      );
    });

    test('takes the basename after a backslash as well as a slash', () {
      expect(syntaxLanguageFor(r'C:\Users\me\.bashrc')?.id, 'shell');
      expect(syntaxLanguageFor(r'C:\srv\app\Dockerfile')?.id, 'dockerfile');
      expect(syntaxLanguageFor(r'C:\srv\app\Makefile')?.id, 'shell');
      expect(syntaxLanguageFor(r'C:\ProgramData\ssh\sshd_config')?.id, 'ini');
      expect(syntaxLanguageFor(r'/srv/mixed\dir/.htaccess')?.id, 'ini');
      // A dot in a directory name is not the file's extension.
      expect(syntaxLanguageFor(r'C:\site.py\README'), isNull);
    });

    test('css covers .css, .scss and .less', () {
      expect(syntaxLanguageFor('site.css')?.id, 'css');
      expect(syntaxLanguageFor('theme.scss')?.id, 'css');
      expect(syntaxLanguageFor('legacy.less')?.id, 'css');
    });

    test('ruby covers extensions, convention basenames and shebangs', () {
      for (final path in [
        'app.rb',
        'tasks.rake',
        'my.gemspec',
        'Gemfile',
        'Rakefile',
        'config.ru',
      ]) {
        expect(syntaxLanguageFor(path)?.id, 'ruby', reason: path);
      }
      for (final shebang in ['#!/usr/bin/ruby', '#!/usr/bin/env ruby']) {
        expect(
          syntaxLanguageFor('/usr/local/bin/tool', firstLine: shebang)?.id,
          'ruby',
          reason: shebang,
        );
      }
    });

    test('perl covers .pl, .pm and shebangs', () {
      expect(syntaxLanguageFor('script.pl')?.id, 'perl');
      expect(syntaxLanguageFor('Module.pm')?.id, 'perl');
      for (final shebang in ['#!/usr/bin/perl', '#!/usr/bin/env perl']) {
        expect(
          syntaxLanguageFor('/usr/local/bin/tool', firstLine: shebang)?.id,
          'perl',
          reason: shebang,
        );
      }
    });

    test('lua covers .lua and the known interpreter spellings only', () {
      expect(syntaxLanguageFor('init.lua')?.id, 'lua');
      for (final interpreter in [
        'lua',
        'luajit',
        'lua5.1',
        'lua5.2',
        'lua5.3',
        'lua5.4',
      ]) {
        for (final shebang in [
          '#!/usr/bin/$interpreter',
          '#!/usr/bin/env $interpreter',
        ]) {
          expect(
            syntaxLanguageFor('/usr/local/bin/tool', firstLine: shebang)?.id,
            'lua',
            reason: shebang,
          );
        }
      }
      // Names that merely start with "lua" are not claimed.
      for (final shebang in ['#!/usr/bin/lua5.5', '#!/usr/bin/luabridge']) {
        expect(
          syntaxLanguageFor('/usr/local/bin/tool', firstLine: shebang),
          isNull,
          reason: shebang,
        );
      }
    });

    test('Apache dot-configs map to ini', () {
      expect(syntaxLanguageFor('/srv/www/.htaccess')?.id, 'ini');
      expect(syntaxLanguageFor('/srv/www/.htpasswd')?.id, 'ini');
    });
  });

  group('tokenizer', () {
    test('shell: comments, keywords, strings, numbers, variables', () {
      const text = '# note\necho "hi" 42 \$HOME\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.shell);
      final comments = _ofType(tokens, SyntaxTokenType.comment);
      expect(comments, hasLength(1));
      expect(_slice(text, comments.single), '# note');
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('echo'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('"hi"'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.number).map((t) => _slice(text, t)),
        contains('42'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        contains('\$HOME'),
      );
    });

    test('shell: a hash inside a word is not a comment', () {
      final tokens = tokenizeSyntax('path/foo#bar\n', SyntaxLanguages.shell);
      expect(_ofType(tokens, SyntaxTokenType.comment), isEmpty);
    });

    test('python: hash comments need no boundary; triple quotes span lines',
        () {
      const text = 'x=1# c\n"""doc\nstring"""\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.python);
      final comments = _ofType(tokens, SyntaxTokenType.comment);
      expect(comments.map((t) => _slice(text, t)), contains('# c'));
      final strings = _ofType(tokens, SyntaxTokenType.string);
      expect(strings, hasLength(1));
      expect(_slice(text, strings.single), '"""doc\nstring"""');
    });

    test('javascript: block comments and template strings', () {
      const text = '/* a\nb */ const x = `tpl\nline`; // end\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.javascript);
      final comments = _ofType(tokens, SyntaxTokenType.comment);
      expect(comments.map((t) => _slice(text, t)), contains('/* a\nb */'));
      expect(comments.map((t) => _slice(text, t)), contains('// end'));
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('`tpl\nline`'),
      );
    });

    test('strings: escapes are honored and unterminated stops at newline', () {
      const text = '"a\\"b" "open\nnext';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.json);
      final strings = _ofType(tokens, SyntaxTokenType.string);
      expect(_slice(text, strings.first), '"a\\"b"');
      expect(_slice(text, strings.last), '"open');
    });

    test('numbers: hex, decimals, exponents', () {
      const text = 'a = 0xFF; b = 3.14e-2; c = 10_000';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.cFamily);
      expect(
        _ofType(tokens, SyntaxTokenType.number).map((t) => _slice(text, t)),
        containsAll(['0xFF', '3.14e-2', '10_000']),
      );
    });

    test('yaml: keys are meta unless consumed by another token', () {
      const text = 'name: test\n# port: none\nport: 8080\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.yaml);
      final meta = _ofType(tokens, SyntaxTokenType.meta);
      expect(meta.map((t) => _slice(text, t)), ['name', 'port']);
      expect(
        _ofType(tokens, SyntaxTokenType.number).map((t) => _slice(text, t)),
        contains('8080'),
      );
    });

    test('ini: sections, comments, booleans', () {
      const text = '[core]\n; note\nenabled = TRUE\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.ini);
      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        contains('[core]'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        contains('; note'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('TRUE'),
      );
    });

    test('dockerfile: instructions are case-insensitive keywords', () {
      const text = 'FROM debian:stable\nrun apt-get update\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.dockerfile);
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        containsAll(['FROM', 'run']),
      );
    });

    test('css: block comments, property meta, at-rule keywords', () {
      const text = '/* note */\n@media screen {\n  color: red;\n}\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.css);
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        ['/* note */'],
      );
      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        contains('color'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('media'),
      );
    });

    test('ruby: bounded hash comments, keywords, strings', () {
      const text = '# note\ndef greet\n  puts "hi"\nend\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.ruby);
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        ['# note'],
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        containsAll(['def', 'end', 'puts']),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        ['"hi"'],
      );
      // `x#y` is not a comment start in Ruby.
      expect(
        _ofType(
          tokenizeSyntax('x#y\n', SyntaxLanguages.ruby),
          SyntaxTokenType.comment,
        ),
        isEmpty,
      );
    });

    test('perl: hash comments anywhere, keywords, strings', () {
      const text = 'my \$x = 1;# tail\nsub f { print "hi" }\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.perl);
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        ['# tail'],
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        containsAll(['my', 'sub', 'print']),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        ['"hi"'],
      );
    });

    test('lua: --[[ ]] comments and [[ ]] strings span lines', () {
      const text = '--[[ block\ncomment ]]\nlocal s = [[ multi\nline ]]\n'
          '-- tail\nlocal open = [[ unterminated';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.lua);
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        ['--[[ block\ncomment ]]', '-- tail'],
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        ['[[ multi\nline ]]', '[[ unterminated'],
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('local'),
      );
    });

    test('an optional meta group that does not match adds no token', () {
      final language = SyntaxLanguage(
        id: 'test',
        metaPattern: RegExp(r'key(=\w+)?'),
        metaGroup: 1,
      );
      const text = 'key key=value';
      final tokens = tokenizeSyntax(text, language);
      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        ['=value'],
      );
    });

    test('tokens are ordered and never overlap', () {
      const text = 'if [ -f "\$HOME/.bashrc" ]; then # load\n  source '
          '"\$HOME/.bashrc" 2>/dev/null\nfi\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.shell);
      for (var i = 1; i < tokens.length; i++) {
        expect(tokens[i].start, greaterThanOrEqualTo(tokens[i - 1].end));
      }
    });
  });

  group('search', () {
    test('is case-insensitive by default and reports exact ranges', () {
      final matches = findSearchMatches('Beta beta BETA', 'beta');
      expect(matches, hasLength(3));
      expect(matches.first, const TextRange(start: 0, end: 4));
      expect(matches.last, const TextRange(start: 10, end: 14));
      expect(findSearchMatches('Beta beta BETA', 'beta', caseSensitive: true),
          hasLength(1));
    });

    test('caps the match count at the limit', () {
      final text = 'a' * 50;
      expect(findSearchMatches(text, 'a', limit: 10), hasLength(10));
    });

    test('an empty query has no matches', () {
      expect(findSearchMatches('anything', ''), isEmpty);
    });
  });

  group('span building', () {
    test('search hits overlay token colors without splitting order', () {
      const text = 'abcdef';
      final spans = buildHighlightedSpans(
        text: text,
        tokens: const [SyntaxToken(0, 4, SyntaxTokenType.string)],
        matches: const [TextRange(start: 2, end: 6)],
        activeMatchIndex: 0,
        theme: EditorSyntaxTheme.dark,
      );
      final texts = spans.map((s) => (s as TextSpan).text).toList();
      expect(texts, ['ab', 'cd', 'ef']);
      final styles = spans.map((s) => (s as TextSpan).style).toList();
      expect(styles[0]?.color, EditorSyntaxTheme.dark.string);
      expect(styles[0]?.backgroundColor, isNull);
      expect(
        styles[1]?.backgroundColor,
        EditorSyntaxTheme.dark.activeMatchBackground,
      );
      expect(
        styles[2]?.backgroundColor,
        EditorSyntaxTheme.dark.activeMatchBackground,
      );
      expect(styles[2]?.color, EditorSyntaxTheme.dark.activeMatchForeground);
    });

    test('inactive matches use the plain hit colors', () {
      final spans = buildHighlightedSpans(
        text: 'xx yy',
        tokens: const [],
        matches: const [
          TextRange(start: 0, end: 2),
          TextRange(start: 3, end: 5),
        ],
        activeMatchIndex: 1,
        theme: EditorSyntaxTheme.dark,
      );
      final styles = spans.map((s) => (s as TextSpan).style).toList();
      expect(
        styles.first?.backgroundColor,
        EditorSyntaxTheme.dark.matchBackground,
      );
      expect(
        styles.last?.backgroundColor,
        EditorSyntaxTheme.dark.activeMatchBackground,
      );
    });

    test('reassembles the exact source text', () {
      const text = '# c\nkey: "value" 42\n';
      final spans = buildHighlightedSpans(
        text: text,
        tokens: tokenizeSyntax(text, SyntaxLanguages.yaml),
        matches: findSearchMatches(text, 'e'),
        activeMatchIndex: 0,
        theme: EditorSyntaxTheme.light,
      );
      expect(spans.map((s) => (s as TextSpan).text).join(), text);
    });
  });
}
