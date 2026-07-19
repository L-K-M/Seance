import 'package:seance_core/src/ssh/home_path.dart';
import 'package:test/test.dart';

void main() {
  group('expandHomePath', () {
    test('expands ~ and ~/ against HOME', () {
      const env = {'HOME': '/home/ada'};
      expect(expandHomePath('~', environment: env), '/home/ada');
      expect(
        expandHomePath('~/.ssh/id_ed25519', environment: env),
        '/home/ada/.ssh/id_ed25519',
      );
    });

    test('leaves absolute, relative, and ~user paths alone', () {
      const env = {'HOME': '/home/ada'};
      expect(expandHomePath('/etc/key', environment: env), '/etc/key');
      expect(expandHomePath('keys/id', environment: env), 'keys/id');
      expect(expandHomePath('~bob/.ssh/id', environment: env), '~bob/.ssh/id');
      expect(expandHomePath('~x', environment: env), '~x');
    });

    test('falls back to USERPROFILE, then to the input unchanged', () {
      expect(
        expandHomePath('~/k', environment: {'USERPROFILE': r'C:\Users\ada'}),
        r'C:\Users\ada/k',
      );
      expect(expandHomePath('~/k', environment: {}), '~/k');
      expect(expandHomePath('~/k', environment: {'HOME': ''}), '~/k');
    });

    test('strips the macOS sandbox container from HOME', () {
      // The exact regression: a sandboxed app's $HOME is the app container,
      // but ~/.ssh must mean the user's real .ssh directory.
      const env = {
        'HOME': '/Users/benedikt/Library/Containers/com.lkm.seanceApp/Data',
      };
      expect(
        expandHomePath('~/.ssh/id_rsa', environment: env, isMacOS: true),
        '/Users/benedikt/.ssh/id_rsa',
      );
      // A trailing slash on the container path changes nothing.
      expect(
        expandHomePath(
          '~/.ssh/id_rsa',
          environment: {'HOME': '${env['HOME']}/'},
          isMacOS: true,
        ),
        '/Users/benedikt/.ssh/id_rsa',
      );
    });

    test('keeps a non-container macOS HOME as-is', () {
      expect(
        expandHomePath(
          '~/.ssh/id_rsa',
          environment: {'HOME': '/Users/benedikt'},
          isMacOS: true,
        ),
        '/Users/benedikt/.ssh/id_rsa',
      );
    });

    test('does not strip container-like paths on other platforms', () {
      const env = {'HOME': '/home/x/Library/Containers/y/Data'};
      expect(
        expandHomePath('~/k', environment: env),
        '/home/x/Library/Containers/y/Data/k',
      );
    });
  });
}
