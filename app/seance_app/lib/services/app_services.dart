import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seance_core/seance_core.dart';

import 'app_settings.dart';
import 'assistant_settings_sync.dart';
import 'command_stats.dart';
import 'external_file_opener.dart';
import 'file_stores.dart';
import 'identity_audit_log.dart';
import 'identity_bookmarks.dart';
import 'managed_remote_file_store.dart';
import 'secure_master_key.dart';

/// A "reference, don't store" identity file couldn't be read at connect time.
/// [toString] is the user-facing connection-failure message, so it names the
/// resolved path (after `~` expansion) and, when the macOS sandbox denied the
/// read, says how to get a readable key instead of surfacing a bare EPERM.
class IdentityFileException implements Exception {
  final String path;
  final FileSystemException cause;
  // Injectable so the hint branch is unit-testable off-macOS (CI runs Linux).
  final bool isMacOS;
  IdentityFileException(this.path, this.cause, {bool? isMacOS})
      : isMacOS = isMacOS ?? Platform.isMacOS;

  @override
  String toString() {
    final os = cause.osError?.message;
    final detail = (os == null || os.isEmpty) ? cause.message : os;
    // errno 1 = EPERM: the app sandbox blocked the read. The entitlements
    // cover only files physically under ~/.ssh, so this also fires for a
    // ~/.ssh entry that is a symlink elsewhere (the sandbox checks the
    // resolved path) — the wording below has to fit that case too.
    final sandboxHint = isMacOS && cause.osError?.errorCode == 1
        ? ' The macOS sandbox lets Séance read keys only from ~/.ssh or '
            'files granted via Browse… — store the key in ~/.ssh as a real '
            'file (a symlink to another folder won\'t open), re-pick it with '
            'Browse…, or paste it into the server settings instead of '
            'referencing a file.'
        : '';
    return 'Could not read identity file $path — $detail.$sandboxHint';
  }
}

/// A vault without its key: the OS keystore was unavailable at bootstrap, so
/// no key exists this session. Reads and writes fail with a clear message
/// instead of decrypting with a wrong key (which would look like corruption)
/// or fabricating an ephemeral one (which would silently orphan anything saved
/// now on the next launch). Deleting stays legal — it needs no key.
class LockedSecretVault extends SecretVault {
  LockedSecretVault(VaultStore store) : super(store, const <int>[]);

  @override
  Future<Secret?> getSecret(String id) async => throw const VaultLockedException();

  @override
  Future<void> putSecret(Secret secret) async => throw const VaultLockedException();

  @override
  Future<void> putSecrets(Iterable<Secret> secrets) async =>
      throw const VaultLockedException();
}

/// Wires together the seance_core services with the app's file-backed stores
/// and the OS keystore. Created once at startup.
class AppServices {
  final ConfigStore configStore;
  final SnippetStore snippetStore;
  /// Durable record of deletions awaiting sync (see [TombstoneStore]). Without
  /// it a deleted server returns on the next full pull, since the sync mirror
  /// is rebuilt each round.
  final TombstoneStore tombstoneStore;
  // Mutable so sync enrolment can re-key the vault to the shared encryption key.
  SecretVault vault;
  final HostKeyStore hostKeyStore;
  final TofuVerifier tofu;
  final ProbeService probe;
  final MasterKeyManager masterKeys;
  final SettingsStore settingsStore;
  final CommandStatsStore commandStatsStore;
  final CommandStats commandStats;
  final ManagedRemoteFileStore managedRemoteFiles;
  final IdentityFileBookmarks identityBookmarks;
  final IdentityAuditLog identityAudit;
  /// Null while the vault is locked (keystore unavailable at bootstrap — see
  /// [LockedSecretVault] and [unlockVaultFromKeystore]).
  List<int>? vaultKey;
  AppSettings settings;

