/// Basic syntax highlighting for the built-in text editor.
///
/// This is deliberately not a full grammar engine: one generic scanner covers
/// comments, strings, numbers and keywords, and a per-language regex adds
/// "meta" tokens (YAML keys, INI sections, shell variables, tags). That is
/// enough to make config files and scripts readable without pulling in a
/// highlighting dependency or paying for a real parser on every keystroke.
library;

import 'package:flutter/material.dart';

/// Above this size the editor skips syntax highlighting (and the precise
/// scroll-to-match layout): tokenizing stays linear, but building and painting
/// hundreds of thousands of spans per frame does not.
const int syntaxHighlightingMaxChars = 200 * 1000;

/// Search stops counting matches here; the find bar shows "1000+" instead of
/// building an unbounded highlight list for a one-letter query in a huge file.
const int searchMatchLimit = 1000;

enum SyntaxTokenType { comment, string, number, keyword, meta }

/// A non-overlapping half-open range `[start, end)` of one token type.
class SyntaxToken {
  final int start;
  final int end;
  final SyntaxTokenType type;

  const SyntaxToken(this.start, this.end, this.type);

  @override
  bool operator ==(Object other) =>
      other is SyntaxToken &&
      other.start == start &&
      other.end == end &&
      other.type == type;

  @override
  int get hashCode => Object.hash(start, end, type);

  @override
  String toString() => 'SyntaxToken($start, $end, ${type.name})';
}

/// What the generic scanner needs to know about one language family.
class SyntaxLanguage {
  final String id;
  final Set<String> keywords;
  final bool caseInsensitiveKeywords;

  /// Markers that start a comment running to the end of the line.
  final List<String> lineComments;

  /// When true a line comment only starts at the beginning of a line or after
  /// whitespace — correct for `#` in shell and YAML (`foo#bar` is not a
  /// comment there), wrong for Python or C-family markers.
  final bool lineCommentNeedsBoundary;

  /// `[open, close]` pairs, e.g. `['/*', '*/']` or `['<!--', '-->']`.
  final List<List<String>> blockComments;

  /// Delimiters of strings that may span lines (`'''`, `"""`, '`').
  final List<String> multilineStrings;

  /// `[open, close]` pairs for multiline strings whose delimiters differ
  /// (Lua's `[[ ]]`). They take no escapes, so the closer is a plain search.
  /// Scanned right after [multilineStrings]: after block comments, before
  /// line comments.
  final List<List<String>> multilineStringPairs;

  /// Single-line string quotes; a missing closer ends the token at newline.
  final List<String> strings;

  /// Optional extra pattern matched over the whole text (use `multiLine` for
  /// anchors); matches that don't overlap scanner tokens become [meta] tokens.
  final RegExp? metaPattern;

  /// Which group of [metaPattern] is the token; null highlights group 0.
  final int? metaGroup;

  /// Prose-like formats (Markdown, plain config values) skip number
  /// highlighting — digits in text are content, not literals.
  final bool highlightNumbers;

  const SyntaxLanguage({
    required this.id,
    this.keywords = const {},
    this.caseInsensitiveKeywords = false,
    this.lineComments = const [],
    this.lineCommentNeedsBoundary = false,
    this.blockComments = const [],
    this.multilineStrings = const [],
    this.multilineStringPairs = const [],
    this.strings = const [],
    this.metaPattern,
    this.metaGroup,
    this.highlightNumbers = true,
  });
}

