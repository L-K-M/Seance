import 'dart:developer' as developer;

import 'package:seance_protocol/seance_protocol.dart';

import '../hostkey/tofu.dart';
import '../store/stores.dart';
import 'local_record_store.dart';
import 'sync_engine.dart';

const int _warningLogLevel = 900;
const String _recordKindDelimiter = ':';
const String _secretIdPrefix = 'secret$_recordKindDelimiter';
const String _syncLoggerName = 'seance.sync';

/// Bridges the app's domain objects (server configs, pinned host keys, and —
/// opt-in — secrets) to the encrypted record layer and back, then drives a
/// [SyncEngine] round. Records are keyed by their domain id and disambiguated
/// by [RecordKind], so applying pulled records routes each to the right store.
///
/// Strategy is deliberately simple for a few dozen rarely-edited records:
/// re-collect everything from local stores, let the engine push/pull, and
/// re-apply. Server-side LWW makes unchanged pushes no-ops, so this converges
/// without precise dirty-tracking.
class SyncCoordinator {
  final ConfigStore configStore;
  final HostKeyStore hostKeyStore;
  final RecordCodec codec;
  final LocalRecordStore local;
  final String deviceId;

  /// Optional snippet store. When present, snippets sync like server configs.
  final SnippetStore? snippetStore;

  /// Opt-in secret syncing. When true, [secretVault] and [secretIds] must be
  /// provided so secrets can be sealed into records.
  final bool syncSecrets;
  final SecretVault? secretVault;

  SyncCoordinator({
    required this.configStore,
    required this.hostKeyStore,
    required this.codec,
    required this.local,
    required this.deviceId,
    this.snippetStore,
    this.syncSecrets = false,
    this.secretVault,
  });

  /// Encode current local state into the record store (as local edits).
  Future<void> collectLocal() async {
    final servers = await configStore.listServers();

    // Host keys are keyed by `host:port`, not by server, so a pin is only
    // withheld when *every* server naming that address is excluded. One
    // included server on the same box is enough to keep pinning it: the
    // address is already published by that server's own record.
    final excludedLocators = <String>{};
    final syncedLocators = <String>{};
    // The same rule, for credentials: nothing prevents two configs pointing at
    // one vault entry, and a credential a still-synced server holds must keep
    // reaching the devices that want it.
    final syncedSecretRefs = <String>{};
    for (final s in servers) {
      (s.excludeFromSync ? excludedLocators : syncedLocators)
          .add(hostKeyLocator(s.host, s.port));
      if (!s.excludeFromSync && s.secretRef != null) {
        syncedSecretRefs.add(s.secretRef!);
      }
    }

    for (final server in servers) {
      if (server.excludeFromSync) {
        await _retract(server, syncedSecretRefs);
        continue;
      }
      await local.putLocal(await codec.encrypt(DecryptedRecord(
        id: server.id,
        kind: RecordKind.serverConfig,
        updatedAt: server.updatedAt,
        deviceId: deviceId,
        data: server.toJson(),
      )));
      if (syncSecrets && server.syncSecret && server.secretRef != null) {
        final secret = await secretVault?.getSecret(server.secretRef!);
        if (secret != null) {
          await local.putLocal(await codec.encrypt(DecryptedRecord(
            id: '$_secretIdPrefix${secret.id}',
            kind: RecordKind.secret,
            updatedAt: server.updatedAt,
            deviceId: deviceId,
            data: secret.toJson(),
          )));
        }
      }
    }
    for (final hk in await hostKeyStore.all()) {
      if (excludedLocators.contains(hk.locator) &&
          !syncedLocators.contains(hk.locator)) {
        // Withheld, not retracted, and the difference is a real residual: a
        // pin pushed before the exclusion stays on the sync server, carrying
        // the host and port the user asked to keep local. Another device that
        // still holds the pin — the config tombstone deletes its server, not
        // its pins — also keeps re-publishing it.
        //
        // Retracting would need a `hostkey:` tombstone the apply path honours,
        // and that is the change not to make: a tombstone is the one record
        // with no sealed payload (`RecordCodec.decrypt` short-circuits on the
        // envelope's `deleted` flag), so honouring one for a pin would let
        // anything able to write to the sync server strip every device's
        // pinned host keys and drop each of them back to trust-on-first-use.
        // A breach-tolerant blob store must not be able to do that. Sealing
        // tombstones comes first; retraction can follow it.
        continue;
      }
      await local.putLocal(await codec.encrypt(DecryptedRecord(
        id: 'hostkey:${hk.locator}',
        kind: RecordKind.hostKey,
        updatedAt: hk.pinnedAt,
        deviceId: deviceId,
        data: hk.toJson(),
      )));
    }
    final snippets = snippetStore;
    if (snippets != null) {
      for (final s in await snippets.listSnippets()) {
        await local.putLocal(await codec.encrypt(DecryptedRecord(
          id: 'snippet:${s.id}',
          kind: RecordKind.snippet,
          updatedAt: s.updatedAt,
          deviceId: deviceId,
          data: s.toJson(),
        )));
      }
    }
  }

