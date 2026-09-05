import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/server_duplication.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  group('duplicateServerLabel', () {
    test('names the first copy and then numbers the rest', () {
      expect(duplicateServerLabel('web', const []), 'web copy');
      expect(duplicateServerLabel('web', const ['web', 'web copy']),
          'web copy 2');
      expect(
        duplicateServerLabel('web', const ['web', 'web copy', 'web copy 2']),
        'web copy 3',
      );
    });

    test('a copy of a copy continues the series instead of stuttering', () {
      // Not "web copy copy": the suffix comes back off before it goes back on.
      expect(duplicateServerLabel('web copy', const ['web copy']),
          'web copy 2');
      expect(
        duplicateServerLabel('web copy 2', const ['web copy', 'web copy 2']),
        'web copy 3',
      );
    });

    test('matches taken labels the way the list reads them', () {
      // The server list sorts case-insensitively, so "Web Copy" and "web copy"
      // are one name to the person looking at it.
      expect(duplicateServerLabel('web', const ['WEB COPY']), 'web copy 2');
      // And edge whitespace is not a difference either.
      expect(duplicateServerLabel('web', const ['  web copy  ']),
          'web copy 2');
    });

    test('a server named "copy" numbers rather than stutters', () {
      // The whole label is the suffix, so the series just continues.
      expect(duplicateServerLabel('copy', const ['copy']), 'copy 2');
      expect(duplicateServerLabel('copy 2', const ['copy', 'copy 2']),
          'copy 3');
      // An unnamed server (nothing enforces a label in the store) is the same
      // shape of input and must not produce a leading-spaced name.
      expect(duplicateServerLabel('', const []), 'copy');
    });

    test('leaves a word that merely starts with "copy" alone', () {
      expect(duplicateServerLabel('copyright', const []), 'copyright copy');
    });
  });

  group('duplicateServerConfig', () {
    ServerConfig source({
      String? secretRef,
      bool excludeFromSync = false,
      bool syncSecret = false,
    }) => ServerConfig(
      id: 'original',
      label: 'web',
      host: 'web.example.com',
      port: 2222,
      username: 'deploy',
      authMethod: AuthMethod.privateKey,
      secretRef: secretRef,
      identityFilePath: '/keys/id_ed25519',
      jumpHostId: 'bastion',
      syncSecret: syncSecret,
      group: 'Production',
      color: ServerColor.red,
      icon: ServerIcon.rocket,
      loginScript: 'tmux attach',
      excludeFromSync: excludeFromSync,
      createdAt: 100,
      updatedAt: 200,
    );

    test('takes a new identity and carries the rest over', () {
      final copy = duplicateServerConfig(
        source(secretRef: 'sec-old'),
        id: 'fresh',
        label: 'web copy',
        secretRef: 'sec-new',
        now: 999,
      );

      expect(copy.id, 'fresh');
      expect(copy.label, 'web copy');
      // Never the original's vault entry: deleting either server would strip
      // the credential from the other, and edits would rewrite it in place.
      expect(copy.secretRef, 'sec-new');
      // "Added on" for a copy is today, not the day the original was added.
      expect(copy.createdAt, 999);
      expect(copy.updatedAt, 999);

      expect(copy.host, 'web.example.com');
      expect(copy.port, 2222);
      expect(copy.username, 'deploy');
      expect(copy.authMethod, AuthMethod.privateKey);
      expect(copy.identityFilePath, '/keys/id_ed25519');
      expect(copy.jumpHostId, 'bastion');
      expect(copy.group, 'Production');
      expect(copy.color, ServerColor.red);
      expect(copy.icon, ServerIcon.rocket);
      expect(copy.loginScript, 'tmux attach');
    });

    test('a server with no credential copies as one with no credential', () {
      final copy = duplicateServerConfig(
        source(),
        id: 'fresh',
        label: 'web copy',
        secretRef: null,
        now: 999,
      );
      expect(copy.secretRef, isNull);
    });

    test('the sync answers are inherited, never widened', () {
      final copy = duplicateServerConfig(
        source(excludeFromSync: true, syncSecret: false),
        id: 'fresh',
        label: 'web copy',
        secretRef: null,
        now: 999,
      );
      // A copy of a server the user keeps off the sync server starts off it
      // too — the direction that cannot surprise anyone.
      expect(copy.excludeFromSync, isTrue);
      expect(copy.syncSecret, isFalse);
    });
  });

  testWidgets('the row menu offers Duplicate', (tester) async {
    var duplicated = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServerTile(
            server: ServerConfig(
              id: 's1',
              label: 'web',
              host: 'web.example.com',
              username: 'deploy',
              createdAt: 1,
              updatedAt: 2,
            ),
            connection: TerminalStatus.disconnected,
            tabCount: 0,
            reachability: ProbeStatus.unknown,
            selected: false,
            onTap: () {},
            onNewTab: () {},
            onEdit: () {},
            onDuplicate: () => duplicated++,
            onDelete: () {},
            onDisconnect: () {},
            onReconnect: null,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate'), findsOneWidget);

    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(duplicated, 1);
  });
}
