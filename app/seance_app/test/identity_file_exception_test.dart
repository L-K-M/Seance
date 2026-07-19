import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_services.dart';

void main() {
  group('IdentityFileException', () {
    const path = '/Users/ada/.ssh/id_ed25519';

    test('macOS EPERM gets the sandbox hint', () {
      final e = IdentityFileException(
        path,
        const FileSystemException(
            'Cannot open file', path, OSError('Operation not permitted', 1)),
        isMacOS: true,
      );
      expect('$e', contains(path));
      expect('$e', contains('Operation not permitted'));
      expect('$e', contains('~/.ssh'));
    });

    test('a missing file gets no sandbox hint', () {
      final e = IdentityFileException(
        path,
        const FileSystemException(
            'Cannot open file', path, OSError('No such file or directory', 2)),
        isMacOS: true,
      );
      expect('$e', contains('No such file or directory'));
      expect('$e', isNot(contains('~/.ssh only')));
    });

    test('EPERM off macOS gets no sandbox hint', () {
      final e = IdentityFileException(
        path,
        const FileSystemException(
            'Cannot open file', path, OSError('Operation not permitted', 1)),
        isMacOS: false,
      );
      expect('$e', isNot(contains('~/.ssh only')));
    });

    test('falls back to the exception message when the OS detail is absent',
        () {
      final withoutOsError = IdentityFileException(
        path,
        const FileSystemException('Cannot open file', path),
        isMacOS: true,
      );
      expect('$withoutOsError', contains('Cannot open file'));
      final emptyOsMessage = IdentityFileException(
        path,
        const FileSystemException('Cannot open file', path, OSError('', 2)),
        isMacOS: true,
      );
      expect('$emptyOsMessage', contains('Cannot open file'));
    });
  });
}
