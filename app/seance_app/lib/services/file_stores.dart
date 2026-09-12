import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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

/// What settling a staged re-key did with the journal it found.
enum VaultRekeyOutcome {
  /// Nothing was staged; the stored vault was already the only generation.
  none,

  /// A staged generation matched the installed key and is now the vault.
  adopted,

  /// The installed key opened neither staged generation, so the journal was
  /// moved aside and the stored vault stands.
  discarded,
}

/// Crash recovery for a vault re-key, which has to change two stores that no
/// single operation spans: the vault file and the OS keystore. Between the two
/// writes one of them is wrong, and a process that dies there leaves a vault
/// sealed with a key nothing holds: unreadable, and not repairable by retrying
/// the enrolment, because that path starts by reading the very credentials
/// that no longer open.
///
/// [stageRekey] persists both generations before the keystore changes, so
/// whichever key the keystore ends up holding, [settleRekey] can still find
/// the matching one. Only a store that outlives the process needs this: an
/// in-memory vault dies with the keystore write that failed.
abstract interface class VaultRekeyJournal {
  /// Record both generations of the vault, the current one and the one sealed
  /// under [newKey], before the OS keystore is asked to adopt [newKey].
  Future<void> stageRekey({
    required List<int> currentKey,
    required List<int> newKey,
  });

  /// Resolve a staged re-key against [key], the one the OS keystore actually
  /// holds, and clear the journal. Always resolves: see [VaultRekeyOutcome].
  Future<VaultRekeyOutcome> settleRekey(List<int> key);
}

/// JSON-file [VaultStore] holding only opaque, already-encrypted blobs
/// (base64). [SecretVault] seals/opens; this just persists bytes.
class FileVaultStore implements VaultStore, VaultRekeyJournal {
  final File file;
  final Map<String, String> _blobs = {}; // id -> base64
  Future<void>? _loading;
  Future<void> _pending = Future<void>.value();
  Map<String, String>? _rekeySnapshots;

  FileVaultStore(this.file);

  File get _rekeyFile => File('${file.path}.rekey');

