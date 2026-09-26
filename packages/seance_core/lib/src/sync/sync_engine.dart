import 'package:seance_protocol/seance_protocol.dart';

import 'local_record_store.dart';
import 'push_batcher.dart';

/// The authenticated record endpoints the engine needs. Implemented over HTTP
/// by [HttpSyncClient]; faked in tests.
abstract class SyncApi {
  Future<PullResponse> pull({required int since});
  Future<PushResponse> push(List<EncryptedRecord> records);
}

/// Outcome of a sync run, for the UI/telemetry.
class SyncOutcome {
  final int pulled;
  final int pushed;
  final int rounds;
  const SyncOutcome(
      {required this.pulled, required this.pushed, required this.rounds});
}

/// The server's error code for a push it refuses as too large to store.
const String _payloadTooLarge = 'payload_too_large';

/// One record the sync server refused to store because it is too large.
class RefusedRecord {
  final String id;

  /// What the record holds. [RecordKind.unknown] when only the sealed record
  /// was at hand, which is all the [SyncEngine] ever sees.
  final RecordKind kind;

  /// The name the user knows the record by (a snippet's title, a server's
  /// label), when the caller could tell.
  final String? name;

  const RefusedRecord(this.id, {this.kind = RecordKind.unknown, this.name});

  String get _described {
    final noun = switch (kind) {
      RecordKind.serverConfig => 'server',
      RecordKind.hostKey => 'host key',
      RecordKind.secret => 'credential',
      RecordKind.snippet => 'snippet',
      RecordKind.bookmark => 'bookmark',
      RecordKind.assistantSettings => 'assistant settings',
      RecordKind.unknown => 'record',
    };
    final named = name?.trim() ?? '';
    return named.isEmpty ? '$noun ($id)' : '$noun "$named"';
  }
}

/// A sync run finished, except for records the server refused as too large.
///
/// Such a record is pushed alone (see [batchForPush]), so the refusal is its
/// own and nothing else in the run has to pay for it: the run carries on and
/// this is thrown at the end, with [outcome] describing what did happen. Only
/// a refused push of that one record is put down to it: a refused batch of
/// several names no culprit, and it ends the run where it happens, as every
/// other failure does.
///
/// An [ApiError] with the server's own code, so a caller that handled the
/// refusal before it was isolated still recognises it.
class SyncRecordsRefused extends ApiError {
  /// Every record refused, each still waiting to be pushed: it stays dirty, so
  /// a later run retries it once it has shrunk or the limit has been raised.
  final List<RefusedRecord> records;

  /// What the run achieved around the refused records.
  final SyncOutcome outcome;

  SyncRecordsRefused(this.records, {required this.outcome})
      : assert(records.isNotEmpty),
        super(code: _payloadTooLarge, message: _describe(records));

  List<String> get recordIds => [for (final record in records) record.id];

  static String _describe(List<RefusedRecord> records) {
    const tail = 'Everything else synced.';
    if (records.length == 1) {
      final what = records.single._described;
      return '${what[0].toUpperCase()}${what.substring(1)} is too large for '
          'the sync server, so it stays on this device until you make it '
          'smaller. $tail';
    }
    return '${records.length} records are too large for the sync server, so '
        'they stay on this device until you make them smaller: '
        '${records.map((r) => r._described).join(', ')}. $tail';
  }

  /// The message alone: it is written for the person reading the sync status.
  @override
  String toString() => message;
}

/// Drives synchronization between the local mirror and the server using the
/// last-write-wins rules in [Lww]. Because both sides apply the same rule, a
/// pull that loses is discarded and a push that loses is reconciled on the next
/// pull, so repeated runs converge.
class SyncEngine {
  final LocalRecordStore store;
  final int maxRounds;

  SyncEngine(this.store, {this.maxRounds = 5});

  /// Throws [SyncRecordsRefused] once the run is otherwise complete if the
  /// server refused any record as too large; any other failure is thrown where
  /// it happens.
  Future<SyncOutcome> sync(SyncApi api) async {
    var totalPulled = 0;
    var totalPushed = 0;
    var round = 0;
    // Ids the server refused as too large during this run. Each is sent once
    // per run, not once per round: nothing between rounds can shrink it, and
    // re-sending a record past the cap every round would upload it up to
    // [maxRounds] times only to be refused each time. Per run rather than on
    // the engine for the reason the limits are (see [_pullOnce]).
    final refused = <String>{};
    while (round < maxRounds) {
      round++;
      final pulled = await _pullOnce(api);
      final pushed = await _pushOnce(api, pulled.limits, refused);
      totalPulled += pulled.applied;
      totalPushed += pushed.accepted;
      // Converged when nothing new arrived and nothing remains to push.
      if (pulled.applied == 0 && (await store.dirtyRecords()).isEmpty) break;
      // Safety: if a push keeps getting rejected with no progress, stop.
      if (pulled.applied == 0 &&
          pushed.accepted == 0 &&
          pushed.rejected == 0) {
        break;
      }
    }
    final outcome = SyncOutcome(
        pulled: totalPulled, pushed: totalPushed, rounds: round);
    if (refused.isEmpty) return outcome;
    // A later round may have adopted another device's winning copy of a
    // refused record, which settles it; only the ones still owed are news.
    final owed = {for (final record in await store.dirtyRecords()) record.id};
    final stillRefused = [
      for (final id in refused)
        if (owed.contains(id)) RefusedRecord(id),
    ];
    if (stillRefused.isEmpty) return outcome;
    throw SyncRecordsRefused(stillRefused, outcome: outcome);
  }