  /// Whether the last [runSync] adopted a pulled assistant configuration. The
  /// chat provider is built once per configuration version, so a new model or
  /// key only takes effect if somebody rebuilds it.
  ///
  /// True from the end of a round that adopted until the start of the next
  /// one, which resets it first thing. Read it right after the round that set
  /// it, in the same call: rounds are serialized behind `AppState._mutate`,
  /// but a reader that awaits something else in between can find the next
  /// round has already begun and cleared it.
  ///
  /// Raised in a `finally`, so a round that applied the record and *then*
  /// failed still reports the adoption — which is the case it was put there
  /// for. Read it from a `finally` around [runSync] rather than only on the
  /// success path, or that round's adoption is the one that goes unseen.
  /// Read-only to everything but [runSync], which owns both writes. The
  /// field was public and settable, and its whole correctness argument is
  /// about *when* it is written relative to the round — so a second writer
  /// anywhere would not fail to compile, would not fail a test, and would
  /// cost an adopted provider its rebuild in exactly the silent way this
  /// flag exists to prevent.
  bool get assistantSettingsChanged => _assistantSettingsChanged;
  bool _assistantSettingsChanged = false;

  AppServices._({
    required this.configStore,
    required this.snippetStore,
    required this.tombstoneStore,
    required this.vault,
    required this.hostKeyStore,
    required this.tofu,
    required this.probe,
    required this.masterKeys,
    required this.settingsStore,
    required this.commandStatsStore,
    required this.commandStats,
    required this.managedRemoteFiles,
    required this.identityBookmarks,
    required this.identityAudit,
    required this.vaultKey,
    required this.settings,
  });

  /// [masterKeyManager] is for tests that need the OS keystore to misbehave
  /// (a locked keyring refusing the re-key's install, say); production passes
  /// nothing and gets the real one.
  static Future<AppServices> initialize({
    @visibleForTesting MasterKeyManager? masterKeyManager,
  }) async {
    final dir = await getApplicationSupportDirectory();
    String p(String name) => '${dir.path}/$name';

    final masterKeys = masterKeyManager ?? MasterKeyManager();
    // May be null when the OS keystore is locked or unavailable (locked login
    // keyring on auto-login systems, no Secret Service daemon on minimal
    // desktops): the app then starts with a locked vault — secrets unreadable
    // and unwritable with a clear error, retry offered in the UI — instead of
    // crashing before the shell exists.
    final vaultKey = await masterKeys.probeKeystore();

    final configStore = FileConfigStore(File(p('servers.json')));
    final snippetStore = FileSnippetStore(File(p('snippets.json')));
    final tombstoneStore = FileTombstoneStore(File(p('deleted_records.json')));
    final vaultStore = FileVaultStore(File(p('vault.json')));
    final hostKeyStore = FileHostKeyStore(File(p('known_hosts.json')));
    final settingsStore = SettingsStore(File(p('settings.json')));
    final commandStatsStore = CommandStatsStore(File(p('command_stats.json')));
    final managedRemoteFiles = ManagedRemoteFileStore(
      indexFile: File(p('managed_remote_files.json')),
      checkoutRoot: Directory(p('sftp-checkouts')),
    );
    final settings = await settingsStore.load();
    var settingsChanged = false;
    if (settings.deviceId.isEmpty) {
      settings.deviceId = uuidV4();
      settingsChanged = true;
    }
    if ((Platform.isAndroid || Platform.isIOS) &&
        settings.editorRegistry.defaultEditorId ==
            EditorRegistry.systemDefaultId) {
      settings.editorRegistry.defaultEditorId = EditorRegistry.builtInId;
      settingsChanged = true;
    }
    if (settingsChanged) await settingsStore.save(settings);

    return AppServices._(
      configStore: configStore,
      snippetStore: snippetStore,
      tombstoneStore: tombstoneStore,
      vault: vaultKey == null
          ? LockedSecretVault(vaultStore)
          : SecretVault(vaultStore, vaultKey),
      hostKeyStore: hostKeyStore,
      tofu: TofuVerifier(hostKeyStore),
      probe: ProbeService(),
      masterKeys: masterKeys,
      settingsStore: settingsStore,
      commandStatsStore: commandStatsStore,
      commandStats: await commandStatsStore.load(),
      managedRemoteFiles: managedRemoteFiles,
      identityBookmarks: IdentityFileBookmarks(),
      identityAudit: IdentityAuditLog(File(p('identity_reads.jsonl'))),
      vaultKey: vaultKey,
      settings: settings,
    );
  }