/// The language families the editor recognizes. Kept intentionally small:
/// the files edited over SFTP are overwhelmingly configs and scripts.
class SyntaxLanguages {
  static final shell = SyntaxLanguage(
    id: 'shell',
    keywords: const {
      'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'do',
      'done', 'case', 'esac', 'in', 'function', 'select', 'time', 'local',
      'export', 'readonly', 'declare', 'unset', 'shift', 'return', 'exit',
      'break', 'continue', 'source', 'alias', 'eval', 'exec', 'set', 'trap',
      'test', 'echo', 'cd',
    },
    lineComments: const ['#'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
    metaPattern: RegExp(r'\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@#?*!$-]'),
  );

  static final python = SyntaxLanguage(
    id: 'python',
    keywords: const {
      'def', 'class', 'if', 'elif', 'else', 'for', 'while', 'try', 'except',
      'finally', 'with', 'as', 'import', 'from', 'return', 'yield', 'lambda',
      'pass', 'break', 'continue', 'raise', 'global', 'nonlocal', 'del',
      'assert', 'async', 'await', 'and', 'or', 'not', 'in', 'is', 'None',
      'True', 'False', 'match', 'case', 'self',
    },
    lineComments: const ['#'],
    multilineStrings: const ["'''", '"""'],
    strings: const ["'", '"'],
  );

  static final javascript = SyntaxLanguage(
    id: 'javascript',
    keywords: const {
      'function', 'const', 'let', 'var', 'if', 'else', 'for', 'while', 'do',
      'switch', 'case', 'default', 'break', 'continue', 'return', 'new',
      'delete', 'typeof', 'instanceof', 'in', 'of', 'class', 'extends',
      'super', 'this', 'import', 'export', 'from', 'as', 'async', 'await',
      'try', 'catch', 'finally', 'throw', 'yield', 'static', 'get', 'set',
      'null', 'undefined', 'true', 'false', 'void', 'interface', 'type',
      'enum', 'implements', 'readonly', 'public', 'private', 'protected',
    },
    lineComments: const ['//'],
    blockComments: const [
      ['/*', '*/'],
    ],
    multilineStrings: const ['`'],
    strings: const ["'", '"'],
  );

  static final dart = SyntaxLanguage(
    id: 'dart',
    keywords: const {
      'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
      'catch', 'class', 'const', 'continue', 'covariant', 'default', 'do',
      'dynamic', 'else', 'enum', 'export', 'extends', 'extension', 'external',
      'factory', 'false', 'final', 'finally', 'for', 'get', 'if',
      'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
      'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow',
      'return', 'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync',
      'this', 'throw', 'true', 'try', 'typedef', 'var', 'void', 'when',
      'while', 'with', 'yield',
    },
    lineComments: const ['//'],
    blockComments: const [
      ['/*', '*/'],
    ],
    multilineStrings: const ["'''", '"""'],
    strings: const ["'", '"'],
  );

  static final json = SyntaxLanguage(
    id: 'json',
    keywords: const {'true', 'false', 'null'},
    strings: const ['"'],
  );

  static final yaml = SyntaxLanguage(
    id: 'yaml',
    keywords: const {'true', 'false', 'null'},
    lineComments: const ['#'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
    metaPattern: RegExp(
      r'^[ \t]*(?:-[ \t]+)*([^\s#-][^:\n]*?)[ \t]*:(?=[ \t]|$)',
      multiLine: true,
    ),
    metaGroup: 1,
  );

  static final ini = SyntaxLanguage(
    id: 'ini',
    keywords: const {'true', 'false', 'yes', 'no', 'on', 'off'},
    caseInsensitiveKeywords: true,
    lineComments: const ['#', ';'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
    metaPattern: RegExp(r'^[ \t]*\[[^\]\n]+\]', multiLine: true),
    highlightNumbers: true,
  );

  static final dockerfile = SyntaxLanguage(
    id: 'dockerfile',
    keywords: const {
      'from', 'run', 'cmd', 'label', 'maintainer', 'expose', 'env', 'add',
      'copy', 'entrypoint', 'volume', 'user', 'workdir', 'arg', 'onbuild',
      'stopsignal', 'healthcheck', 'shell', 'as',
    },
    caseInsensitiveKeywords: true,
    lineComments: const ['#'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
    metaPattern: RegExp(r'\$\{?[A-Za-z_][A-Za-z0-9_]*\}?'),
  );

  static final sql = SyntaxLanguage(
    id: 'sql',
    keywords: const {
      'select', 'from', 'where', 'insert', 'into', 'values', 'update',
      'delete', 'create', 'drop', 'alter', 'table', 'index', 'view', 'join',
      'inner', 'left', 'right', 'outer', 'on', 'as', 'and', 'or', 'not',
      'null', 'is', 'in', 'like', 'between', 'order', 'by', 'group', 'having',
      'limit', 'offset', 'distinct', 'union', 'all', 'exists', 'primary',
      'key', 'foreign', 'references', 'default', 'unique', 'constraint',
      'begin', 'commit', 'rollback', 'transaction', 'grant', 'revoke', 'set',
    },
    caseInsensitiveKeywords: true,
    lineComments: const ['--'],
    blockComments: const [
      ['/*', '*/'],
    ],
    strings: const ["'", '"'],
  );

  static final cFamily = SyntaxLanguage(
    id: 'c-family',
    keywords: const {
      'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default',
      'break', 'continue', 'return', 'goto', 'struct', 'class', 'enum',
      'union', 'typedef', 'const', 'static', 'void', 'int', 'long', 'short',
      'char', 'float', 'double', 'bool', 'unsigned', 'signed', 'true',
      'false', 'new', 'delete', 'public', 'private', 'protected', 'virtual',
      'override', 'namespace', 'using', 'template', 'typename', 'func', 'fn',
      'let', 'var', 'mut', 'impl', 'trait', 'match', 'mod', 'pub', 'use',
      'crate', 'package', 'import', 'interface', 'extends', 'implements',
      'final', 'abstract', 'throws', 'throw', 'try', 'catch', 'finally',
      'null', 'nullptr', 'nil', 'this', 'self', 'defer', 'go', 'chan', 'map',
      'range', 'type',
    },
    lineComments: const ['//'],
    blockComments: const [
      ['/*', '*/'],
    ],
    strings: const ["'", '"'],
  );

  static final xml = SyntaxLanguage(
    id: 'xml',
    blockComments: const [
      ['<!--', '-->'],
    ],
    strings: const ["'", '"'],
    metaPattern: RegExp(r'</?[A-Za-z][A-Za-z0-9:._-]*'),
    highlightNumbers: false,
  );

  static final markdown = SyntaxLanguage(
    id: 'markdown',
    multilineStrings: const ['```'],
    strings: const ['`'],
    metaPattern: RegExp(r'^#{1,6}[ \t].*$', multiLine: true),
    highlightNumbers: false,
  );

  /// CSS, SCSS and LESS. Property names are meta. The `//` line comments
  /// SCSS and LESS allow are left out on purpose: that rule would swallow an
  /// unquoted `url(http://…)` as a comment. The meta rule cannot tell a
  /// declaration from a selector, so `a:hover` and `max-width:` light up
  /// too. Keywords are single identifiers, which stop at `-`, so a
  /// hyphenated at-rule such as `font-face` cannot be one.
  static final css = SyntaxLanguage(
    id: 'css',
    keywords: const {
      'media', 'supports', 'keyframes', 'import', 'charset', 'namespace',
      'page', 'important', 'inherit', 'initial', 'unset', 'revert', 'auto',
      'none',
    },
    caseInsensitiveKeywords: true,
    blockComments: const [
      ['/*', '*/'],
    ],
    strings: const ["'", '"'],
    metaPattern: RegExp(r'([-a-zA-Z]+)[ \t]*:'),
    metaGroup: 1,
  );

  /// Ruby. `=begin`/`=end` block comments only count at the start of a line,
  /// which the scanner cannot express; they render as plain text.
  static final ruby = SyntaxLanguage(
    id: 'ruby',
    keywords: const {
      'alias', 'and', 'begin', 'BEGIN', 'break', 'case', 'class', 'def',
      'defined', 'do', 'else', 'elsif', 'end', 'END', 'ensure', 'false',
      'for', 'if', 'in', 'module', 'next', 'nil', 'not', 'or', 'redo',
      'rescue', 'retry', 'return', 'self', 'super', 'then', 'true', 'undef',
      'unless', 'until', 'when', 'while', 'yield', 'require',
      'require_relative', 'attr_accessor', 'attr_reader', 'attr_writer',
      'include', 'extend', 'private', 'protected', 'public', 'raise',
      'lambda', 'proc', 'puts', 'print',
    },
    lineComments: const ['#'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
  );

  /// Perl. A `#` counts as a comment only at a line start or after
  /// whitespace, as for Ruby: glued to a sigil or a delimiter it is syntax
  /// (`$#list`, `s#a#b#`, `qw#a b#`, `s/#.*//`), and without the boundary
  /// each greyed out the rest of its line. The cost is that a comment
  /// glued to code (`1;# note`) renders as code. POD (`=pod` … `=cut`) is
  /// left out for the same start-of-line reason as Ruby's `=begin`.
  static final perl = SyntaxLanguage(
    id: 'perl',
    keywords: const {
      'my', 'our', 'local', 'sub', 'use', 'package', 'require', 'if',
      'elsif', 'else', 'unless', 'while', 'until', 'for', 'foreach', 'last',
      'next', 'redo', 'return', 'goto', 'do', 'eval', 'die', 'warn', 'print',
      'say', 'chomp', 'chop', 'push', 'pop', 'shift', 'unshift', 'splice',
      'grep', 'map', 'sort', 'keys', 'values', 'each', 'exists', 'defined',
      'undef', 'ref', 'bless', 'tie', 'scalar', 'wantarray', 'caller',
      'exit', 'open', 'close', 'read', 'and', 'or', 'not', 'xor', 'eq', 'ne',
      'lt', 'gt', 'le', 'ge', 'cmp',
    },
    lineComments: const ['#'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
  );

  /// Lua. `--[[ ]]` is declared as a block comment because the scanner tries
  /// block comments before both line comments and multiline strings, so
  /// `--[[` never becomes a `--` line comment (stranding `]]`) and the `[[`
  /// inside it never opens a string. Leveled brackets (`[==[`) are not
  /// recognized: `--[==[` falls to the line rule, a bare `[==[` to nothing.
  static final lua = SyntaxLanguage(
    id: 'lua',
    keywords: const {
      'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for',
      'function', 'goto', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat',
      'return', 'then', 'true', 'until', 'while', 'require', 'module',
      'print', 'pairs', 'ipairs', 'type', 'tostring', 'tonumber', 'error',
      'pcall', 'xpcall', 'select', 'rawget', 'rawset', 'rawequal',
      'setmetatable', 'getmetatable', 'next', 'unpack', 'self',
    },
    blockComments: const [
      ['--[[', ']]'],
    ],
    lineComments: const ['--'],
    multilineStringPairs: const [
      ['[[', ']]'],
    ],
    strings: const ["'", '"'],
  );
}

const Map<String, String> _extensionLanguages = {
  'sh': 'shell', 'bash': 'shell', 'zsh': 'shell', 'ksh': 'shell',
  'py': 'python', 'pyw': 'python',
  'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
  'jsx': 'javascript', 'ts': 'javascript', 'tsx': 'javascript',
  'dart': 'dart',
  'json': 'json', 'jsonc': 'json',
  'yaml': 'yaml', 'yml': 'yaml',
  'toml': 'ini', 'ini': 'ini', 'cfg': 'ini', 'conf': 'ini',
  'properties': 'ini', 'env': 'ini', 'desktop': 'ini', 'service': 'ini',
  'socket': 'ini', 'timer': 'ini',
  'sql': 'sql',
  'c': 'c-family', 'h': 'c-family', 'cpp': 'c-family', 'cc': 'c-family',
  'cxx': 'c-family', 'hpp': 'c-family', 'hh': 'c-family', 'go': 'c-family',
  'rs': 'c-family', 'java': 'c-family', 'kt': 'c-family', 'kts': 'c-family',
  'swift': 'c-family', 'cs': 'c-family', 'scala': 'c-family',
  'php': 'c-family',
  'xml': 'xml', 'html': 'xml', 'htm': 'xml', 'xhtml': 'xml', 'svg': 'xml',
  'plist': 'xml',
  'md': 'markdown', 'markdown': 'markdown',
  'css': 'css', 'scss': 'css', 'less': 'css',
  'rb': 'ruby', 'rake': 'ruby', 'gemspec': 'ruby',
  'pl': 'perl', 'pm': 'perl',
  'lua': 'lua',
};

const Map<String, String> _basenameLanguages = {
  'dockerfile': 'dockerfile', 'containerfile': 'dockerfile',
  'makefile': 'shell', 'gnumakefile': 'shell',
  '.bashrc': 'shell', '.bash_profile': 'shell', '.bash_aliases': 'shell',
  '.bash_logout': 'shell', '.zshrc': 'shell', '.zshenv': 'shell',
  '.zprofile': 'shell', '.profile': 'shell',
  '.gitignore': 'ini', '.dockerignore': 'ini', '.gitconfig': 'ini',
  '.gitmodules': 'ini', '.editorconfig': 'ini', '.npmrc': 'ini',
  // The files an SSH client edits most.
  'config': 'ini', 'ssh_config': 'ini', 'sshd_config': 'ini',
  'authorized_keys': 'ini', 'known_hosts': 'ini', 'hosts': 'ini',
  'fstab': 'ini', 'crontab': 'shell',
  'gemfile': 'ruby', 'rakefile': 'ruby', 'config.ru': 'ruby',
  // Apache's per-directory config. `.htpasswd` (`user:hash` lines) matches
  // no ini rule; it is mapped so it opens as a known config, not unknown.
  '.htaccess': 'ini', '.htpasswd': 'ini',
};

SyntaxLanguage? _languageById(String id) => switch (id) {
  'shell' => SyntaxLanguages.shell,
  'python' => SyntaxLanguages.python,
  'javascript' => SyntaxLanguages.javascript,
  'dart' => SyntaxLanguages.dart,
  'json' => SyntaxLanguages.json,
  'yaml' => SyntaxLanguages.yaml,
  'ini' => SyntaxLanguages.ini,
  'dockerfile' => SyntaxLanguages.dockerfile,
  'sql' => SyntaxLanguages.sql,
  'c-family' => SyntaxLanguages.cFamily,
  'xml' => SyntaxLanguages.xml,
  'markdown' => SyntaxLanguages.markdown,
  'css' => SyntaxLanguages.css,
  'ruby' => SyntaxLanguages.ruby,
  'perl' => SyntaxLanguages.perl,
  'lua' => SyntaxLanguages.lua,
  _ => null,
};

/// Pick a language for [path], preferring a well-known basename, then the
/// extension, then a `#!` interpreter line from [firstLine]. Returns null for
/// unrecognized files, which render as plain text.
SyntaxLanguage? syntaxLanguageFor(String path, {String? firstLine}) {
  // Either separator ends a directory: a remote path is POSIX, but a local
  // Windows path (or a Windows host's) arrives with backslashes.
  final separator = path.lastIndexOf(RegExp(r'[/\\]'));
  final basename = path.substring(separator + 1).toLowerCase();
  final byBasename = _basenameLanguages[basename];
  if (byBasename != null) return _languageById(byBasename);
  if (basename.startsWith('dockerfile.') || basename.endsWith('.dockerfile')) {
    return SyntaxLanguages.dockerfile;
  }
  final dot = basename.lastIndexOf('.');
  if (dot > 0 && dot < basename.length - 1) {
    final byExtension = _extensionLanguages[basename.substring(dot + 1)];
    if (byExtension != null) return _languageById(byExtension);
  }
  final shebang = firstLine?.trim();
  if (shebang != null && shebang.startsWith('#!')) {
    if (shebang.contains('python')) return SyntaxLanguages.python;
    if (shebang.contains('node') ||
        shebang.contains('deno') ||
        shebang.contains('bun')) {
      return SyntaxLanguages.javascript;
    }
    // Word boundaries match the interpreter both directly (`#!/usr/bin/ruby`)
    // and after `env`, and keep `lua5.5` or `luabridge` from counting as Lua.
    if (RegExp(r'\bruby\b').hasMatch(shebang)) return SyntaxLanguages.ruby;
    if (RegExp(r'\bperl\b').hasMatch(shebang)) return SyntaxLanguages.perl;
    if (RegExp(r'\blua(?:5\.[1-4]|jit)?\b').hasMatch(shebang)) {
      return SyntaxLanguages.lua;
    }
    if (RegExp(r'\b(sh|bash|zsh|ksh|dash|ash)\b').hasMatch(shebang)) {
      return SyntaxLanguages.shell;
    }
  }
  return null;
}

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;

bool _isIdentPart(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39);

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Scan [text] into non-overlapping, ordered [SyntaxToken]s.
List<SyntaxToken> tokenizeSyntax(String text, SyntaxLanguage language) {
  final tokens = <SyntaxToken>[];
  final n = text.length;
  var i = 0;
  outer:
  while (i < n) {
    final c = text.codeUnitAt(i);

    for (final pair in language.blockComments) {
      if (text.startsWith(pair[0], i)) {
        final close = text.indexOf(pair[1], i + pair[0].length);
        final end = close < 0 ? n : close + pair[1].length;
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.comment));
        i = end;
        continue outer;
      }
    }

    for (final delimiter in language.multilineStrings) {
      if (text.startsWith(delimiter, i)) {
        final end = _scanString(text, i, delimiter, stopAtNewline: false);
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.string));
        i = end;
        continue outer;
      }
    }

    for (final pair in language.multilineStringPairs) {
      if (text.startsWith(pair[0], i)) {
        final close = text.indexOf(pair[1], i + pair[0].length);
        final end = close < 0 ? n : close + pair[1].length;
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.string));
        i = end;
        continue outer;
      }
    }

    for (final marker in language.lineComments) {
      if (text.startsWith(marker, i) &&
          (!language.lineCommentNeedsBoundary ||
              i == 0 ||
              _isWhitespace(text.codeUnitAt(i - 1)))) {
        final newline = text.indexOf('\n', i);
        final end = newline < 0 ? n : newline;
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.comment));
        i = end;
        continue outer;
      }
    }

    for (final quote in language.strings) {
      if (text.startsWith(quote, i)) {
        final end = _scanString(text, i, quote, stopAtNewline: true);
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.string));
        i = end;
        continue outer;
      }
    }

    if (_isIdentStart(c)) {
      var end = i + 1;
      while (end < n && _isIdentPart(text.codeUnitAt(end))) {
        end++;
      }
      final word = text.substring(i, end);
      final isKeyword = language.caseInsensitiveKeywords
          ? language.keywords.contains(word.toLowerCase())
          : language.keywords.contains(word);
      if (isKeyword) {
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.keyword));
      }
      i = end;
      continue;
    }

    if (language.highlightNumbers && _isDigit(c)) {
      final end = _scanNumber(text, i);
      tokens.add(SyntaxToken(i, end, SyntaxTokenType.number));
      i = end;
      continue;
    }

    i++;
  }

  final meta = language.metaPattern;
  if (meta == null) return tokens;
  return _mergeMetaTokens(tokens, text, meta, language.metaGroup);
}