  /// Applies a pull and reports how this round's push may be sized.
  ///
  /// The limits ride along rather than living on the engine: [sync] takes the
  /// endpoint per call, so they belong to one run against one server. As a
  /// field they would outlive the server that advertised them and, with two
  /// runs overlapping, could size one run's push against the other's server.
  /// A pull carrying no advertisement yields the shipped defaults, which is
  /// what such a server enforces by definition.
  Future<({int applied, PushLimits limits})> _pullOnce(SyncApi api) async {
    final since = await store.highWaterSeq();
    final resp = await api.pull(since: since);
    final limits = resp.limits ?? const PushLimits();
    var applied = 0;
    var snapshotHighWater = since;
    // Pulled records should carry server-assigned seqs; trust only observed seqs.
    for (final remote in resp.records) {
      final remoteSeq = remote.seq;
      if (remoteSeq != null && remoteSeq > snapshotHighWater) {
        snapshotHighWater = remoteSeq;
      }
      final local = await store.getRecord(remote.id);
      if (local == null) {
        await store.putRemote(remote);
        applied++;
        continue;
      }
      // Lww.resolve returns one of the two objects passed in, so identity tells
      // us which side won.
      final remoteWon = identical(Lww.resolve(local, remote), remote);
      if (remoteWon) {
        // Adopt the remote version and drop any losing local change.
        await store.putRemote(remote);
        applied++;
      }
      // Else the local copy is newer and stays dirty for the push phase.
    }
    await store.setHighWaterSeq(snapshotHighWater);
    return (applied: applied, limits: limits);
  }

  /// Pushes everything dirty, in as many requests as the server's limits
  /// require. One oversized request would be refused whole and the next round
  /// would rebuild it identically, so an unbatched push turns a large dirty set
  /// into a sync that never converges rather than one that is merely slow.
  ///
  /// Batches go out in sequence and each response is applied before the next
  /// request leaves, so a batch that fails costs the batches behind it, never
  /// the bookkeeping for the ones already accepted. The counts returned still
  /// cover the whole dirty set, which is what [sync]'s no-progress guard reads.
  ///
  /// Records in [refused] are skipped, and a record the server refuses as too
  /// large is added to it.
  Future<({int accepted, int rejected})> _pushOnce(
    SyncApi api,
    PushLimits limits,
    Set<String> refused,
  ) async {
    final dirty = [
      for (final record in await store.dirtyRecords())
        if (!refused.contains(record.id)) record,
    ];
    if (dirty.isEmpty) return (accepted: 0, rejected: 0);
    var accepted = 0;
    var rejected = 0;
    for (final batch in batchForPush(dirty, limits)) {
      // A batch the server refuses whole (413, oversized body or blob) is not
      // the benign per-record rejection below, which the next pull resolves:
      // nothing local can fix it, so it must not pass for a sync that
      // succeeded while a record never leaves the device. The batches already
      // accepted stay marked synced.
      //
      // A refused batch of one record is that record's own failure, though:
      // the batcher sends a record past a cap alone and last for exactly this.
      // So it is set aside and reported at the end of the run, and the pull
      // this run made still reaches its caller. Any other failure, including
      // a refused batch of several, ends the run here as it always has.
      final PushResponse resp;
      try {
        resp = await api.push(batch);
      } on ApiError catch (error) {
        if (error.code != _payloadTooLarge || batch.length != 1) rethrow;
        refused.add(batch.single.id);
        continue;
      }
      for (final result in resp.results) {
        if (result.accepted) {
          await store.markSynced(result.id, result.seq);
          accepted++;
        } else {
          // Keep the losing local version dirty until a pull adopts the server
          // winner; assigning the winner's seq here would mislabel our payload.
          rejected++;
        }
      }
    }
    return (accepted: accepted, rejected: rejected);
  }
}
