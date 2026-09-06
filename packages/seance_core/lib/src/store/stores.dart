import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';

import '../hostkey/tofu.dart';

/// Persists non-secret server configuration. Backed by SQLite in the app.
abstract class ConfigStore {
  Future<List<ServerConfig>> listServers();
  Future<ServerConfig?> getServer(String id);
  Future<void> putServer(ServerConfig config);
  Future<void> deleteServer(String id);
}

/// Persists reusable command snippets (non-secret). Synced across devices.
abstract class SnippetStore {
  Future<List<Snippet>> listSnippets();
  Future<Snippet?> getSnippet(String id);
  Future<void> putSnippet(Snippet snippet);
  Future<void> deleteSnippet(String id);
}

/// Holds the assistant's configuration as a single synced value.
///
/// Read/write rather than list/delete: there is exactly one of these, and the
/// app keeps it inside its own settings file rather than in a store of its
/// own. The interface exists so [SyncCoordinator] can reach it without knowing
/// that, and so the sync path is testable without an app.
///
/// [getAssistantSettings] returns null only while this device has nothing to
/// publish — which is what keeps two freshly-installed devices from pushing
/// rival defaults at each other before either has configured anything. It is
/// not how a configuration is withdrawn: clearing one is an edit like any
/// other, so it still returns a record, with the fields the user cleared
/// cleared and a fresh `updatedAt`. Returning null for that would read as
/// "nothing to publish", and the next pull would re-apply the configuration
/// this device just removed.
///
/// The provider name is not one of the fields a clear can empty — it is
/// written from an enum, which always has a value — and the apply path in
/// `SyncCoordinator` relies on that: a record with an empty one is a payload
/// this build could not read, not a configuration, and is skipped rather than
/// adopted over a working assistant.
///
/// What it returns is the *publishable* value: any keystore references it
/// holds are resolved to key material first, because it is this value's
/// `toJson()` that is sealed and pushed. An implementation that returned the
/// references alone would sync a configuration that looks set up everywhere
/// and answers nowhere.
abstract class AssistantSettingsStore {
  /// The publishable configuration, or null when there is nothing to publish.
  ///
  /// Null is reserved for "this device has never configured one" and for
  /// "the key material cannot be vouched for right now" — the coordinator
  /// treats both as a round to sit out, and the second is why a locked
  /// keyring must not publish a keyless copy over a keyed one.
  Future<AssistantSettings?> getAssistantSettings();

  /// When this device's stored configuration was last edited — and nothing
  /// else.
  ///
  /// Separate from [getAssistantSettings] because that one resolves key
  /// references into key material, which means reaching into the OS keystore
  /// and holding secrets in memory. The apply path needs only a timestamp, to
  /// avoid writing a pulled record over a local edit newer than anything the
  /// synced mirror has seen yet, and paying for key material to read a number
  /// would put secrets on a path that has no use for them.
  ///
  /// Zero while this device holds nothing — no local edit and nothing adopted
  /// from sync, since an adopted record keeps its own stamp — matching the
  /// stamp [getAssistantSettings] treats as "nothing to publish".
  Future<int> assistantSettingsUpdatedAt();

  /// Store a configuration: a local edit, or a record adopted from sync.
  ///
  /// Two contracts an implementer cannot infer from the signature. The record
  /// is stored *as given*, `updatedAt` included — dating it belongs to the
  /// caller, and re-stamping a pulled record here would corrupt the
  /// comparison the whole adopt/publish path is ordered by. And a record that
  /// arrived over the wire carries key *material* inline, which has to be
  /// moved into the OS keystore with only references kept: keys travel inside
  /// the sealed record and must not land in the file the settings persist to.
  ///
  /// An absent key means "look locally", never "forget the entry you have":
  /// a configuration that stops naming a key is not an instruction to delete
  /// it, and another configuration this record does not describe may still
  /// use it.
  ///
  /// Third contract, for the keystore write failing — a locked keyring, say.
  /// Keep the configuration and its stamp and retry the key on a later round:
  /// the record is delivered again every round, and throwing here would only
  /// abandon the rest of the round's records. What an implementation must not
  /// then do is publish the configuration back without that key, because the
  /// stamp it kept ties with the keyed record it came from and a tie is broken
  /// by device id — so the keyless copy can evict the keyed one. Remembering
  /// which names were dropped, durably enough to survive a restart, is what
  /// makes that distinguishable from a key that was simply never stored.
  Future<void> putAssistantSettings(AssistantSettings settings);
}