bool _isWhitespace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

/// End index of a string starting at [start] with [delimiter]; a backslash
/// escapes the next character. Unterminated single-line strings stop at the
/// newline; unterminated multiline strings run to the end of the text.
int _scanString(
  String text,
  int start,
  String delimiter, {
  required bool stopAtNewline,
}) {
  final n = text.length;
  var i = start + delimiter.length;
  while (i < n) {
    final c = text.codeUnitAt(i);
    if (c == 0x5c /* backslash */ ) {
      i += 2;
      continue;
    }
    if (stopAtNewline && c == 0x0a) return i;
    if (text.startsWith(delimiter, i)) return i + delimiter.length;
    i++;
  }
  return n;
}

int _scanNumber(String text, int start) {
  final n = text.length;
  var i = start;
  if (text.startsWith('0x', i) || text.startsWith('0X', i)) {
    i += 2;
    while (i < n && _isHexDigit(text.codeUnitAt(i))) {
      i++;
    }
    return i;
  }
  bool digitOrSeparator(int c) => _isDigit(c) || c == 0x5f;
  while (i < n && digitOrSeparator(text.codeUnitAt(i))) {
    i++;
  }
  if (i < n - 1 &&
      text.codeUnitAt(i) == 0x2e /* . */ &&
      _isDigit(text.codeUnitAt(i + 1))) {
    i++;
    while (i < n && digitOrSeparator(text.codeUnitAt(i))) {
      i++;
    }
  }
  if (i < n && (text.codeUnitAt(i) | 0x20) == 0x65 /* e */ ) {
    var j = i + 1;
    if (j < n && (text.codeUnitAt(j) == 0x2b || text.codeUnitAt(j) == 0x2d)) {
      j++;
    }
    if (j < n && _isDigit(text.codeUnitAt(j))) {
      j++;
      while (j < n && _isDigit(text.codeUnitAt(j))) {
        j++;
      }
      i = j;
    }
  }
  return i;
}