  /// Retract a server the user has excluded from sync: tombstone its record,
  /// and its credential's, so a copy pushed before the exclusion comes off the
  /// server — and off the devices that pulled it, which apply both tombstones
  /// (see [_applySecretTombstones]). Doing nothing instead would leave the
  /// blob on the server forever while this device silently stopped updating
  /// it, which is a worse answer than either syncing or not.
  ///
  /// The record id is `secret:` + [ServerConfig.secretRef], which is the same
  /// id [collectLocal] pushes under: [SecretVault.putSecret] keys the blob by
  /// `secret.id` and serializes that same id inside it, so a secret read back
  /// through a ref always reports that ref as its id. Resolving the ref
  /// through the vault here to "be sure" would trade a guaranteed match for a
  /// decryption that throws when the OS keyring is locked — turning a locked
  /// keyring into a silently skipped retraction.
  ///
  /// Dated at [ServerConfig.updatedAt] rather than "now" for two reasons.
  /// Excluding a server *is* an edit, so that timestamp already is the moment
  /// the user asked for this — later than the copy on the server, and it loses
  /// to a genuinely newer edit made elsewhere exactly as any other write would.
  /// And a fixed date makes the tombstone identical between rounds, so the
  /// server sequences it once and later rounds simply adopt their own
  /// tombstone back instead of minting a new sequence number every five
  /// minutes.
  ///
  /// The credential is tombstoned whatever [syncSecrets] and
  /// [ServerConfig.syncSecret] say: those govern *pushing* one, and this
  /// device cannot tell from here whether an earlier session with different
  /// settings already did. Withdrawing a credential that was never there costs
  /// an id-shaped row; leaving one behind because we were unsure costs the
  /// credential.
  ///
  /// Unless a still-synced server shares it, which [syncedSecretRefs] names.
  /// A secret record is keyed by the credential, not by the server holding it,
  /// so a tombstone dated at the exclusion would beat that server's own push
  /// of the same id every round — quietly and permanently ending credential
  /// sync for a server the user never excluded.
  Future<void> _retract(
    ServerConfig server,
    Set<String> syncedSecretRefs,
  ) async {
    await _tombstone(server.id, RecordKind.serverConfig, server.updatedAt);
    final secretRef = server.secretRef;
    if (secretRef != null && !syncedSecretRefs.contains(secretRef)) {
      await _tombstone(
        '$_secretIdPrefix$secretRef',
        RecordKind.secret,
        server.updatedAt,
      );
    }
  }

  Future<void> _tombstone(String id, RecordKind kind, int updatedAt) async {
    await local.putLocal(await codec.encrypt(DecryptedRecord(
      id: id,
      kind: kind,
      updatedAt: updatedAt,
      deviceId: deviceId,
      deleted: true,
    )));
  }

