import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart'
    show
        TerminalStatus,
        SourceServerChanged,
        duplicationSourceUnchanged,
        secretStillReferenced;
import 'package:seance_app/services/app_settings.dart'
    show IdentityFileBookmark;
import 'package:seance_app/services/app_services.dart' show LockedSecretVault;
import 'package:seance_app/services/secure_master_key.dart'
    show VaultLockedException;
import 'package:seance_app/services/server_duplication.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  group('duplicateServerLabel', () {
    test('names the first copy and then numbers the rest', () {
      expect(duplicateServerLabel('web', const []), 'web copy');
      // Fills from the front rather than continuing past the highest taken
      // number: with only "web copy 2" in the way, the first copy is still
      // "web copy". Pinned because both rules are defensible and nothing
      // else says which one ships.
      expect(duplicateServerLabel('web', const ['web copy 2']), 'web copy');
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
      // A trailing number on its own is not the duplicate series: "web 2" is
      // a name someone chose, so its first copy is "web 2 copy" rather than
      // "web copy" (stripped as if it were one) or "web 3" (continued as one).
      expect(duplicateServerLabel('web 2', const []), 'web 2 copy');
      expect(
        duplicateServerLabel('web 2', const ['web 2', 'web 2 copy']),
        'web 2 copy 2',
      );
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

    test('carries over every field a copy is allowed to share', () {
      // Compared as JSON against the source rather than field by field, so a
      // field added to ServerConfig later fails here — but only once the
      // `source()` fixture above gives it a non-default value, since a field
      // left at its default matches on both sides. Set it there when you add
      // one, or it is silently reset on every copy.
      final original = source(secretRef: 'sec-old', syncSecret: true);
      final copy = duplicateServerConfig(
        original,
        id: 'fresh',
        label: 'web copy',
        secretRef: 'sec-new',
        now: 999,
      );
      expect(
        copy.toJson(),
        {...original.toJson()}
          ..['id'] = 'fresh'
          ..['label'] = 'web copy'
          ..['secretRef'] = 'sec-new'
          ..['createdAt'] = 999
          ..['updatedAt'] = 999,
      );
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

    // Scoped to the tile: any other popup menu pumped beside it would make
    // this ambiguous, and the failure would not say why.
    await tester.tap(find.descendant(
      of: find.byType(ServerTile),
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate'), findsOneWidget);

    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(duplicated, 1);
  });

  group('planServerDuplication', () {
    SecretVault vault() =>
        SecretVault(InMemoryVaultStore(), List.filled(32, 7));

    ServerConfig source({String? secretRef}) => ServerConfig(
      id: 'original',
      label: 'web',
      host: 'web.example.com',
      username: 'deploy',
      authMethod: AuthMethod.privateKey,
      // A Browse…-picked key always has both a path and a grant, so the
      // fixture carries both rather than a grant with nothing to open.
      identityFilePath: '/keys/id_ed25519',
      secretRef: secretRef,
      createdAt: 1,
      updatedAt: 2,
    );

    test('planning writes nothing, which is what lets the save be aborted',
        () async {
      final writes = <String>[];
      // The guard runs between the plan and the save, so `SourceServerChanged`
      // can promise nothing was created — but only while planning stays a
      // read. A vault write moved in here would strand an entry no server
      // names, and nothing reference-counts those.
      final store = SecretVault(_RecordingVaultStore(writes), List.filled(32, 7));
      await store.putSecret(const Secret(
        id: 'sec-old',
        kind: SecretKind.password,
        value: 'hunter2',
      ));
      writes.clear();
      final plan = await planServerDuplication(
        source(secretRef: 'sec-old'),
        vault: store,
        takenLabels: const [],
        id: 'copy-1',
        secretId: 'sec-new',
        now: 100,
      );

      expect(plan.secret?.id, 'sec-new');
      // Every write, not just the one id the plan happens to name: a write
      // under any other id would strand an entry no server references, and
      // nothing reference-counts those.
      expect(writes, isEmpty,
          reason: 'the planned entry is written by the save, not the plan');
      expect((await store.getSecret('sec-old'))?.value, 'hunter2');
    });

    test('copies the credential into a vault entry of its own', () async {
      final store = vault();
      await store.putSecret(const Secret(
        id: 'sec-old',
        kind: SecretKind.privateKey,
        value: 'PEM',
        keyPassphrase: 'phrase',
      ));

      final plan = await planServerDuplication(
        source(secretRef: 'sec-old'),
        vault: store,
        takenLabels: const ['web'],
        id: 'fresh',
        secretId: 'sec-new',
        now: 999,
      );

      // Never the original's entry: deleting either server would strip the
      // credential from the other, and edits would rewrite it in place.
      expect(plan.config.secretRef, 'sec-new');
      // Compared as JSON with only the id overridden, like the config's own
      // carryover test — and with the same caveat: a field Secret gains later
      // is only caught here once the fixture above gives it a non-default
      // value, since one left at its default matches on both sides.
      final original = (await store.getSecret('sec-old'))!;
      expect(
        plan.secret!.toJson(),
        {...original.toJson()}..['id'] = 'sec-new',
      );
      // Spelled out as well, because these are the two that stop a copy
      // connecting: the material and the passphrase that opens it.
      expect(plan.secret!.value, 'PEM');
      expect(plan.secret!.keyPassphrase, 'phrase');
      expect(plan.config.label, 'web copy');
    });

    test('a dangling reference plans as no credential, not as a failure',
        () async {
      // The original is already in this state; the copy is not the place to
      // discover it.
      final plan = await planServerDuplication(
        source(secretRef: 'sec-gone'),
        vault: vault(),
        takenLabels: const [],
        id: 'fresh',
        secretId: 'sec-new',
        now: 999,
      );
      expect(plan.secret, isNull);
      expect(plan.config.secretRef, isNull);
    });

    test('a locked vault fails instead of losing the credential', () async {
      // A duplicate that quietly lost its password would look identical in the
      // list and only admit it at connect time.
      await expectLater(
        planServerDuplication(
          source(secretRef: 'sec-old'),
          vault: LockedSecretVault(InMemoryVaultStore()),
          takenLabels: const [],
          id: 'fresh',
          secretId: 'sec-new',
          now: 999,
        ),
        throwsA(isA<VaultLockedException>()),
      );
    });

    test('carries the source grant over to the copy', () async {
      // The one line this feature's doc calls load-bearing: without it a
      // duplicate of a Browse…-picked key falls back to the raw path and
      // cannot open a key outside ~/.ssh. It is planned, not read at the save
      // site, so it can be asserted without an AppState.
      const grant = IdentityFileBookmark(path: '/keys/id', bookmark: 'b64');
      final plan = await planServerDuplication(
        source(),
        vault: vault(),
        takenLabels: const [],
        id: 'fresh',
        secretId: 'sec-new',
        now: 999,
        bookmarkFor: (id) => id == 'original' ? grant : null,
      );
      // Looked up under the *source's* id — the grant is keyed by server, and
      // the copy does not have one yet.
      expect(plan.identityFileBookmark, grant);
    });

    test('a server with no credential needs no vault read', () async {
      final plan = await planServerDuplication(
        source(),
        vault: LockedSecretVault(InMemoryVaultStore()),
        takenLabels: const [],
        id: 'fresh',
        secretId: 'sec-new',
        now: 999,
      );
      expect(plan.secret, isNull);
    });
  });

  group('mutation-zone timers', () {
    test('a timer inherits the zone it was created in, not the one it fires in',
        () async {
      // The rule the auto-sync debounce turns on: `_mutate` marks its zone,
      // and a timer scheduled from inside a mutation would carry that marker
      // into a sync round that is not one — tripping the re-entrancy assert on
      // every save. A `createTimer` override cannot undo it, because the
      // callback is bound to the creating zone before the override sees it;
      // creating it in a captured outer zone is what works.
      final outside = Zone.current;
      final seen = <String, Object?>{};
      final done = Completer<void>();

      runZoned(() {
        Timer(Duration.zero, () => seen['inside'] = Zone.current[#mutation]);
        outside.run(() => Timer(Duration.zero, () {
              seen['outside'] = Zone.current[#mutation];
              done.complete();
            }));
      }, zoneValues: {#mutation: true});

      await done.future;
      expect(seen['inside'], isTrue);
      expect(seen['outside'], isNull);
    });
  });

  group('duplicationSourceUnchanged', () {
    ServerConfig at(String? ref) => ServerConfig(
      id: 'original',
      label: 'web',
      host: 'web.example.com',
      username: 'deploy',
      secretRef: ref,
      createdAt: 1,
      updatedAt: 2,
    );

    test('only the credential reference decides', () {
      // The vault read a duplicate plans from can wait out a keychain prompt,
      // and a sync round is not behind the same queue the UI's own deletes
      // are: it can withdraw the credential and remove the server first.
      expect(duplicationSourceUnchanged(at('sec-1'), at('sec-1')), isTrue);
      expect(duplicationSourceUnchanged(null, at('sec-1')), isFalse);
      expect(duplicationSourceUnchanged(at('sec-2'), at('sec-1')), isFalse);
      expect(duplicationSourceUnchanged(at(null), at('sec-1')), isFalse);
      // A server that never had one is not "changed" for having none now.
      expect(duplicationSourceUnchanged(at(null), at(null)), isTrue);
      // A rename between the plan and the save costs the copy nothing: it
      // carries its own label, and the credential is what was read early.
      expect(
        duplicationSourceUnchanged(
          at('sec-1').copyWith(label: 'renamed', updatedAt: 9),
          at('sec-1'),
        ),
        isTrue,
      );
    });

    test('the failure says which server and that nothing was created', () {
      // The list pane interpolates this into "Could not duplicate: $error",
      // so it has to read as a sentence rather than a class name.
      final message = const SourceServerChanged('web').toString();
      expect(message, contains('"web"'));
      expect(message, contains('Nothing was created'));
      expect(message, isNot(contains('Exception')));
    });
  });

  group('secretStillReferenced', () {
    ServerConfig at(String id, String? secretRef) => ServerConfig(
      id: id,
      label: id,
      host: 'h',
      username: 'u',
      secretRef: secretRef,
      createdAt: 1,
      updatedAt: 2,
    );

    test('a credential another server names survives its owner', () {
      // Nothing stops two configs sharing one vault entry, and deleting it
      // out from under the survivor is silent credential loss it only
      // discovers at connect time.
      final servers = [at('a', 'shared'), at('b', 'shared'), at('c', 'own')];
      expect(
        secretStillReferenced('shared', servers, excludingId: 'a'),
        isTrue,
      );
      // The server being deleted does not count as a reference to itself.
      expect(secretStillReferenced('own', servers, excludingId: 'c'), isFalse);
      // Nor does a credential nothing names at all.
      expect(secretStillReferenced('gone', servers, excludingId: 'a'), isFalse);
    });
  });
}

/// Records every write so a test can assert a read-only path touched nothing,
/// under any id rather than only the one it expected.
class _RecordingVaultStore extends InMemoryVaultStore {
  _RecordingVaultStore(this.writes);
  final List<String> writes;

  @override
  Future<void> putSecretBlob(String id, Uint8List blob) async {
    writes.add(id);
    return super.putSecretBlob(id, blob);
  }
}