bool _isHexDigit(int c) =>
    _isDigit(c) ||
    (c >= 0x41 && c <= 0x46) ||
    (c >= 0x61 && c <= 0x66) ||
    c == 0x5f;

/// Add meta tokens for [pattern] matches that don't overlap scanner [tokens]
/// (a YAML "key" inside a comment stays a comment), keeping order.
List<SyntaxToken> _mergeMetaTokens(
  List<SyntaxToken> tokens,
  String text,
  RegExp pattern,
  int? group,
) {
  final merged = <SyntaxToken>[];
  var tokenIndex = 0;
  for (final match in pattern.allMatches(text)) {
    var start = match.start;
    var end = match.end;
    if (group != null) {
      // Dart's Match API exposes no per-group offsets (start/end are whole-
      // match getters), so the group is located by search. That is exact as
      // long as a metaPattern's group cannot also occur inside its own
      // prefix — true for the YAML key pattern, whose group starts with
      // [^\s#-] while the prefix is only whitespace and dashes. Keep that
      // property when adding grouped patterns.
      // An optional group that did not take part yields no token.
      final groupText = match[group];
      if (groupText == null) continue;
      start = match.start + match[0]!.indexOf(groupText);
      end = start + groupText.length;
    }
    if (end <= start) continue;
    while (tokenIndex < tokens.length && tokens[tokenIndex].end <= start) {
      merged.add(tokens[tokenIndex++]);
    }
    final overlaps =
        tokenIndex < tokens.length && tokens[tokenIndex].start < end;
    if (!overlaps) {
      merged.add(SyntaxToken(start, end, SyntaxTokenType.meta));
    }
  }
  merged.addAll(tokens.sublist(tokenIndex));
  return merged;
}