  /// Re-probe the OS keystore and, if it's back, unlock the vault in place
  /// (existing references to [vault] keep working — the key is swapped into a
  /// fresh instance). Returns whether the vault has a key afterwards.
  Future<bool> unlockVaultFromKeystore() async {
    if (vaultKey != null) return true;
    final key = await masterKeys.probeKeystore();
    if (key == null) return false;
    vault = SecretVault(vault.store, key);
    vaultKey = key;
    return true;
  }

  /// True when the settings file could not be parsed at startup and was moved
  /// aside. The UI surfaces this once, because a silent reset of the sync
  /// account, provider configuration and editor registry is not something the
  /// user should be left to discover on their own.
  bool get settingsWereRecovered => settingsStore.recoveredFromCorruptFile;

  Future<void> saveSettings() => settingsStore.save(settings);

  Future<void> saveCommandStats() => commandStatsStore.save(commandStats);

  /// Whether sync enrolment has happened on this device (a server URL is set).
  /// The bearer token check in [runSync] is the authoritative gate; this is the
  /// cheap synchronous check the auto-sync scheduler uses.
  bool get isSyncConfigured =>
      settings.syncBaseUrl != null && settings.syncBaseUrl!.isNotEmpty;

  /// Re-key the vault to [newKey], re-encrypting secrets referenced by current
  /// configs so nothing is lost. Used by sync enrolment to adopt the shared,
  /// encryption-passphrase-derived key.
  Future<void> _rekeyVault(List<int> newKey) async {
    final secretRefs = {
      for (final cfg in await configStore.listServers())
        if (cfg.secretRef != null) cfg.secretRef!,
    };
    final secrets = <Secret>[];
    // Shared credentials must be read exactly once with the old key. Read all
    // of them before writing so an unreadable credential cannot leave earlier
    // entries encrypted with a key that has not been installed yet.
    for (final ref in secretRefs) {
      final secret = await vault.getSecret(ref);
      if (secret != null) secrets.add(secret);
    }
    final previousVault = vault;
    final newVault = SecretVault(vault.store, newKey);
    // One write, not one per credential. The vault file is rewritten whole on
    // every entry, so a loop left it holding a mix of both keys when a write
    // partway through failed — and the key the rest were sealed with is not
    // installed until below, so a restart could not open them again.
    await newVault.putSecrets(secrets);
    try {
      // The keystore is the only place the new key survives a restart, and it
      // can refuse outright — a locked keyring throws here, which is why the
      // rest of this class treats it as a state to recover from rather than a
      // crash. Until it holds the new key, the file that is now sealed with
      // that key is unreadable by the next launch, so a refused install has
      // to put the file back rather than leave the two disagreeing.
      await masterKeys.setKeystoreKey(newKey);
    } catch (_) {
      try {
        await previousVault.putSecrets(secrets);
      } catch (error, stackTrace) {
        // Only the keystore error reaches the caller, and on its own it reads
        // as an ordinary locked keyring rather than the one state where the
        // vault is left disagreeing with the keystore. Log the write that was
        // supposed to prevent that, or a field report cannot explain it.
        developer.log(
          'Vault re-key rollback failed; the vault file stays sealed with a '
          'key the OS keystore does not hold',
          name: 'seance.app',
          level: 1000,
          error: error,
          stackTrace: stackTrace,
        );
        // Both writes failed, so the file keeps a key the keystore does not
        // hold. Stay on that key here: the credentials remain readable for
        // this session, and a retried enrolment re-attempts the install from
        // a vault whose file and in-memory key still agree.
        vault = newVault;
        vaultKey = newKey;
      }
      rethrow;
    }
    vault = newVault;
    vaultKey = newKey;
  }

