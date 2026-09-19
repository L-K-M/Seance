import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/session_label.dart';

void main() {
  group('sessionTabLabel', () {
    test('falls back to the ordinal when the shell reports nothing', () {
      expect(sessionTabLabel(ordinal: 2), 'Session 2');
      expect(
        sessionTabLabel(ordinal: 1, workingDirectory: '', terminalTitle: ''),
        'Session 1',
      );
    });

    test('prefers the working directory basename', () {
      expect(
        sessionTabLabel(
          ordinal: 1,
          workingDirectory: '/var/log/nginx',
          terminalTitle: 'ops@web-01: /var/log/nginx',
        ),
        'nginx',
      );
    });

    test('names the root directory', () {
      expect(sessionTabLabel(ordinal: 1, workingDirectory: '/'), '/');
    });

    test('ignores a relative or malformed directory and uses the title', () {
      expect(
        sessionTabLabel(
          ordinal: 3,
          workingDirectory: 'var/log',
          terminalTitle: 'building',
        ),
        'building',
      );
    });

    test('uses the terminal title when there is no OSC 7 directory', () {
      expect(sessionTabLabel(ordinal: 1, terminalTitle: 'htop'), 'htop');
    });

    test('keeps the distinguishing tail when shortening', () {
      final label = sessionTabLabel(
        ordinal: 1,
        terminalTitle: 'deploy staging eu-west-1',
        maxLength: 10,
      );
      expect(label.length, 10);
      expect(label.startsWith('…'), isTrue);
      expect(label.endsWith('eu-west-1'), isTrue);
    });

    test('never splits a grapheme cluster', () {
      // Family emoji is a multi-codepoint ZWJ sequence.
      final label = sessionTabLabel(
        ordinal: 1,
        terminalTitle: 'aaaa👩‍👩‍👧‍👦',
        maxLength: 3,
      );
      // Two grapheme clusters kept plus the ellipsis — and the family emoji
      // survives whole rather than being cut mid-sequence.
      expect(label, '…a👩‍👩‍👧‍👦');
    });
  });

  group('remote text is untrusted', () {
    test('control characters and newlines cannot escape the label', () {
      expect(
        sanitizeRemoteLabel('onetwo\nthree\r\n  four'),
        'one two three four',
      );
    });

    test('bidi overrides and zero-width characters are stripped', () {
      expect(sanitizeRemoteLabel('safe\u202Egnahc\u200B\uFEFF'), 'safe gnahc');
    });

    test('a hostile title is sanitized before it reaches the tab', () {
      expect(
        sessionTabLabel(ordinal: 1, terminalTitle: 'ok\nrm -rf /'),
        'ok rm -rf /',
      );
    });
  });

  group('sessionTabTooltip', () {
    test('names the session, its target, and its reported location', () {
      expect(
        sessionTabTooltip(
          ordinal: 2,
          target: 'ops@web-01:22',
          workingDirectory: '/srv/app',
          terminalTitle: 'ops@web-01: /srv/app',
        ),
        'Session 2 · ops@web-01:22\n/srv/app\nops@web-01: /srv/app',
      );
    });

    test('omits what the shell has not reported', () {
      expect(
        sessionTabTooltip(ordinal: 1, target: 'root@db:2222'),
        'Session 1 · root@db:2222',
      );
    });

    test('does not repeat a title identical to the directory', () {
      expect(
        sessionTabTooltip(
          ordinal: 1,
          target: 'a@b:22',
          workingDirectory: '/srv',
          terminalTitle: '/srv',
        ),
        'Session 1 · a@b:22\n/srv',
      );
    });
  });

  group('running command in the label', () {
    test('what the tab is doing beats where it is', () {
      expect(
        sessionTabLabel(
          ordinal: 1,
          workingDirectory: '/srv/app',
          terminalTitle: 'ops@web: /srv/app',
          runningCommand: 'tail -f app.log',
        ),
        'tail -f app.log',
      );
    });

    test('a long command keeps its head, not its tail', () {
      expect(
        sessionTabLabel(
          ordinal: 1,
          runningCommand: 'rsync -avz --progress ./build deploy@web:/srv',
          maxLength: 12,
        ),
        'rsync -avz\u2026',
      );
    });

    test('a command is sanitized like any remote text', () {
      expect(
        sessionTabLabel(ordinal: 1, runningCommand: 'ok\u202ekcatta'),
        'ok kcatta',
      );
    });

    test('an absent or blank command falls through to the directory', () {
      expect(
        sessionTabLabel(
          ordinal: 1,
          workingDirectory: '/srv/app',
          runningCommand: '  ',
        ),
        'app',
      );
    });
  });

  group('editorTabLabel', () {
    test('names the file by its basename', () {
      expect(editorTabLabel('/etc/nginx/nginx.conf'), 'nginx.conf');
      expect(editorTabLabel('/var/log/app/debug.log'), 'debug.log');
    });

    test('falls back to "File" when the path has no basename', () {
      expect(editorTabLabel('/'), 'File');
      expect(editorTabLabel('relative/path.txt'), 'File');
    });

    test('a hostile path is sanitized before it reaches the tab', () {
      expect(editorTabLabel('/etc/ok\nrm -rf'), 'ok rm -rf');
    });

    test('keeps the distinguishing tail when shortening', () {
      final label = editorTabLabel(
        '/srv/app/config/very-long-file-name.conf',
        maxLength: 10,
      );
      expect(label.length, 10);
      expect(label.startsWith('…'), isTrue);
      expect(label.endsWith('name.conf'), isTrue);
    });
  });

  group('editorTabTooltip', () {
    test('names the full path and the owning session', () {
      expect(
        editorTabTooltip(
          remotePath: '/etc/nginx/nginx.conf',
          target: 'ops@web-01:22',
        ),
        '/etc/nginx/nginx.conf\nops@web-01:22',
      );
    });

    test('flags unsaved changes', () {
      expect(
        editorTabTooltip(
          remotePath: '/etc/hosts',
          target: 'ops@web-01:22',
          dirty: true,
        ),
        '/etc/hosts\nops@web-01:22\nUnsaved changes',
      );
    });

    test('sanitizes the target line too', () {
      // The target string is assembled from server config — one hostile
      // config value must not smuggle extra lines into the tooltip.
      expect(
        editorTabTooltip(
          remotePath: '/etc/hosts',
          target: 'ops@web-01\nnot a newline',
        ),
        '/etc/hosts\nops@web-01 not a newline',
      );
    });

    test('sanitizes a hostile remote path', () {
      // Remote filenames can carry newlines; a hostile path must not be
      // able to forge tooltip lines such as a fake "Unsaved changes" flag.
      expect(
        editorTabTooltip(
          remotePath: '/etc/hosts\nUnsaved changes',
          target: 'ops@web-01:22',
        ),
        '/etc/hosts Unsaved changes\nops@web-01:22',
      );
    });
  });

  group('disambiguateTabLabels', () {
    test('unique labels pass through untouched', () {
      expect(disambiguateTabLabels(['app', 'logs', '~']), ['app', 'logs', '~']);
    });

    test('duplicates get stable ordinals in tab order', () {
      expect(disambiguateTabLabels(['~', '~', 'app', '~']), [
        '~ \u00b71',
        '~ \u00b72',
        'app',
        '~ \u00b73',
      ]);
    });

    test('independent duplicate groups number independently', () {
      expect(disambiguateTabLabels(['a', 'b', 'a', 'b']), [
        'a \u00b71',
        'b \u00b71',
        'a \u00b72',
        'b \u00b72',
      ]);
    });

    test('an empty strip is fine', () {
      expect(disambiguateTabLabels([]), isEmpty);
    });
  });

  group('tooltip with a running command', () {
    test('says what is running above where it is', () {
      expect(
        sessionTabTooltip(
          ordinal: 1,
          target: 'ops@web:22',
          workingDirectory: '/srv/app',
          runningCommand: 'htop',
        ),
        'Session 1 \u00b7 ops@web:22\nRunning: htop\n/srv/app',
      );
    });
  });
}