/// Substring search used by the editor's find bar. Case-insensitive matching
/// lowercases both sides; if lowering changes the haystack length (a handful
/// of Unicode characters do), it falls back to case-sensitive search rather
/// than report misaligned ranges. Capped at [limit] matches.
List<TextRange> findSearchMatches(
  String text,
  String query, {
  bool caseSensitive = false,
  int limit = searchMatchLimit,
}) {
  if (query.isEmpty) return const [];
  var haystack = text;
  var needle = query;
  if (!caseSensitive) {
    final lowered = text.toLowerCase();
    if (lowered.length == text.length) {
      haystack = lowered;
      needle = query.toLowerCase();
    }
  }
  final matches = <TextRange>[];
  var from = 0;
  while (matches.length < limit) {
    final at = haystack.indexOf(needle, from);
    if (at < 0) break;
    matches.add(TextRange(start: at, end: at + needle.length));
    from = at + needle.length;
  }
  return matches;
}

/// Token colors plus search-hit colors, per brightness. The values are drawn
/// from the app's terminal palettes so the editor reads as the same product.
class EditorSyntaxTheme {
  final Color comment;
  final Color string;
  final Color number;
  final Color keyword;
  final Color meta;
  final Color matchBackground;
  final Color matchForeground;
  final Color activeMatchBackground;
  final Color activeMatchForeground;

