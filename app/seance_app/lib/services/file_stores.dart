import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';

import 'atomic_file.dart';

/// Simple JSON-file [ConfigStore]. For a single-user personal tool this is
/// plenty; the proposal's SQLite/drift backend is a drop-in future swap behind
/// the same interface. Secret material never lands here — only references.
class FileConfigStore implements ConfigStore {
  final File file;
  final Map<String, ServerConfig> _cache = {};
  bool _loaded = false;

  FileConfigStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final j in list) {
          final cfg = ServerConfig.fromJson((j as Map).cast<String, dynamic>());
          _cache[cfg.id] = cfg;
        }
      } catch (_) {
        // A corrupt file must not wedge startup: move it aside and start empty.
        _cache.clear();
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush() async {
    await writeStringAtomically(
        file, jsonEncode(_cache.values.map((c) => c.toJson()).toList()));
  }

  @override
  Future<List<ServerConfig>> listServers() async {
    await _load();
    final list = _cache.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return list;
  }

  @override
  Future<ServerConfig?> getServer(String id) async {
    await _load();
    return _cache[id];
  }

  @override
  Future<void> putServer(ServerConfig config) async {
    await _load();
    _cache[config.id] = config;
    await _flush();
  }

  @override
  Future<void> deleteServer(String id) async {
    await _load();
    _cache.remove(id);
    await _flush();
  }
}

/// Simple JSON-file [SnippetStore]. Non-secret; synced like server configs.
class FileSnippetStore implements SnippetStore {
  final File file;
  final Map<String, Snippet> _cache = {};
  bool _loaded = false;

  FileSnippetStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final j in list) {
          final s = Snippet.fromJson((j as Map).cast<String, dynamic>());
          _cache[s.id] = s;
        }
      } catch (_) {
        _cache.clear();
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush() async {
    await writeStringAtomically(
        file, jsonEncode(_cache.values.map((s) => s.toJson()).toList()));
  }

  @override
  Future<List<Snippet>> listSnippets() async {
    await _load();
    final list = _cache.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return list;
  }

  @override
  Future<Snippet?> getSnippet(String id) async {
    await _load();
    return _cache[id];
  }

  @override
  Future<void> putSnippet(Snippet snippet) async {
    await _load();
    _cache[snippet.id] = snippet;
    await _flush();
  }

  @override
  Future<void> deleteSnippet(String id) async {
    await _load();
    _cache.remove(id);
    await _flush();
  }
}

/// JSON-file [VaultStore] holding only opaque, already-encrypted blobs
/// (base64). [SecretVault] seals/opens; this just persists bytes.
class FileVaultStore implements VaultStore {
  final File file;
  final Map<String, String> _blobs = {}; // id -> base64
  bool _loaded = false;

  FileVaultStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        final map = jsonDecode(await file.readAsString()) as Map;
        map.forEach((k, v) => _blobs[k as String] = v as String);
      } catch (_) {
        _blobs.clear();
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush() async {
    await writeStringAtomically(file, jsonEncode(_blobs));
  }

  @override
  Future<Uint8List?> getSecretBlob(String id) async {
    await _load();
    final b64 = _blobs[id];
    return b64 == null ? null : base64.decode(b64);
  }

  @override
  Future<void> putSecretBlob(String id, Uint8List blob) async {
    await _load();
    _blobs[id] = base64.encode(blob);
    await _flush();
  }

  @override
  Future<void> deleteSecret(String id) async {
    await _load();
    _blobs.remove(id);
    await _flush();
  }
}

/// JSON-file [HostKeyStore] for pinned TOFU keys.
class FileHostKeyStore implements HostKeyStore {
  final File file;
  final Map<String, HostKey> _keys = {};
  bool _loaded = false;

  FileHostKeyStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final j in list) {
          final k = HostKey.fromJson((j as Map).cast<String, dynamic>());
          _keys[k.locator] = k;
        }
      } catch (_) {
        _keys.clear();
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush() async {
    await writeStringAtomically(
        file, jsonEncode(_keys.values.map((k) => k.toJson()).toList()));
  }

  @override
  Future<List<HostKey>> all() async {
    await _load();
    return _keys.values.toList();
  }

  @override
  Future<HostKey?> get(String host, int port) async {
    await _load();
    return _keys['$host:$port'];
  }

  @override
  Future<void> put(HostKey key) async {
    await _load();
    _keys[key.locator] = key;
    await _flush();
  }
}
