import 'package:seance_protocol/seance_protocol.dart';

/// The client's local mirror of synced records plus its sync bookkeeping.
///
/// A record is "dirty" when it has a local change not yet accepted by the
/// server. [putLocal] marks a record dirty (a local edit); [putRemote] stores a
/// record pulled from the server without marking it dirty; [markSynced] clears
/// the dirty flag once the server has assigned a sequence number.
abstract class LocalRecordStore {
  Future<List<EncryptedRecord>> allRecords();
  Future<EncryptedRecord?> getRecord(String id);

  /// Store a locally-originated change and mark it for push.
  Future<void> putLocal(EncryptedRecord record);

  /// Store a server-originated record; not dirty.
  Future<void> putRemote(EncryptedRecord record);

  Future<List<EncryptedRecord>> dirtyRecords();
  Future<void> markSynced(String id, int seq);

  Future<int> highWaterSeq();
  Future<void> setHighWaterSeq(int seq);
}

/// In-memory implementation used by tests and as a reference; the Flutter app
/// backs the same interface with SQLite.
class InMemoryLocalRecordStore implements LocalRecordStore {
  final Map<String, EncryptedRecord> _records = {};
  final Set<String> _dirty = {};
  int _highWater = 0;

  @override
  Future<List<EncryptedRecord>> allRecords() async => _records.values.toList();

  @override
  Future<EncryptedRecord?> getRecord(String id) async => _records[id];

  @override
  Future<void> putLocal(EncryptedRecord record) async {
    _records[record.id] = record;
    _dirty.add(record.id);
  }

  @override
  Future<void> putRemote(EncryptedRecord record) async {
    _records[record.id] = record;
    _dirty.remove(record.id);
  }

  @override
  Future<List<EncryptedRecord>> dirtyRecords() async =>
      _dirty.map((id) => _records[id]!).toList();

  @override
  Future<void> markSynced(String id, int seq) async {
    final r = _records[id];
    if (r != null) _records[id] = r.withSeq(seq);
    _dirty.remove(id);
  }

  @override
  Future<int> highWaterSeq() async => _highWater;

  @override
  Future<void> setHighWaterSeq(int seq) async {
    if (seq > _highWater) _highWater = seq;
  }
}