  const EditorSyntaxTheme({
    required this.comment,
    required this.string,
    required this.number,
    required this.keyword,
    required this.meta,
    required this.matchBackground,
    required this.matchForeground,
    required this.activeMatchBackground,
    required this.activeMatchForeground,
  });

  static const dark = EditorSyntaxTheme(
    comment: Color(0xFF6B6880),
    string: Color(0xFF7FD88F),
    number: Color(0xFFE6C177),
    keyword: Color(0xFFC49BE8),
    meta: Color(0xFF7AA2F7),
    matchBackground: Color(0x66E6C177),
    matchForeground: Color(0xFFF4F2FA),
    activeMatchBackground: Color(0xFFB9AFEE),
    activeMatchForeground: Color(0xFF15141B),
  );

  static const light = EditorSyntaxTheme(
    comment: Color(0xFF6B6880),
    string: Color(0xFF2E6B36),
    number: Color(0xFF7A5A00),
    keyword: Color(0xFF8A3FA8),
    meta: Color(0xFF2B4FBF),
    matchBackground: Color(0x80F5D89B),
    matchForeground: Color(0xFF2A2733),
    activeMatchBackground: Color(0xFFB9AFEE),
    activeMatchForeground: Color(0xFF15141B),
  );

  static EditorSyntaxTheme of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  Color colorFor(SyntaxTokenType type) => switch (type) {
    SyntaxTokenType.comment => comment,
    SyntaxTokenType.string => string,
    SyntaxTokenType.number => number,
    SyntaxTokenType.keyword => keyword,
    SyntaxTokenType.meta => meta,
  };
}