/// Persists opaque, already-encrypted secret blobs keyed by secret id. It never
/// sees plaintext — [SecretVault] seals before storing and opens after reading.
abstract class VaultStore {
  Future<void> putSecretBlob(String id, Uint8List blob);
  Future<Uint8List?> getSecretBlob(String id);
  Future<void> deleteSecret(String id);
}

/// The application-facing secret store. Wraps a [VaultStore] with the vault key
/// so callers work in terms of [Secret]s while only encrypted blobs are
/// persisted.
class SecretVault {
  final VaultStore store;
  final List<int> vaultKey;

  const SecretVault(this.store, this.vaultKey);

  Future<void> putSecret(Secret secret) async {
    final blob = await VaultCrypto.sealJson(vaultKey, secret.toJson());
    await store.putSecretBlob(secret.id, blob);
  }

  Future<Secret?> getSecret(String id) async {
    final blob = await store.getSecretBlob(id);
    if (blob == null) return null;
    final json = await VaultCrypto.openJson(vaultKey, blob);
    return Secret.fromJson(json);
  }

  Future<void> deleteSecret(String id) => store.deleteSecret(id);
}

class InMemoryConfigStore implements ConfigStore {
  final Map<String, ServerConfig> _servers = {};

  @override
  Future<List<ServerConfig>> listServers() async {
    final list = _servers.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return list;
  }

  @override
  Future<ServerConfig?> getServer(String id) async => _servers[id];

  @override
  Future<void> putServer(ServerConfig config) async =>
      _servers[config.id] = config;

  @override
  Future<void> deleteServer(String id) async => _servers.remove(id);
}

class InMemoryAssistantSettingsStore implements AssistantSettingsStore {
  AssistantSettings? settings;

  InMemoryAssistantSettingsStore([this.settings]);

  @override
  Future<AssistantSettings?> getAssistantSettings() async => settings;

  @override
  Future<int> assistantSettingsUpdatedAt() async => settings?.updatedAt ?? 0;

  @override
  Future<void> putAssistantSettings(AssistantSettings value) async =>
      settings = value;
}

class InMemorySnippetStore implements SnippetStore {
  final Map<String, Snippet> _snippets = {};

  @override
  Future<List<Snippet>> listSnippets() async {
    final list = _snippets.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return list;
  }

  @override
  Future<Snippet?> getSnippet(String id) async => _snippets[id];

  @override
  Future<void> putSnippet(Snippet snippet) async =>
      _snippets[snippet.id] = snippet;

  @override
  Future<void> deleteSnippet(String id) async => _snippets.remove(id);
}

class InMemoryVaultStore implements VaultStore {
  final Map<String, Uint8List> _blobs = {};

  @override
  Future<Uint8List?> getSecretBlob(String id) async => _blobs[id];

  @override
  Future<void> putSecretBlob(String id, Uint8List blob) async =>
      _blobs[id] = blob;

  @override
  Future<void> deleteSecret(String id) async => _blobs.remove(id);
}

class InMemoryHostKeyStore implements HostKeyStore {
  final Map<String, HostKey> _keys = {};

  @override
  Future<List<HostKey>> all() async => _keys.values.toList();

  @override
  Future<HostKey?> get(String host, int port) async => _keys['$host:$port'];

  @override
  Future<void> put(HostKey key) async => _keys[key.locator] = key;
}
