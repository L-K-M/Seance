import 'dart:io';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/local_shells.dart';

/// Words that must reach the program byte-for-byte whichever shell parses
/// them. Several would run `touch pwned` if the quoting broke.
final _roundTripWords = [
  '',
  ' ',
  "'",
  r'\',
  r"\'",
  r'\\',
  "it's",
  r'a\\b',
  r'''/tmp/x\'";touch pwned;#''',
  r"""\\'";touch pwned;#""",
  "'; touch pwned; '",
  r'$(touch pwned)',
  '(touch pwned)',
  '`touch pwned`',
  r'$HOME ${HOME} $fish_pid %self',
  '~ ~/x *.txt ? [ab] {a,b} !! #',
  'line one\nline two',
  'caf\u00e9 \u6587\u4ef6',
  String.fromCharCodes(Iterable<int>.generate(0x7f - 0x20, (i) => i + 0x20)),
];

void main() {
  group('quoteShellWord', () {
    test('pins the spelling of every character the shells treat specially', () {
      const cases = <String, String>{
        '': "''",
        'plain': "'plain'",
        "'": '"\'"',
        r'\': r'"\\"',
        "it's": "'it'\"'\"'s'",
        r'a\b': r"""'a'"\\"'b'""",
        r"\'": r'''"\\""'"''',
        r'a\\b': r"""'a'"\\""\\"'b'""",
        r'''/tmp/x\'";touch PWNED;#''': r"""'/tmp/x'"\\""'"'";touch PWNED;#'""",
        r'$(touch pwned)': r"'$(touch pwned)'",
        '`touch pwned`': "'`touch pwned`'",
        'line one\nline two': "'line one\nline two'",
      };
      cases.forEach((word, quoted) {
        expect(quoteShellWord(word), quoted, reason: 'word: $word');
      });
    });

    for (final shell in localShells.keys) {
      test('round-trips byte-exact through $shell -c', () async {
        final directory = await Directory.systemTemp.createTemp(
          'seance-quote-',
        );
        addTearDown(() => directory.delete(recursive: true));

        for (final word in _roundTripWords) {
          final result = await runInShell(
            shell,
            'printf %s ${quoteShellWord(word)}',
            workingDirectory: directory.path,
          );
          expect(result.exitCode, 0, reason: 'word: $word\n${result.stderr}');
          expect(result.stdout, word, reason: 'word: $word');
        }
        expect(
          directory.listSync(),
          isEmpty,
          reason: 'a quoted word ran as a command',
        );
      }, skip: shellSkipReason(shell));
    }
  });

  group('buildChangeDirectoryCommand', () {
    test('builds commands for root and ordinary absolute paths', () {
      expect(
        buildChangeDirectoryCommand('/', shell: RemoteShellKind.posix),
        "cd '/'",
      );
      expect(
        buildChangeDirectoryCommand(
          '/srv/www/site',
          shell: RemoteShellKind.fish,
        ),
        "cd '/srv/www/site'",
      );
    });

    test('quotes POSIX metacharacters and whitespace as literal path text', () {
      const path = r'/tmp/$HOME;$(touch pwned)&|<>*?[]{}()!# name';
      expect(
        buildChangeDirectoryCommand(path, shell: RemoteShellKind.posix),
        r"cd '/tmp/$HOME;$(touch pwned)&|<>*?[]{}()!# name'",
      );
    });

    test('spells quotes and backslashes the same for every shell', () {
      // fish treats `\'` and `\\` inside single quotes as escapes, so one
      // spelling that avoids both is safe whichever shell really parses it.
      const path = r"/tmp/a'b\c";
      for (final shell in RemoteShellKind.values) {
        expect(
          buildChangeDirectoryCommand(path, shell: shell),
          r"""cd '/tmp/a'"'"'b'"\\"'c'""",
        );
      }
    });

    test('preserves printable Unicode path text', () {
      const path = '/srv/caf\u00e9/\u6587\u4ef6';
      for (final shell in RemoteShellKind.values) {
        expect(buildChangeDirectoryCommand(path, shell: shell), "cd '$path'");
      }
    });

    test('accepts every printable ASCII character safely', () {
      final path =
          '/${String.fromCharCodes(Iterable<int>.generate(0x7f - 0x20, (index) => index + 0x20))}';

      for (final shell in RemoteShellKind.values) {
        final command = buildChangeDirectoryCommand(path, shell: shell);
        expect(command, startsWith('cd '));
        expect(command, isNot(contains('\n')));
        expect(command, isNot(contains('\r')));
        expect(command, isNot(contains('\x1b')));
      }
    });

    test('rejects empty and non-absolute paths', () {
      for (final path in [
        '',
        '.',
        'tmp/files',
        '~/files',
        r'C:\files',
        ' /tmp',
      ]) {
        expect(
          () => buildChangeDirectoryCommand(path, shell: RemoteShellKind.posix),
          throwsArgumentError,
          reason: 'path: $path',
        );
      }
    });

    test('rejects C0, DEL, and C1 control characters', () {
      final controls = <int>[
        ...Iterable<int>.generate(0x20),
        ...Iterable<int>.generate(0x21, (index) => index + 0x7f),
      ];

      for (final codePoint in controls) {
        final path = '/tmp/a${String.fromCharCode(codePoint)}b';
        expect(
          () => buildChangeDirectoryCommand(path, shell: RemoteShellKind.fish),
          throwsArgumentError,
          reason: 'code point: 0x${codePoint.toRadixString(16)}',
        );
      }
    });

    for (final shell in localShells.keys) {
      test('changes into hostile directory names under $shell', () async {
        final root = await Directory.systemTemp.createTemp('seance-cd-');
        addTearDown(() => root.delete(recursive: true));
        final kind = shell == 'fish'
            ? RemoteShellKind.fish
            : RemoteShellKind.posix;
        final names = [
          r'''x\'";touch pwned;#''',
          r'''\\'";touch pwned;#''',
          // Every printable ASCII character a file name can hold.
          String.fromCharCodes(
            Iterable<int>.generate(0x7f - 0x20, (i) => i + 0x20),
          ).replaceAll('/', ''),
        ];

        for (final name in names) {
          final target = await Directory('${root.path}/$name').create();
          final command = buildChangeDirectoryCommand(target.path, shell: kind);
          final result = await runInShell(
            shell,
            '$command && pwd',
            workingDirectory: root.path,
          );
          expect(
            result.stdout,
            '${target.path}\n',
            reason: 'name: $name\n${result.stderr}',
          );
        }
        expect(File('${root.path}/pwned').existsSync(), isFalse);
      }, skip: shellSkipReason(shell));
    }

    test('never appends input that would execute the command', () {
      for (final shell in RemoteShellKind.values) {
        final command = buildChangeDirectoryCommand(
          '/tmp/review me; exit',
          shell: shell,
        );
        expect(command, isNot(endsWith('\n')));
        expect(command, isNot(endsWith('\r')));
        expect(command, isNot(contains('\x1b')));
      }
    });
  });
}