/// Flatten syntax [tokens] and search [matches] into styled spans. Both
/// inputs are ordered and internally non-overlapping; a search hit overlaying
/// a token keeps the token's color and adds the hit background.
List<InlineSpan> buildHighlightedSpans({
  required String text,
  required List<SyntaxToken> tokens,
  required List<TextRange> matches,
  required int activeMatchIndex,
  required EditorSyntaxTheme theme,
}) {
  final spans = <InlineSpan>[];
  final n = text.length;
  var position = 0;
  var tokenIndex = 0;
  var matchIndex = 0;
  while (position < n) {
    while (tokenIndex < tokens.length && tokens[tokenIndex].end <= position) {
      tokenIndex++;
    }
    while (matchIndex < matches.length && matches[matchIndex].end <= position) {
      matchIndex++;
    }
    final token = tokenIndex < tokens.length ? tokens[tokenIndex] : null;
    final match = matchIndex < matches.length ? matches[matchIndex] : null;
    final inToken = token != null && token.start <= position;
    final inMatch = match != null && match.start <= position;
    var end = n;
    if (token != null) end = end.clamp(0, inToken ? token.end : token.start);
    if (match != null) end = end.clamp(0, inMatch ? match.end : match.start);
    TextStyle? style;
    if (inToken) style = TextStyle(color: theme.colorFor(token.type));
    if (inMatch) {
      final active = matchIndex == activeMatchIndex;
      style = (style ?? const TextStyle()).copyWith(
        color: active ? theme.activeMatchForeground : theme.matchForeground,
        backgroundColor: active
            ? theme.activeMatchBackground
            : theme.matchBackground,
      );
    }
    spans.add(TextSpan(text: text.substring(position, end), style: style));
    position = end;
  }
  return spans;
}

