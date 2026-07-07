import 'package:seance_protocol/seance_protocol.dart';

import 'local_record_store.dart';

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
      final pushed = await _pushOnce(api);
      totalPulled += pulled;
      totalPushed += pushed.accepted;
      // Converged when nothing new arrived and nothing remains to push.
      if (pulled == 0 && (await store.dirtyRecords()).isEmpty) break;
      // Safety: if a push keeps getting rejected with no progress, stop.
      if (pulled == 0 && pushed.accepted == 0 && pushed.rejected == 0) break;
    }
    return SyncOutcome(
        pulled: totalPulled, pushed: totalPushed, rounds: round);
  }

  Future<int> _pullOnce(SyncApi api) async {
    final since = await store.highWaterSeq();
    final resp = await api.pull(since: since);
    var applied = 0;
    for (final remote in resp.records) {
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
    await store.setHighWaterSeq(resp.latestSeq);
    return applied;
  }

  Future<({int accepted, int rejected})> _pushOnce(SyncApi api) async {
    final dirty = await store.dirtyRecords();
    if (dirty.isEmpty) return (accepted: 0, rejected: 0);
    final resp = await api.push(dirty);
    var accepted = 0;
    var rejected = 0;
    for (final result in resp.results) {
      if (result.accepted) {
        await store.markSynced(result.id, result.seq);
        accepted++;
      } else {
        // Server held a newer version; stop treating ours as dirty and let the
        // next pull bring the winner down.
        await store.markSynced(result.id, result.seq);
        rejected++;
      }
    }
    await store.setHighWaterSeq(resp.latestSeq);
    return (accepted: accepted, rejected: rejected);
  }
}
