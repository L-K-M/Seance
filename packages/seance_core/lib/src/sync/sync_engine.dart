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

/// Drives synchronization between the local mirror and the server using the
/// last-write-wins rules in [Lww]. Because both sides apply the same rule, a
/// pull that loses is discarded and a push that loses is reconciled on the next
/// pull, so repeated runs converge.
class SyncEngine {
  final LocalRecordStore store;
  final int maxRounds;

  SyncEngine(this.store, {this.maxRounds = 5});

  Future<SyncOutcome> sync(SyncApi api) async {
    var totalPulled = 0;
    var totalPushed = 0;
    var round = 0;
    while (round < maxRounds) {
      round++;
      final pulled = await _pullOnce(api);
      final pushed = await _pushOnce(api, pulled.limits);
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
    return SyncOutcome(
        pulled: totalPulled, pushed: totalPushed, rounds: round);
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
  Future<({int accepted, int rejected})> _pushOnce(
    SyncApi api,
    PushLimits limits,
  ) async {
    final dirty = await store.dirtyRecords();
    if (dirty.isEmpty) return (accepted: 0, rejected: 0);
    var accepted = 0;
    var rejected = 0;
    for (final batch in batchForPush(dirty, limits)) {
      // A batch the server refuses whole (413, oversized body or blob) throws,
      // and that is deliberate: it is not the benign per-record rejection
      // below, which the next pull resolves. Nothing local can fix it, so
      // swallowing it would report a sync that succeeded while a record never
      // leaves the device — [SyncOutcome] carries no rejected count to say
      // otherwise. The batches already accepted stay marked synced.
      final resp = await api.push(batch);
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