/// A [TextEditingController] that renders syntax and search-match highlights.
///
/// Tokenization is memoized on the text instance, so selection movement and
/// repaints don't re-scan; only actual edits do. During IME composition it
/// falls back to the default span (plain text + composing underline) so
/// highlighting can never fight the input method.
class CodeEditingController extends TextEditingController {
  SyntaxLanguage? language;
  EditorSyntaxTheme theme;

  List<TextRange> _matches = const [];
  int _activeMatchIndex = -1;

  String? _tokenizedText;
  SyntaxLanguage? _tokenizedLanguage;
  List<SyntaxToken> _tokens = const [];

  CodeEditingController({this.language, this.theme = EditorSyntaxTheme.dark});

  List<TextRange> get searchMatches => _matches;
  int get activeMatchIndex => _activeMatchIndex;

  void setSearchMatches(List<TextRange> matches, int activeIndex) {
    if (identical(_matches, matches) && _activeMatchIndex == activeIndex) {
      return;
    }
    _matches = matches;
    _activeMatchIndex = activeIndex;
    notifyListeners();
  }

  List<SyntaxToken> _tokensFor(String text) {
    final language = this.language;
    if (language == null || text.length > syntaxHighlightingMaxChars) {
      return const [];
    }
    if (!identical(_tokenizedText, text) ||
        !identical(_tokenizedLanguage, language)) {
      _tokens = tokenizeSyntax(text, language);
      _tokenizedText = text;
      _tokenizedLanguage = language;
    }
    return _tokens;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final composing = withComposing && value.isComposingRangeValid;
    if (composing || text.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final tokens = _tokensFor(text);
    if (tokens.isEmpty && _matches.isEmpty) {
      return TextSpan(style: style, text: text);
    }
    return TextSpan(
      style: style,
      children: buildHighlightedSpans(
        text: text,
        tokens: tokens,
        matches: _matches,
        activeMatchIndex: _activeMatchIndex,
        theme: theme,
      ),
    );
  }
}
