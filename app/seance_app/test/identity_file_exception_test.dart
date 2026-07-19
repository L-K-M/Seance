import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_services.dart';

void main() {
  group('IdentityFileException', () {
    const path = '/Users/ada/.ssh/id_ed25519';
    // A stable fragment of the sandbox hint, present iff the hint is shown.
    const hint = 'paste it into the server settings';

    test('macOS EPERM gets the sandbox hint', () {
      final e = IdentityFileException(
        '/Users/ada/Documents/key.pem',
        const FileSystemException('Cannot open file', path,
            OSError('Operation not permitted', 1)),
        isMacOS: true,
      );
      expect('$e', contains('/Users/ada/Documents/key.pem'));
      expect('$e', contains('Operation not permitted'));
      expect('$e', contains(hint));
    });

    test('macOS EPERM on a ~/.ssh path still gets the hint', () {
      // The sandbox can deny a read under ~/.ssh too — typically a symlink
      // pointing elsewhere, since the resolved path is what's checked. The
      // hint is worded to cover that ("as a real file"), so it must show.
      final e = IdentityFileException(
        path,
        const FileSystemException(
            'Cannot open file', path, OSError('Operation not permitted', 1)),
        isMacOS: true,
      );
      expect('$e', contains(hint));
      expect('$e', contains('real file'));
    });

    test('a missing file gets no sandbox hint', () {
      final e = IdentityFileException(
        path,
        const FileSystemException(
            'Cannot open file', path, OSError('No such file or directory', 2)),
        isMacOS: true,
      );
      expect('$e', contains('No such file or directory'));
      expect('$e', isNot(contains(hint)));
    });

    test('EPERM off macOS gets no sandbox hint', () {
      final e = IdentityFileException(
        path,
        const FileSystemException(
            'Cannot open file', path, OSError('Operation not permitted', 1)),
        isMacOS: false,
      );
      expect('$e', isNot(contains(hint)));
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
