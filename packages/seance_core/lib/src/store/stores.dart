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
/// other, so it still returns a record, with the fields cleared and a fresh
/// `updatedAt`. Returning null for that would read as "nothing to publish",
/// and the next pull would re-apply the configuration this device just
/// removed.
abstract class AssistantSettingsStore {
  Future<AssistantSettings?> getAssistantSettings();
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
