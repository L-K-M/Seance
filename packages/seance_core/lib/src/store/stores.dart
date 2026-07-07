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