  /// Write every record in the local store back into the domain stores,
  /// honouring tombstones. Returns the number of retractions that had to be
  /// re-dated (see [_rescheduleOutranked]), so the caller knows a further push
  /// is worth making.
  Future<int> applyToStores() async {
    // A server excluded from sync is local-only, so nothing pulled may touch
    // it: not the tombstone this device pushed to retract it (which comes back
    // on the next pull sequenced by the server), and not a copy another device
    // is still pushing because it has not seen that tombstone yet. Its
    // credential is shielded on the same grounds, in [_applySecretRecords].
    final excluded = <String>{
      for (final server in await configStore.listServers())
        if (server.excludeFromSync) server.id,
    };
    // Credentials are decided after the loop rather than inside it: whether one
    // may be applied or withdrawn depends on which servers still reference it,
    // and a config record in the same batch may be about to add or remove the
    // last reference. Record order is not defined, so deciding inline would
    // make the outcome depend on it.
    final secretRecords = <DecryptedRecord>[];
    final secretTombstones = <String>[];
    // Live configs for servers this device excluded: see [_rescheduleOutranked].
    final outranked = <DecryptedRecord>[];
    final skippedIds = <String>[];
    Object? firstError;
    StackTrace? firstStackTrace;
    void skip(String id, Object error, StackTrace stackTrace) {
      skippedIds.add(id);
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    for (final enc in await local.allRecords()) {
      try {
        final dec = await codec.decrypt(enc);

        // Tombstones have no encrypted kind, so the id prefix is what routes
        // them. Bare ids are the legacy server-deletion form; `secret:` is
        // handled after the loop; other prefixes remain no-ops pending a
        // per-kind delete for them.
        if (dec.deleted) {
          if (!dec.id.contains(_recordKindDelimiter)) {
            if (!excluded.contains(dec.id)) {
              await configStore.deleteServer(dec.id);
            }
          } else if (dec.id.startsWith(_secretIdPrefix)) {
            secretTombstones.add(dec.id);
          }
          continue;
        }

        switch (dec.kind) {
          case RecordKind.serverConfig:
            if (excluded.contains(dec.id)) {
              outranked.add(dec);
              continue;
            }

            await configStore.putServer(ServerConfig.fromJson(dec.data));
          case RecordKind.hostKey:
            await hostKeyStore.put(HostKey.fromJson(dec.data));
          case RecordKind.secret:
            secretRecords.add(dec);
          case RecordKind.snippet:
            final store = snippetStore;
            if (store == null) continue;

            await store.putSnippet(Snippet.fromJson(dec.data));
          case RecordKind.bookmark:
          case RecordKind.unknown:
            continue;
        }
      } catch (error, stackTrace) {
        skip(enc.id, error, stackTrace);
      }
    }

    await _applySecretRecords(secretRecords, skip);
    await _applySecretTombstones(secretTombstones, skip);

    if (skippedIds.isNotEmpty) {
      developer.log(
        'Skipped synced records: ${skippedIds.join(', ')}',
        name: _syncLoggerName,
        level: _warningLogLevel,
        error: firstError,
        stackTrace: firstStackTrace,
      );
    }

    return _rescheduleOutranked(outranked);
  }

  /// Store pulled credentials, shielding the ones only excluded servers name.
  ///
  /// A stale remote version of a local-only server's credential would
  /// otherwise overwrite the vault entry that server still uses. Shielded only
  /// when *no* synced server shares it — the same "every server that names it"
  /// rule the host-key locators use: a record for a ref a synced server holds
  /// is a live update for that server, not a stale copy of a local-only one.
  ///
  /// The rule is evaluated here, after the record loop, against the server
  /// list the whole batch produced: a config in the same batch may have just
  /// introduced the synced server that shares this credential, and deciding
  /// inline would have shielded it on a snapshot taken before that.
  Future<void> _applySecretRecords(
    List<DecryptedRecord> records,
    void Function(String, Object, StackTrace) skip,
  ) async {
    final vault = secretVault;
    if (records.isEmpty || !syncSecrets || vault == null) return;
    final shielded = await _shieldedSecretIds();
    for (final dec in records) {
      if (shielded.contains(dec.id)) continue;
      try {
        await vault.putSecret(Secret.fromJson(dec.data));
      } catch (error, stackTrace) {
        skip(dec.id, error, stackTrace);
      }
    }
  }

  /// Ids of credentials only excluded servers reference.
  Future<Set<String>> _shieldedSecretIds() async {
    final servers = await configStore.listServers();
    return <String>{
      for (final server in servers)
        if (server.excludeFromSync && server.secretRef != null)
          '$_secretIdPrefix${server.secretRef}',
    }..removeAll(<String>{
        for (final server in servers)
          if (!server.excludeFromSync && server.secretRef != null)
            '$_secretIdPrefix${server.secretRef}',
      });
  }

  /// Re-date retractions the server outranked, and report how many.
  ///
  /// [_retract] dates a tombstone at the config's `updatedAt` — the moment the
  /// user excluded the server, and so later than the copy on the server in the
  /// ordinary case. It is *not* later when another device wrote that copy
  /// under a clock this one runs behind, or edited it while this device was
  /// offline. Then the live record wins last-write-wins, the pull adopts it
  /// back over the tombstone, and every later round mints the same losing date
  /// again: the exclusion holds on this device forever while the config sits
  /// on the sync server and on every other device — a privacy switch failing
  /// silently in exactly the multi-device case it exists for.
  ///
  /// So a live config for an excluded server (which can only reach the local
  /// store by beating our tombstone) re-dates it one millisecond past the
  /// record that won, the smallest date that wins outright instead of tying.
  /// It escalates once and settles: the other device pushes its copy at a
  /// fixed `updatedAt` of its own, not a fresh one per round, so nothing
  /// bids back. Once the retraction lands, no live copy returns and
  /// [_retract]'s stable date takes over again.
  ///
  /// A credential is deliberately not re-dated the same way. A `secret:`
  /// record is keyed by the credential rather than by the server holding it,
  /// so a live one may be the ongoing push of a *synced* server on another
  /// device that shares the vault entry — one this device has not pulled yet,
  /// and whose owner never excluded anything. Out-bidding that would end
  /// credential sync for their server; the shield in [_applySecretRecords]
  /// already keeps the stale-copy case from touching this device's vault.
  ///
  /// The residual that leaves, stated rather than left to be rediscovered:
  /// when the live `secret:` record on the server is dated after the
  /// exclusion, the retraction loses and nothing escalates it, so the
  /// credential stays on the sync server. The shield protects this device's
  /// vault, not the remote copy.
  Future<int> _rescheduleOutranked(List<DecryptedRecord> records) async {
    for (final dec in records) {
      await _tombstone(dec.id, dec.kind, dec.updatedAt + 1);
    }
    return records.length;
  }

  /// Withdraw vault entries whose records were tombstoned — but only the ones
  /// no local server still points at.
  ///
  /// Deleting a credential is the one apply a later round cannot undo, so it
  /// is deliberately conservative. On the device that *made* the retraction,
  /// the excluded server still references its credential, and that reference
  /// is exactly what keeps it — the whole point is that this device keeps
  /// working. On the other device the config tombstone in the same batch has
  /// already removed the last reference, so the credential goes rather than
  /// lingering as an orphan nothing can name and nothing will ever clean up.
  ///
  /// Gated on [syncSecrets] like every other secret path: a user who has
  /// turned credential sync off has said remote secret records are not to
  /// touch their vault, and a delete is not the exception to that.
  /// One caveat this makes newly relevant: a tombstone carries no sealed
  /// payload — `RecordCodec.decrypt` returns a deleted record straight from
  /// the envelope's flag, without opening anything — so a deletion is the one
  /// signal the sync server can assert on its own. Bare-id tombstones already
  /// deleted configs on that basis; this path extends the reach to the
  /// credentials no remaining config names. The extra cost is bounded (the
  /// config has to go first, which was already possible) but the fix is to
  /// seal tombstones, not to special-case this apply.
  Future<void> _applySecretTombstones(
    List<String> ids,
    void Function(String, Object, StackTrace) skip,
  ) async {
    final vault = secretVault;
    if (ids.isEmpty || !syncSecrets || vault == null) return;
    final referenced = <String>{
      for (final server in await configStore.listServers())
        if (server.secretRef != null) '$_secretIdPrefix${server.secretRef}',
    };
    for (final id in ids) {
      if (referenced.contains(id)) continue;
      // Fail-soft like every other apply: the vault throws when the OS keyring
      // is locked, and one refused delete must not abandon the rest of the
      // batch — nor discard the diagnostics gathered for it.
      try {
        await vault.deleteSecret(id.substring(_secretIdPrefix.length));
      } catch (error, stackTrace) {
        skip(id, error, stackTrace);
      }
    }
  }

  /// One full synchronization round.
  Future<SyncOutcome> run(SyncApi api) async {
    await collectLocal();
    final engine = SyncEngine(local);
    final first = await engine.sync(api);
    // A retraction the server outranked has been re-dated to beat the record
    // that beat it. Push it now: the next run would only re-mint the same
    // losing date [collectLocal] computes, so waiting never resolves it. One
    // extra pass, never a loop — a second re-dating is left to the next run.
    if (await applyToStores() == 0) return first;
    final second = await engine.sync(api);
    await applyToStores();
    return SyncOutcome(
      pulled: first.pulled + second.pulled,
      pushed: first.pushed + second.pushed,
      rounds: first.rounds + second.rounds,
    );
  }
}
