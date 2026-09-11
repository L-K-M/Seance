import 'dart:convert';
import 'dart:developer' as developer;
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

/// JSON-file [TombstoneStore]: the deletions this device still owes the sync
/// server. Each entry is an [EncryptedRecord] tombstone (empty blob, no vault
/// key needed to mint), persisted so a delete survives an app restart before
/// the next sync pushes it. `SyncCoordinator` prunes an entry once the server
/// has taken it, so the file stays small.
///
/// Unlike the sealed record blobs, entries here are plaintext (record id,
/// deletion timestamp, deviceId) — the same class of metadata `servers.json`
/// already stores in the clear, and it also travels to the sync server as the
/// tombstone record. Server and snippet ids are random `uuidV4`s, so an id
/// reveals only that *something* was deleted and when, not what.
class FileTombstoneStore implements TombstoneStore {
  final File file;
  final Map<String, EncryptedRecord> _cache = {};
  bool _loaded = false;

  FileTombstoneStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final j in list) {
          final r = EncryptedRecord.fromJson((j as Map).cast<String, dynamic>());
          _cache[r.id] = r;
        }
      } catch (error, stackTrace) {
        // Unlike a corrupt config/snippet file (re-fetched on the next pull),
        // losing pending deletions silently means deleted items reappear with
        // nothing in the logs to say why — so this one failure gets a warning
        // before it is quarantined and the pending deletes are dropped.
        developer.log(
          'Could not read ${file.path}; pending deletion tombstones were '
          'dropped and deleted items may reappear on the next sync',
          name: 'seance.app',
          level: 900,
          error: error,
          stackTrace: stackTrace,
        );
        _cache.clear();
        await quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush() async {
    await writeStringAtomically(
        file, jsonEncode(_cache.values.map((r) => r.toJson()).toList()));
  }

  @override
  Future<List<EncryptedRecord>> all() async {
    await _load();
    return _cache.values.toList();
  }

  @override
  Future<void> add(EncryptedRecord tombstone) async {
    await _load();
    final existing = _cache[tombstone.id];
    // Monotonic (see [TombstoneStore]): a retry or double-delete after the row
    // is gone recomputes a bare-"now" stamp that can trail a pending
    // skew-beating tombstone; keeping the higher stamp stops a regression that
    // would lose last-write-wins and resurrect the row.
    if (existing != null && existing.updatedAt > tombstone.updatedAt) return;
    _cache[tombstone.id] = tombstone;
    await _flush();
  }

  @override
  Future<void> remove(String id) async {
    await _load();
    // Skip the rewrite when nothing was pending: saveServer/saveSnippet call
    // remove() on every save, so without this a delete-free install would
    // create and rewrite the file on each save.
    if (_cache.remove(id) == null) return;
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
