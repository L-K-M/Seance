import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:seance_core/seance_core.dart';

import 'app_settings.dart';
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
}

/// Wires together the seance_core services with the app's file-backed stores
/// and the OS keystore. Created once at startup.
class AppServices {
  final ConfigStore configStore;
  final SnippetStore snippetStore;
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

  AppServices._({
    required this.configStore,
    required this.snippetStore,
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

  static Future<AppServices> initialize() async {
    final dir = await getApplicationSupportDirectory();
    String p(String name) => '${dir.path}/$name';

    final masterKeys = MasterKeyManager();
    // May be null when the OS keystore is locked or unavailable (locked login
    // keyring on auto-login systems, no Secret Service daemon on minimal
    // desktops): the app then starts with a locked vault — secrets unreadable
    // and unwritable with a clear error, retry offered in the UI — instead of
    // crashing before the shell exists.
    final vaultKey = await masterKeys.probeKeystore();

    final configStore = FileConfigStore(File(p('servers.json')));
    final snippetStore = FileSnippetStore(File(p('snippets.json')));
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
    final newVault = SecretVault(vault.store, newKey);
    for (final cfg in await configStore.listServers()) {
      if (cfg.secretRef != null) {
        final secret = await vault.getSecret(cfg.secretRef!);
        if (secret != null) await newVault.putSecret(secret);
      }
    }
    vault = newVault;
    vaultKey = newKey;
    await masterKeys.setKeystoreKey(newKey);
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
      await masterKeys.putApiKey('sync.token', client.token!);
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
    await masterKeys.putApiKey('sync.token', client.token!);
    await _rekeyVault(keys.vaultKey);
  });

  /// Run one synchronization round against the configured server.
  Future<SyncOutcome> runSync() async {
    final baseUrl = settings.syncBaseUrl;
    final token = await masterKeys.getApiKey('sync.token');
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
    final coordinator = SyncCoordinator(
      configStore: configStore,
      hostKeyStore: hostKeyStore,
      snippetStore: snippetStore,
      codec: RecordCodec(key),
      local: InMemoryLocalRecordStore(),
      deviceId: settings.deviceId,
      syncSecrets: settings.syncSecrets,
      secretVault: settings.syncSecrets ? vault : null,
    );
    return _withSyncClient(baseUrl, (client) {
      client.token = token;
      return coordinator.run(client);
    });
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
  /// re-tested, and matches what saving does with a blank field.
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
    if (config.identityFilePath == null && draftIdentityBookmark != null) {
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
          final storedPass = config.secretRef == null
              ? null
              : (await vault.getSecret(config.secretRef!))?.keyPassphrase;
          return SshCredentials.privateKey(
            pem,
            keyPassphrase: draft(draftKeyPassphrase) ?? storedPass,
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
    final entry =
        bookmarkOverride ?? settings.identityFileBookmarks[config.id];
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
        final refreshable = bookmarkOverride == null ||
            bookmarkOverride == settings.identityFileBookmarks[config.id];
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

  /// Build the web-search backend for the chat tool, if one is configured.
  Future<SearchProvider?> buildSearchProvider() async {
    if (settings.searxngUrl != null && settings.searxngUrl!.isNotEmpty) {
      return SearxngSearch(baseUrl: settings.searxngUrl!);
    }
    if (settings.braveApiKeyRef != null &&
        settings.braveApiKeyRef!.isNotEmpty) {
      final key = await masterKeys.getApiKey(settings.braveApiKeyRef!);
      if (key != null) return BraveSearch(apiKey: key);
    }
    return null;
  }

  /// A caller-owned sync client, or null if sync isn't set up. Close after use.
  HttpSyncClient? buildSyncClient() {
    final url = settings.syncBaseUrl;
    if (url == null || url.isEmpty) return null;
    return HttpSyncClient(baseUrl: url);
  }
}