  Future<({List<int> authVerifier, List<int> vaultKey})> _deriveSyncKeys({
    required String password,
    required String encryptionPassphrase,
    required List<int> salt,
    required Argon2Params params,
  }) async {
    final authKeys = await VaultCrypto.deriveKeys(
      passphrase: password,
      salt: salt,
      params: params,
    );
    // Existing accounts used one passphrase for both purposes. Reusing that
    // derivation preserves their keys and avoids a second expensive KDF run.
    if (password == encryptionPassphrase) {
      return (authVerifier: authKeys.authVerifier, vaultKey: authKeys.vaultKey);
    }
    final encryptionKeys = await VaultCrypto.deriveKeys(
      passphrase: encryptionPassphrase,
      salt: salt,
      params: params,
    );
    return (
      authVerifier: authKeys.authVerifier,
      vaultKey: encryptionKeys.vaultKey,
    );
  }

  /// Create a sync account and adopt its separately protected vault key.
  Future<void> registerSync({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async {
    final salt = secureRandomBytes(16);
    final keys = await _deriveSyncKeys(
      password: password,
      encryptionPassphrase: encryptionPassphrase,
      salt: salt,
      params: const Argon2Params(),
    );
    await _withSyncClient(baseUrl, (client) async {
      await client.register(
        RegisterRequest(
          username: username,
          authVerifier: base64.encode(keys.authVerifier),
          argonSalt: base64.encode(salt),
          argonParams: const Argon2Params(),
        ),
      );
      settings.syncBaseUrl = baseUrl;
      settings.syncUsername = username;
      await saveSettings();
      await masterKeys.putApiKey(syncTokenKeyName, client.token!);
      await _rekeyVault(keys.vaultKey);
    });
  }

  /// Enrol this device against an existing account and adopt its vault key.
  Future<void> loginSync({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) => _withSyncClient(baseUrl, (client) async {
    final pre = await client.prelogin(username);
    // Refuse a KDF downgrade: the Argon2 parameters come from the server, so a
    // malicious/compromised one could return weak factors to make the vault key
    // cheap to brute-force. Never derive with anything weaker than the minimum.
    if (!pre.argonParams.meetsMinimum(Argon2Params.minimum)) {
      throw StateError(
        'The sync server returned weaker password-hashing parameters than '
        'Séance accepts — refusing to derive your key (possible downgrade '
        'attack).',
      );
    }
    final keys = await _deriveSyncKeys(
      password: password,
      encryptionPassphrase: encryptionPassphrase,
      salt: base64.decode(pre.argonSalt),
      params: pre.argonParams,
    );
    await client.login(
      LoginRequest(
        username: username,
        authVerifier: base64.encode(keys.authVerifier),
      ),
    );
    // Authentication cannot prove that the separate encryption passphrase is
    // correct. Verify it against one remote payload before changing the local
    // vault or persisting enrollment, so a typo cannot overwrite synced data.
    final remote = await client.pull(since: 0);
    for (final record in remote.records) {
      if (record.deleted || record.blob.isEmpty) continue;
      try {
        await RecordCodec(keys.vaultKey).decrypt(record);
      } catch (_) {
        throw StateError(
          'The vault encryption passphrase could not decrypt this account. '
          'Check it and try again.',
        );
      }
      break;
    }
    settings.syncBaseUrl = baseUrl;
    settings.syncUsername = username;
    await saveSettings();
    await masterKeys.putApiKey(syncTokenKeyName, client.token!);
    await _rekeyVault(keys.vaultKey);
  });

  /// Run one synchronization round against the configured server.
  Future<SyncOutcome> runSync() async {
    // First statement, above every guard. The guards below all throw today,
    // so nothing can read a stale answer — but placing the reset after them
    // means that stays true only while they keep throwing, and a guard that
    // is one day changed to return a failure outcome would hand the caller
    // the previous round's "adopted" answer with nothing to show for it.
    _assistantSettingsChanged = false;
    final baseUrl = settings.syncBaseUrl;
    final token = await masterKeys.getApiKey(syncTokenKeyName);
    if (baseUrl == null || token == null) {
      // A configured account that suddenly reads as "not set up" means the
      // keystore (which holds the token) is down — say that, not "set up sync".
      if (baseUrl != null &&
          masterKeys.keystoreStatus == KeystoreStatus.unavailable) {
        throw StateError(
          'Sync is configured, but the OS keyring is locked or unavailable '
          '(${masterKeys.lastKeystoreError ?? 'no details'}) — the sync token '
          'and the vault key live there. Unlock the keyring and sync again.',
        );
      }
      throw StateError('Sync is not set up');
    }
    // The keystore answered for the token; the vault key may still be missing
    // if the keystore was down at bootstrap — retry it now.
    if (vaultKey == null) await unlockVaultFromKeystore();
    final key = vaultKey;
    if (key == null) {
      throw StateError(
        'The vault is locked: the OS keyring is unavailable '
        '(${masterKeys.lastKeystoreError ?? 'no details'}). Unlock the keyring '
        'and sync again.',
      );
    }
    // Null unless opted in, which is what makes the assistant record neither
    // pushed nor applied on a device that has not asked for it.
    final assistant = settings.syncAssistant
        ? AssistantSettingsSync(
            settings: settings,
            masterKeys: masterKeys,
            saveSettings: saveSettings,
          )
        : null;
    final coordinator = SyncCoordinator(
      configStore: configStore,
      hostKeyStore: hostKeyStore,
      snippetStore: snippetStore,
      assistantStore: assistant,
      codec: RecordCodec(key),
      local: InMemoryLocalRecordStore(),
      deviceId: settings.deviceId,
      syncSecrets: settings.syncSecrets,
      secretVault: settings.syncSecrets ? vault : null,
      tombstoneStore: tombstoneStore,
    );
    try {
      return await _withSyncClient(baseUrl, (client) {
        client.token = token;
        return coordinator.run(client);
      });
    } finally {
      // In a `finally`, because a round can apply the assistant record and
      // *then* fail — the pull happens first, and a push after it can still
      // throw. Assigned only on success, that adoption was invisible: the
      // failed round skipped `reloadLlmProvider`, and the next successful
      // round found the settings already adopted, so the fingerprint matched,
      // `applied` was false again, and the chat provider kept answering with
      // the old model and key until some unrelated edit happened to rebuild
      // it.
      _assistantSettingsChanged = assistant?.applied ?? false;
    }
  }

  /// Keep connections alive through response/persistence work, including errors.
  Future<T> _withSyncClient<T>(
    String baseUrl,
    Future<T> Function(HttpSyncClient client) action,
  ) async {
    final client = HttpSyncClient(baseUrl: baseUrl);
    try {
      return await action(client);
    } finally {
      client.close();
    }
  }

  /// Resolve connection credentials for [config] from the vault / on-disk key.
  ///
  /// The `draft…` arguments are the server editor's own fields, for testing a
  /// connection before saving. Material typed into the form is not in the
  /// vault yet, so resolving from storage alone would quietly test the *old*
  /// credential — or an empty one for a server being added. A blank draft
  /// field falls back to the vault, which is how an unchanged credential is
  /// re-tested, and matches what saving does with a blank field — with one
  /// exception the blanket claim was hiding: a typed draft PEM is new key
  /// material by construction (the editor passes null whenever the key is
  /// referenced from disk or held in the vault), so a blank passphrase beside
  /// one means "no passphrase" rather than "the stored one".
  ///
  /// Precedence, since it is not obvious from the branches: a configured
  /// [ServerConfig.identityFilePath] wins over [draftPrivateKey]. The editor
  /// cannot produce both — it sets the path only while the key is referenced
  /// from disk, and passes the draft PEM as null in exactly that case — so
  /// the order is unreachable from there today, and a caller that populates
  /// both is asking to test the file.
  ///
  /// [draftIdentityBookmark] plays the same role for a Browse…-picked identity
  /// file: its macOS security-scoped grant is keyed by server id and is not
  /// written to settings until save, so without it a key outside `~/.ssh`
  /// would fall back to the raw path and fail with EPERM.
  ///
  /// A *newly picked* identity file is not carved out the way a typed PEM is,
  /// and the asymmetry is deliberate. Save keeps the stored passphrase when
  /// the box is blank (the editor writes no secret in referenced-key mode
  /// without one), so falling back to it here is what makes the test faithful
  /// to the save — the property this whole method is built on. Treating the
  /// pick as new key material instead would need a way to tell "a different
  /// key" from "the same key re-picked", and the only signal available is the
  /// bookmark: a macOS-only blob that is re-minted per grant, so it differs
  /// for the same file and is null everywhere else. That would drop a correct
  /// stored passphrase on every re-pick on one platform and never fire on the
  /// others. The cost is that rotating to an unprotected key cannot be
  /// expressed — the box is already blank — so the test reports a decrypt
  /// failure for a configuration that is correct, and saving would store the
  /// same stale passphrase. `docs/STATUS.md` follow-up 16 tracks the explicit
  /// "no passphrase" affordance that closes it in both places at once.
  Future<SshCredentials> resolveCredentials(
    ServerConfig config, {
    String? draftPassword,
    String? draftPrivateKey,
    String? draftKeyPassphrase,
    IdentityFileBookmark? draftIdentityBookmark,
  }) async {
    String? draft(String? value) =>
        (value == null || value.isEmpty) ? null : value;
    // A cross-file contract with the editor, which builds the grant from the
    // path it is about (`_bookmarkFor` returns null without one). Without the
    // path this branch never runs, so a bookmark passed alone would be
    // silently dropped and the test would resolve the vault credential
    // instead — a green result for a key nobody asked it to try.
    // A throw, not an assert: stripped from the build users run, the only
    // symptom of a caller getting this wrong is a green "authenticated" for a
    // credential nobody asked to test — the same reason the exclusion guard in
    // `ServerConfig.copyWith` throws.
    // Only under key auth: for a password or the agent the bookmark is never
    // consulted, so a stale one left over from an auth-method switch cannot
    // change what is tested, and throwing would turn a harmless leftover
    // into a failed test. A typed PEM is the same case under key auth: it is
    // returned before anything consults a path or a grant.
    if (config.authMethod == AuthMethod.privateKey &&
        config.identityFilePath == null &&
        draft(draftPrivateKey) == null &&
        draftIdentityBookmark != null) {
      throw ArgumentError.value(
        draftIdentityBookmark,
        'draftIdentityBookmark',
        'only honoured alongside identityFilePath: without the path the '
            'grant is dropped and the vault credential is tested instead',
      );
    }
    // Lazily re-probe a keystore that was down at bootstrap, so a keyring that
    // came back (or just got unlocked) unlocks secrets without an app restart.
    if (config.secretRef != null && vaultKey == null) {
      await unlockVaultFromKeystore();
    }
    switch (config.authMethod) {
      case AuthMethod.agent:
        return const SshCredentials.agent();
      case AuthMethod.password:
        final typed = draft(draftPassword);
        if (typed != null) return SshCredentials.password(typed);
        final secret = config.secretRef == null
            ? null
            : await vault.getSecret(config.secretRef!);
        return SshCredentials.password(secret?.value ?? '');
      case AuthMethod.privateKey:
        // "Reference, don't store": read the key from disk at connect time.
        if (config.identityFilePath != null) {
          final pem = await _readIdentityFile(
            config,
            bookmarkOverride: draftIdentityBookmark,
          );
          return SshCredentials.privateKey(
            pem,
            // Behind the `??`, so a typed passphrase skips the read that was
            // about to be discarded. Only a read: the vault is `vault.json`
            // (`FileVaultStore`), and the keyring holds the vault key alone —
            // already resolved by the time this runs — so there is no unlock
            // prompt or keychain failure to avoid here, and no behaviour
            // difference to test. Free, and one less thing happening.
            keyPassphrase: draft(draftKeyPassphrase) ??
                (config.secretRef == null
                    ? null
                    : (await vault.getSecret(config.secretRef!))
                        ?.keyPassphrase),
          );
        }
        final typedPem = draft(draftPrivateKey);
        if (typedPem != null) {
          return SshCredentials.privateKey(
            typedPem,
            keyPassphrase: draft(draftKeyPassphrase),
          );
        }
        final secret = config.secretRef == null
            ? null
            : await vault.getSecret(config.secretRef!);
        return SshCredentials.privateKey(
          secret?.value ?? '',
          keyPassphrase: draft(draftKeyPassphrase) ?? secret?.keyPassphrase,
        );
    }
  }

  /// Read a "reference, don't store" identity file for [config], through the
  /// server's security-scoped bookmark when one exists (a Browse…-picked key
  /// outside ~/.ssh is only readable inside that grant), falling back to the
  /// plain expanded path. Every attempt lands in the audit log; audit failures
  /// never block connecting.
  Future<String> _readIdentityFile(
    ServerConfig config, {
    IdentityFileBookmark? bookmarkOverride,
  }) async {
    // Dart's File does not expand `~`, but the editor hint invites it.
    var readPath = _expandHome(config.identityFilePath!);
    ResolvedIdentityFile? scoped;
    final saved = settings.identityFileBookmarks[config.id];
    final entry = bookmarkOverride ?? saved;
    // The grant counts only while it was minted for the configured path: a
    // synced edit (say, a key rotation on another device) changes the path
    // without touching this device's bookmark map, and the new path must win
    // over the stale grant to the old file.
    if (entry != null && entry.path == config.identityFilePath) {
      scoped = await identityBookmarks.resolveAndStart(entry.bookmark);
      if (scoped != null) {
        readPath = scoped.path;
        // Only a grant that came *from* settings is refreshed back into
        // them. A draft override of a *newly picked* file is not persisted —
        // that would file a grant under a server that may never exist — but
        // an override that is simply the saved grant passed back in (which is
        // what the editor does for a server it did not re-Browse) may refresh
        // in place, or a stale bookmark would be re-minted on every attempt
        // and never kept.
        //
        // Compared with `==`, which `IdentityFileBookmark` overrides over the
        // path and the bookmark payload, so a grant reconstructed with the
        // same contents still counts — the editor is not obliged to hand back
        // the identical instance. Read once, above, rather than looked up
        // again here.
        final refreshable =
            bookmarkOverride == null || bookmarkOverride == saved;
        if (scoped.refreshedBookmark != null && refreshable) {
          // The stored bookmark went stale (key moved/replaced); persist the
          // re-minted one so the grant keeps surviving relaunches.
          settings.identityFileBookmarks[config.id] = IdentityFileBookmark(
            path: entry.path,
            bookmark: scoped.refreshedBookmark!,
          );
          try {
            await saveSettings();
          } catch (_) {
            // Best-effort: the connect must not fail (nor the live grant go
            // unbalanced) over a settings write; the stale bookmark still
            // resolves on the next attempt.
          }
        }
      }
    }
    try {
      final pem = await File(readPath).readAsString();
      await _auditIdentityRead(config, readPath,
          viaBookmark: scoped != null, ok: true);
      return pem;
    } on FileSystemException catch (e, stackTrace) {
      await _auditIdentityRead(config, readPath,
          viaBookmark: scoped != null, ok: false, error: e.toString());
      // Keep the original I/O stack visible to crash reports/logs.
      Error.throwWithStackTrace(IdentityFileException(readPath, e), stackTrace);
    } finally {
      if (scoped != null) await identityBookmarks.stopAccess(scoped.token);
    }
  }

  Future<void> _auditIdentityRead(
    ServerConfig config,
    String path, {
    required bool viaBookmark,
    required bool ok,
    String? error,
  }) async {
    try {
      await identityAudit.record(IdentityReadEvent(
        at: DateTime.now().toUtc().toIso8601String(),
        serverId: config.id,
        serverLabel: config.label,
        path: path,
        viaBookmark: viaBookmark,
        ok: ok,
        error: error,
      ));
    } catch (_) {
      // The audit trail is best-effort; a full disk must not break connecting.
    }
  }

  /// Expand a leading `~` to the user's home directory (Dart's [File] treats it
  /// as a literal path segment, so an identity path like `~/.ssh/id_ed25519`
  /// would otherwise never be found). [expandHomePath] also undoes the macOS
  /// sandbox's container `$HOME`, so `~` means the real home directory.
  static String _expandHome(String path) => expandHomePath(
        path,
        environment: Platform.environment,
        isMacOS: Platform.isMacOS,
      );

  /// Build the configured LLM provider, resolving its API key from the keystore.
  Future<LlmProvider> buildLlmProvider() async {
    final apiKey = settings.llmApiKeyRef.isEmpty
        ? ''
        : (await masterKeys.getApiKey(settings.llmApiKeyRef) ?? '');
    switch (settings.llmKind) {
      case LlmProviderKind.anthropic:
        return AnthropicProvider(
          apiKey: apiKey,
          model: settings.llmModel,
          baseUrl: settings.llmBaseUrl,
        );
      case LlmProviderKind.openaiCompatible:
        return OpenAiCompatibleProvider(
          baseUrl: settings.llmBaseUrl,
          apiKey: apiKey,
          model: settings.llmModel,
        );
    }
  }

  /// A backend the user configured that this launch could not build.
  ///
  /// `CompositeSearch` logs a backend that fails mid-search "because this is
  /// the only record it happened"; one dropped before the search starts leaves
  /// exactly the same symptom — quietly worse results — and deserves the same
  /// record. Never the key or the ref, only which backend and why.
  static void _searchBackendUnavailable(String backend) {
    developer.log(
      '$backend search key unavailable (locked keyring or missing entry); '
      'backend skipped for this session',
      name: searchLoggerName,
      // Warning, like `CompositeSearch`'s record of a backend failing
      // mid-search: the two are halves of one signal, and a filter at
      // warning level should see both. Through the shared constant, which is
      // public so the halves cannot drift — restating the number here was the
      // drift it exists to prevent.
      level: searchWarningLogLevel,
    );
  }

  /// The chat tool's web search: every configured backend, merged.
  ///
  /// Configured means used, rather than a priority order that would quietly
  /// ignore a backend someone took the trouble to set up. Clearing a field is
  /// how you drop one; filling several is how you use them all (see
  /// [CompositeSearch]). Null when nothing is configured, which
  /// is what hides the search tool from the assistant.
  Future<SearchProvider?> buildSearchProvider() async {
    final backends = <SearchProvider>[];
    // Trimmed, like the key refs below it: a URL that is only whitespace has
    // nothing to resolve against — it would build a `SearxngSearch` whose
    // every request fails, and the only sign would be the mid-search failure
    // log. The settings screen already writes trimmed-or-null; a hand-edited
    // or synced `settings.json` need not.
    final searxngUrl = settings.searxngUrl?.trim() ?? '';
    if (searxngUrl.isNotEmpty) {
      backends.add(SearxngSearch(baseUrl: searxngUrl));
    }
    // Trimmed for the reason the URL above is: these arrive from a
    // hand-edited `settings.json` or over sync, and a padded name addresses no
    // keystore entry. Untrimmed, it passes the emptiness check, misses its
    // lookup, and is reported as a locked keyring — sending the user to debug
    // a keystore that is working.
    final braveRef = settings.braveApiKeyRef?.trim() ?? '';
    if (braveRef.isNotEmpty) {
      // getApiKey answers null on a locked keyring rather than throwing, so a
      // keystore that is down reads as "this backend is not available" and the
      // others still work.
      final key = await masterKeys.getApiKey(braveRef);
      if (key != null) {
        backends.add(BraveSearch(apiKey: key));
      } else {
        _searchBackendUnavailable('Brave');
      }
    }
    final zaiRef = settings.zaiApiKeyRef?.trim() ?? '';
    if (zaiRef.isNotEmpty) {
      final key = await masterKeys.getApiKey(zaiRef);
      if (key != null) {
        backends.add(ZaiSearch(apiKey: key));
      } else {
        _searchBackendUnavailable('Z.AI');
      }
    }
    if (backends.isEmpty) return null;
    return backends.length == 1 ? backends.single : CompositeSearch(backends);
  }

  /// A caller-owned sync client, or null if sync isn't set up. Close after use.
  HttpSyncClient? buildSyncClient() {
    final url = settings.syncBaseUrl;
    if (url == null || url.isEmpty) return null;
    return HttpSyncClient(baseUrl: url);
  }
}
