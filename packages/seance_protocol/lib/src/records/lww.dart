import 'record.dart';

/// Conflict resolution shared by client and server so both always agree on the
/// winner. Per-record last-write-wins keyed by `(updatedAt, deviceId)`:
///
///   * higher `updatedAt` wins;
///   * on an exact timestamp tie, the lexicographically larger `deviceId` wins
///     (an arbitrary but *deterministic* rule — both sides compute the same
///     result without coordination).
///
/// A delete (tombstone) is just another write and competes on the same
/// timestamp, so a later edit can legitimately resurrect a record and a later
/// delete beats an earlier edit.
class Lww {
  /// Returns whichever record should win. Records must share the same `id`.
  static EncryptedRecord resolve(EncryptedRecord a, EncryptedRecord b) {
    assert(a.id == b.id, 'Lww.resolve compares two versions of one record');
    if (a.updatedAt != b.updatedAt) {
      return a.updatedAt > b.updatedAt ? a : b;
    }
    final cmp = a.deviceId.compareTo(b.deviceId);
    if (cmp != 0) return cmp > 0 ? a : b;
    // Same timestamp and device: prefer whichever the server already sequenced.
    final aSeq = a.seq ?? -1;
    final bSeq = b.seq ?? -1;
    return aSeq >= bSeq ? a : b;
  }

  /// Merge two record sets keyed by id, resolving per-id conflicts. The result
  /// contains the winning version of every id present in either input.
  static Map<String, EncryptedRecord> merge(
    Iterable<EncryptedRecord> local,
    Iterable<EncryptedRecord> remote,
  ) {
    final out = <String, EncryptedRecord>{};
    for (final r in local) {
      out[r.id] = r;
    }
    for (final r in remote) {
      final existing = out[r.id];
      out[r.id] = existing == null ? r : resolve(existing, r);
    }
    return out;
  }
}
