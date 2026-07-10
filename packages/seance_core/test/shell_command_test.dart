import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
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

    test('escapes POSIX single quotes without changing backslashes', () {
      const path = r"/tmp/a'b\c";
      expect(
        buildChangeDirectoryCommand(path, shell: RemoteShellKind.posix),
        "cd '/tmp/a'\"'\"'b\\c'",
      );
    });

    test('uses cross-shell-safe quote segments for fish', () {
      const path = r"/tmp/a'b\c";
      expect(
        buildChangeDirectoryCommand(path, shell: RemoteShellKind.fish),
        "cd '/tmp/a'\"'\"'b\\c'",
      );
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