  static String _keyId(List<int> key) => sha256.convert(key).toString();

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) throw const FormatException('Expected a vault map.');
    return value.map((key, value) {
      if (key is! String || value is! String) {
        throw const FormatException('Invalid vault map entry.');
      }
      return MapEntry(key, value);
    });
  }

  /// Memoized, because the flag this replaced was only set after the reads:
  /// two first-time callers both ran the body, and the one that finished last
  /// repopulated the cache from the file as it was before the other's
  /// mutation committed — putting back an entry that mutation had deleted,
  /// for the next flush to persist.
  Future<void> _load() async {
    final pending = _loading;
    if (pending != null) return pending;
    final started = _read();
    _loading = started;
    try {
      await started;
    } catch (_) {
      // A load that failed outright is not cached: the next caller tries the
      // file again rather than inheriting the failure for the whole session.
      _loading = null;
      rethrow;
    }
  }

  Future<void> _read() async {
    _rekeySnapshots = await _readRekeyJournal();
    if (!await file.exists()) return;
    try {
      final map = jsonDecode(await file.readAsString()) as Map;
      map.forEach((k, v) => _blobs[k as String] = v as String);
    } catch (_) {
      _blobs.clear();
      await quarantineCorruptFile(file);
    }
  }

  Future<void> _flush() async {
    await writeStringAtomically(file, jsonEncode(_blobs));
  }

  /// The staged generations, or null when no re-key is pending.
  ///
  /// [stageRekey] never writes [file], so while a journal exists the stored
  /// vault still holds a complete generation. That is what makes a damaged
  /// journal safe to move aside instead of fatal: unlike the vault file it is
  /// never the only copy of anything, and a journal that could not be read and
  /// could not be cleared would fail every vault operation from here on.
  Future<Map<String, String>?> _readRekeyJournal() async {
    if (!await _rekeyFile.exists()) return null;
    try {
      final journal = jsonDecode(await _rekeyFile.readAsString());
      if (journal is! Map || journal['version'] != 1) {
        throw const FormatException('Invalid vault recovery journal.');
      }
      return _stringMap(journal['snapshots']);
    } catch (_) {
      await quarantineCorruptFile(_rekeyFile);
      return null;
    }
  }

  /// Run [body] with the cache loaded and no other operation in flight.
  ///
  /// Every public operation takes a slot, reads included. Serializing only the
  /// writes is not enough and [writeStringAtomically]'s own per-path queue is
  /// not enough either: that one orders the writes, while the snapshot, the
  /// mutation and the restore sit outside it, so two overlapping mutations
  /// could let one that failed restore a snapshot taken before the other
  /// committed. A read is in here for a related reason. Merely awaiting
  /// [_pending] before reading leaves it racing any mutation queued after that
  /// await, and which of the two reaches the cache first comes down to the two
  /// paths happening to take the same number of microtask hops — an invariant
  /// no future edit to this file could be expected to preserve, since nothing
  /// about it is visible at the point where it would break.
  Future<T> _serialize<T>(Future<T> Function() body) {
    final run = _pending.then((_) async {
      await _load();
      return body();
    });
    // The queue has to outlive a failed operation, so swallow the error here
    // and hand it to the caller through [run] alone.
    _pending = run.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return run;
  }

  /// Apply [change] to the cache and persist it, or leave both as they were.
  ///
  /// The whole map is rewritten on every mutation, so the file alone is
  /// already all-or-nothing — [writeStringAtomically] ends in a rename. The
  /// cache is not: mutating it before the flush means a failed write leaves it
  /// holding a value the caller was told was never stored, which the next
  /// successful write would then commit on its behalf. Restoring the snapshot
  /// keeps the two in step.
  Future<void> _mutate(void Function() change) => _serialize(() async {
        _requireNoRekey();
        final previous = Map<String, String>.from(_blobs);
        try {
          change();
          await _flush();
        } catch (_) {
          _blobs
            ..clear()
            ..addAll(previous);
          rethrow;
        }
      });

  @override
  Future<Uint8List?> getSecretBlob(String id) => _serialize(() async {
        // Connecting to a server resolves its credential while an auto-sync
        // round may be writing one, so a read outside the queue could report
        // a value the mutation's flush is about to roll back.
        //
        // A pending journal does not block this. The cache holds the stored
        // generation, which is the one the keystore still opens until the
        // re-key gets past its keystore write; past that, [settleRekey] has
        // swapped in the generation that matches. Refusing to read here would
        // only turn a recoverable state into a locked vault.
        final b64 = _blobs[id];
        return b64 == null ? null : base64.decode(b64);
      });

  @override
  Future<void> putSecretBlob(String id, Uint8List blob) =>
      _mutate(() => _blobs[id] = base64.encode(blob));

  @override
  Future<void> putSecretBlobs(Map<String, Uint8List> blobs) => _mutate(() {
        for (final entry in blobs.entries) {
          _blobs[entry.key] = base64.encode(entry.value);
        }
      });

  @override
  Future<void> deleteSecret(String id) => _mutate(() => _blobs.remove(id));

  /// A staged re-key owns the vault until it is settled: a mutation now would
  /// persist the stored generation, which [settleRekey] may then replace with
  /// the staged one, silently undoing the write. Startup settles before
  /// anything can call this, so the window is the one where the keystore is
  /// unavailable and the vault is locked regardless.
  void _requireNoRekey() {
    if (_rekeySnapshots != null) {
      throw StateError('Finish vault recovery before changing credentials.');
    }
  }

  /// Re-seal one stored blob under [newKey].
  ///
  /// An entry the current key cannot open is carried over byte for byte rather
  /// than failing the re-key. Such an entry is already unreadable (an orphan
  /// from an earlier interrupted re-key, say), so keeping it as it is loses
  /// nothing, while refusing would make enrolment impossible on exactly the
  /// vaults that most need this journal.
  Future<String> _reseal(
      String stored, List<int> currentKey, List<int> newKey) async {
    final Map<String, dynamic> plaintext;
    try {
      plaintext = await VaultCrypto.openJson(currentKey, base64.decode(stored));
    } catch (_) {
      return stored;
    }
    return base64.encode(await VaultCrypto.sealJson(newKey, plaintext));
  }

  /// Stage both complete generations before the OS keystore changes. Each
  /// snapshot is sealed under the key it belongs to, so the key that opens one
  /// is proof it is that key's generation, and an empty vault stages too.
  ///
  /// The sidecar is only ever written to a fresh path, never replaced in
  /// place: a second re-key while one is pending would drop the generations
  /// the first one is the only record of.
  @override
  Future<void> stageRekey({
    required List<int> currentKey,
    required List<int> newKey,
  }) => _serialize(() async {
    _requireNoRekey();
    if (await _rekeyFile.exists()) {
      throw StateError('A pending vault recovery must be completed first.');
    }
    final next = <String, String>{};
    for (final entry in _blobs.entries) {
      next[entry.key] = await _reseal(entry.value, currentKey, newKey);
    }
    final snapshots = <String, String>{
      // Preserve the raw map, orphan entries and version metadata included.
      _keyId(currentKey):
          base64.encode(await VaultCrypto.sealJson(currentKey, {'blobs': _blobs})),
      _keyId(newKey):
          base64.encode(await VaultCrypto.sealJson(newKey, {'blobs': next})),
    };
    await writeStringAtomically(_rekeyFile,
        jsonEncode({'version': 1, 'snapshots': snapshots}),
        privacy: AtomicFilePrivacy.ownerOnly);
    _rekeySnapshots = snapshots;
  });

  /// Adopt whichever staged generation [key] opens, then clear the journal.
  ///
  /// A journal this key matches neither half of is moved aside rather than
  /// kept. Neither generation is recoverable without a key that opens it, and
  /// a journal that stays is one that blocks every mutation forever, which is
  /// what a stray sidecar from a restored backup or a half-shipped build would
  /// otherwise do. The stored vault is untouched either way.
  @override
  Future<VaultRekeyOutcome> settleRekey(List<int> key) => _serialize(() async {
    final snapshots = _rekeySnapshots;
    if (snapshots == null) return VaultRekeyOutcome.none;
    final Map<String, String> blobs;
    try {
      final sealed = snapshots[_keyId(key)];
      if (sealed == null) throw const FormatException('No matching snapshot.');
      blobs = _stringMap(
          (await VaultCrypto.openJson(key, base64.decode(sealed)))['blobs']);
    } catch (_) {
      await quarantineCorruptFile(_rekeyFile);
      _rekeySnapshots = null;
      return VaultRekeyOutcome.discarded;
    }
    _blobs
      ..clear()
      ..addAll(blobs);
    // The cache is not restored if the flush fails: it now holds the
    // generation [key] opens, which is the one this session has to read with.
    // The journal stays on disk for the next launch to settle again, and lands
    // on the same generation because the installed key has not changed.
    await _flush();
    if (await _rekeyFile.exists()) await _rekeyFile.delete();
    _rekeySnapshots = null;
    return VaultRekeyOutcome.adopted;
  });
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
