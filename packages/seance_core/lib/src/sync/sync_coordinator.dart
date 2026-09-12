import 'dart:developer' as developer;

import 'package:meta/meta.dart';
import 'package:seance_protocol/seance_protocol.dart';

import '../hostkey/tofu.dart';
import '../store/stores.dart';
import 'local_record_store.dart';
import 'sync_engine.dart';

const int _warningLogLevel = 900;
const String _recordKindDelimiter = ':';
const String _secretIdPrefix = 'secret$_recordKindDelimiter';
const String _snippetIdPrefix = 'snippet$_recordKindDelimiter';
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

  /// Opt-in assistant-configuration syncing. Null — the default — means the
  /// record is neither pushed nor applied, so a device that has not opted in
  /// keeps its own provider, model and keys whatever the account carries.
  ///
  /// When it is set, the assistant's API keys travel inside the sealed record
  /// whether or not [syncSecrets] is on. The two switches are about different
  /// things — [syncSecrets] governs the credentials servers authenticate with
  /// — but `syncSecrets: false` is the flag a reader would reach for to keep
  /// key material off the server, so the exception is worth stating here. The
  /// seal is the protection, the same one synced passwords get.
  final AssistantSettingsStore? assistantStore;

  /// Whether an assistant record is worth having on the account at all.
  ///
  /// One predicate for both sides on purpose. [collectLocal] asks it before
  /// publishing and the apply loop asks it before adopting, and the two must
  /// answer identically: a record one side publishes and the other skips is
  /// parked on the account under a stamp nothing older can displace, and one
  /// the publish side would refuse but the apply side takes is adopted over a
  /// working configuration. Written out twice, that symmetry survives only
  /// until someone edits one copy. The reasoning behind each clause is at the
  /// two call sites, which is where it is load-bearing.
  static bool _isViableAssistantRecord(AssistantSettings s) =>
      s.providerKind.isNotEmpty && s.updatedAt > 0;

  /// Opt-in secret syncing. When true, [secretVault] and [secretIds] must be
  /// provided so secrets can be sealed into records.
  ///
  /// Governs server credentials only: the assistant's API keys travel with
  /// [assistantStore]'s record whatever this says — see there.
  final bool syncSecrets;
  final SecretVault? secretVault;

  /// Durable record of servers (and other kinds) the user has deleted, awaiting
  /// propagation. Optional so the pure-Dart tests and any embedding without a
  /// deletion path can omit it; when present, [collectLocal] republishes each
  /// pending tombstone so the engine pushes it, and [run] prunes it once the
  /// sync server has taken it. Null means deletions are not propagated — the
  /// pre-existing behaviour, which the app no longer relies on.
  final TombstoneStore? tombstoneStore;

  SyncCoordinator({
    required this.configStore,
    required this.hostKeyStore,
    required this.codec,
    required this.local,
    required this.deviceId,
    this.snippetStore,
    this.assistantStore,
    this.syncSecrets = false,
    this.secretVault,
    this.tombstoneStore,
  });

  /// The credentials [servers] opt into publishing to the account.
  ///
  /// One rule in one place: [collectLocal] decides what to publish with it and
  /// [_reviveSecrets] decides what is worth re-dating with it, and the two are
  /// only correct while they agree. This used to be a predicate inside
  /// `collectLocal`'s loop, leaning on the `continue` above it for the
  /// excluded half — a shape the second caller could only copy, not share, so
  /// adding a condition would have reached one and missed the other.
  Set<String> _publishableSecretRefs(List<ServerConfig> servers) => {
        if (syncSecrets)
          for (final server in servers)
            if (!server.excludeFromSync &&
                server.syncSecret &&
                server.secretRef != null)
              server.secretRef!,
      };

  /// Encode current local state into the record store (as local edits).
  ///
  /// Local credential edits must use [SecretVault.putLocalSecret] so their
  /// versions advance independently of unrelated server configuration edits.
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
      final ref = s.secretRef;
      if (ref != null && !s.excludeFromSync) syncedSecretRefs.add(ref);
    }

    // Record ids of domain objects that still exist this round. A pending
    // tombstone whose id is still present was re-created (import/migration) or
    // never actually removed, so it is not republished — see the tombstone
    // loop. Read from the stores, not the sync mirror: the mirror is rebuilt
    // per round, and a persistent one (the documented future store) would hold
    // a live copy of a just-deleted record that must not suppress its
    // tombstone. Fetched once and reused for the snippet publishing loop.
    final snippetList = await snippetStore?.listSnippets() ?? const <Snippet>[];
    final presentIds = <String>{
      for (final s in servers) s.id,
      for (final s in snippetList) '$_snippetIdPrefix${s.id}',
    };

    final publishedSecretRefs = _publishableSecretRefs(servers);
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
    }
    // Publish each opted-in credential at its own edit time. Legacy local
    // entries use zero until an actual edit or a remote version supplies a
    // stamp, so an unrelated server rename cannot promote stale material.
    // Older clients still borrow server timestamps and need upgrading for
    // this protection to hold on every device.
    for (final ref in publishedSecretRefs) {
      final secret = await secretVault?.getSecret(ref);
      if (secret == null) continue;
      await local.putLocal(await codec.encrypt(DecryptedRecord(
        id: '$_secretIdPrefix${secret.id}',
        kind: RecordKind.secret,
        updatedAt: secret.updatedAt,
        deviceId: deviceId,
        data: secret.toJson(),
      )));
    }
    // Deletions the user made are remembered in [tombstoneStore], not in
    // configStore — the row is gone. Republish each as a dirty tombstone so the
    // engine pushes it and last-write-wins carries the delete to the server and
    // every other device, instead of the deleted record returning on the next
    // full pull and being re-adopted by [applyToStores]. Pruned in [run] once
    // the server has the tombstone. A config tombstone is honoured on apply
    // regardless of the payload it replaces (routed by its bare id), so the
    // deletion converges even for a kind a peer cannot yet decode.
    for (final tombstone
        in await tombstoneStore?.all() ?? const <EncryptedRecord>[]) {
      // Skip a tombstone whose id still names a live domain object this round:
      // an id re-created (import or migration) while its delete was pending, or
      // one whose row-drop was interrupted. Publishing it would push a delete
      // for something that exists. Checked against [presentIds] (the stores),
      // not the mirror, so it holds however the mirror is backed; the app also
      // clears a pending tombstone when its id is re-saved.
      if (presentIds.contains(tombstone.id)) continue;
      await local.putLocal(tombstone);
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
        id: hk.recordId,
        kind: RecordKind.hostKey,
        updatedAt: hk.pinnedAt,
        deviceId: deviceId,
        data: hk.toJson(),
      )));
    }
    // The contract reserves null for "the keys could not be vouched for this
    // round", but the real store backs onto an OS keyring, and a locked or
    // missing one surfaces from a platform channel as a throw. Uncaught, one
    // failed keystore read would abandon the rest of this method — the
    // snippets below it would never be collected, and a round's worth of
    // unrelated records would pay for the assistant's keyring. Degrading to
    // null costs the assistant the round it was going to sit out anyway.
    AssistantSettings? assistant;
    try {
      assistant = await assistantStore?.getAssistantSettings();
    } catch (_) {
      assistant = null;
    }
    // The apply side's guard, at the boundary where bad data enters: an empty
    // provider means a payload this build could not read, not a configuration
    // — the same degradation `fromJson` makes of a missing field can happen
    // to a device's own settings file — and publishing one would park a
    // record no device adopts on the account under this device's stamp,
    // where nothing older can displace it.
    // And the stamp, which is the other half of "is this worth publishing".
    // Zero means this device has never edited its assistant — the sentinel
    // `AppState.assistantSyncSwitchedOn` reads before it decides to stamp and
    // publish. Without it here, a device that opted in with nothing
    // configured parks its *shipped defaults* on the account at stamp zero,
    // and the next device to opt in — every install that configured its
    // assistant before this feature existed reads zero too — adopts them over
    // a working provider, model and keys, because `0 < 0` is false. That is
    // the exact harm the switch-on guard exists to prevent; guarding the
    // stamp bump alone left this path open.
    if (assistant != null && _isViableAssistantRecord(assistant)) {
      await local.putLocal(await codec.encrypt(DecryptedRecord(
        id: AssistantSettings.recordId,
        kind: RecordKind.assistantSettings,
        // The settings' own timestamp, not the round's: collectLocal runs
        // every five minutes, and a moving one would make each round a fresh
        // winning write and set two devices trading the record forever.
        updatedAt: assistant.updatedAt,
        deviceId: deviceId,
        data: assistant.toJson(),
      )));
    }
    for (final s in snippetList) {
      await local.putLocal(await codec.encrypt(DecryptedRecord(
        id: '$_snippetIdPrefix${s.id}',
        kind: RecordKind.snippet,
        updatedAt: s.updatedAt,
        deviceId: deviceId,
        data: s.toJson(),
      )));
    }
  }

  /// Retract a server the user has excluded from sync: tombstone its record,
  /// and its credential's, so a copy pushed before the exclusion comes off the
  /// server — and the server row off the devices that pulled it, which honour
  /// the config tombstone. They keep their vault entry, because a tombstone is
  /// unsealed and so is not trusted with a delete; the routing comment in
  /// [applyToStores] has the reasoning. Doing nothing instead would leave the
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
  /// That row is a real disclosure and worth naming: a credential the user
  /// never synced has its ref published to the sync server as a tombstone id.
  /// It is a `uuidV4` minted for the vault, carrying no host, user or label,
  /// so what the server learns is that a credential exists — and it stops
  /// there, because the id is not honoured as a delete anywhere. Gating this
  /// on the current [syncSecrets] instead would trade that for the failure
  /// that actually matters: a credential the user *did* publish under older
  /// settings, left on the sync server with nothing that will ever withdraw
  /// it.
  ///
  /// Unless a still-synced server shares it, which [syncedSecretRefs] names.
  /// A secret record is keyed by the credential, not by the server holding it,
  /// so a tombstone dated at the exclusion would beat that server's own push
  /// of the same id every round — quietly and permanently ending credential
  /// sync for a server the user never excluded. That set counts a sharer
  /// whose own [ServerConfig.syncSecret] is off too, which is the
  /// conservative side of the same trade: a credential such a sharer once
  /// published stays on the server rather than being withdrawn from under a
  /// server that still holds it.
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

  /// Re-date a credential this device retracted and then opted back in to,
  /// and report how many moved.
  ///
  /// The credential analogue of [_revive], and needed for the same reason: a
  /// retraction is dated from the config that carried it, so re-including the
  /// server leaves a tombstone the credential's own edit time — which the
  /// switch did not touch — loses to. Without this the config comes back while
  /// its credential stays withdrawn, and a device enrolling afterwards gets a
  /// server it cannot log into.
  ///
  /// The bump is written to the vault as well as staged, which does move a
  /// stamp the user did not earn by editing the material. Two reasons it has
  /// to: the record's payload carries the same stamp as its envelope and a
  /// peer *rejects* the pair when they disagree ([_applySecretRecords]), and a
  /// vault left behind would republish the losing date every round. It is the
  /// same fiction [_revive] applies to a re-included config, bounded the same
  /// way — one millisecond past the retraction, a deterministic function of a
  /// date already on the record, so it settles instead of bidding.
  ///
  /// [servers] is the list [applyToStores] already read, not a second read of
  /// the same store: publishing eligibility must be the rule [collectLocal]
  /// applies, and two reads could straddle a write and disagree with it.
  ///
  /// What that costs, accepted rather than left to be rediscovered: a peer's
  /// config tombstone applied earlier in the same batch has already deleted a
  /// server that is still in this list, so its credential can be revived and
  /// published once as an orphan no config names. It is the same one-round
  /// view [collectLocal] published under a moment earlier, it corrects itself
  /// on the next round's read, and the alternative — re-reading the store
  /// here — buys that at the price of the two rules disagreeing, which is the
  /// failure this list exists to prevent.
  Future<int> _reviveSecrets(
    List<(String, int)> refs,
    List<ServerConfig> servers,
    void Function(String, Object, StackTrace) skip,
  ) async {
    final vault = secretVault;
    if (refs.isEmpty || !syncSecrets || vault == null) return 0;
    final published = _publishableSecretRefs(servers);
    var bumpedCount = 0;
    for (final (ref, retractedAt) in refs) {
      // Still retracted as far as this device is concerned: the switch is off
      // again, or off for every owner. Nothing to bring back.
      if (!published.contains(ref)) continue;
      // Fail-soft per credential, like [_revive]: a locked keyring on one
      // entry must not throw out of `applyToStores` and discard the round.
      try {
        final secret = await vault.getSecret(ref);
        // Gone, or already outranking its own retraction — [collectLocal]
        // publishes a winning date on its own and needs no help. Counting it
        // would spend a sync round on a batch that changed nothing.
        if (secret == null || secret.updatedAt > retractedAt) continue;
        final bumped = secret.copyWith(updatedAt: retractedAt + 1);
        // Staged first, stored second, for the reason spelled out in
        // [_revive]: a failed store write is retried identically next round,
        // while a failed stage after a successful store write would leave the
        // guard above dropping this credential forever.
        await local.putLocal(await codec.encrypt(DecryptedRecord(
          id: '$_secretIdPrefix$ref',
          kind: RecordKind.secret,
          updatedAt: bumped.updatedAt,
          deviceId: deviceId,
          data: bumped.toJson(),
        )));
        await vault.putSecret(bumped);
        bumpedCount++;
      } catch (error, stackTrace) {
        skip('$_secretIdPrefix$ref', error, stackTrace);
      }
    }
    return bumpedCount;
  }

  /// Drop pending tombstones that are done, so [tombstoneStore] stays bounded.
  ///
  /// [collectLocal] republishes every entry each round (unless its id is a
  /// live record again — see [presentIds]). An entry is done in two cases, both
  /// judged from the sequenced record the mirror holds after the round:
  ///
  ///  * a sequenced tombstone — this round's push was accepted, or a pull
  ///    carried the server's own copy back: the delete has propagated.
  ///  * a sequenced live record strictly newer than the tombstone — a peer's
  ///    later edit won last-write-wins (or the id was re-created), so the
  ///    tombstone can never win and [collectLocal] already skips it; retrying
  ///    it forever would only leak store entries.
  ///
  /// Everything else stays: an unconfirmed entry (a round that pushed nothing —
  /// offline), or a live record the tombstone still outranks (an interrupted
  /// row-drop, where the delete may yet win). Dropping either would strand a
  /// deletion while the record resurrects.
  Future<void> _pruneConfirmedTombstones() async {
    final store = tombstoneStore;
    if (store == null) return;
    for (final pending in await store.all()) {
      final mirrored = await local.getRecord(pending.id);
      if (mirrored == null || mirrored.seq == null) continue;
      if (mirrored.deleted || mirrored.updatedAt > pending.updatedAt) {
        await store.remove(pending.id);
      }
    }
  }

  /// Write every record in the local store back into the domain stores,
  /// honouring tombstones. Returns the number of records that had to be
  /// re-dated — retractions the server outranked (see [rescheduleOutranked])
  /// plus servers re-included behind their own retraction (see [_revive]) — so
  /// the caller knows a further push is worth making.
  Future<int> applyToStores() async {
    // A server excluded from sync is local-only, so nothing pulled may touch
    // it: not the tombstone this device pushed to retract it (which comes back
    // on the next pull sequenced by the server), and not a copy another device
    // is still pushing because it has not seen that tombstone yet. Its
    // credential is shielded on the same grounds, in [_applySecretRecords].
    final servers = await configStore.listServers();
    final excluded = <String>{
      for (final server in servers)
        if (server.excludeFromSync) server.id,
    };
    // The address rule [collectLocal] applies on the way out, on the way in:
    // a pin for an address only excluded servers use is withheld from the
    // account, and the mirror therefore never holds it — so a copy another
    // device pushes would win last-write-wins by default and overwrite a pin
    // this device made locally. Nothing pulled may touch a local-only server,
    // and that includes what this device chose to trust for its address.
    final excludedLocators = <String>{
      for (final server in servers)
        if (server.excludeFromSync) hostKeyLocator(server.host, server.port),
    }..removeAll(<String>{
        for (final server in servers)
          if (!server.excludeFromSync)
            hostKeyLocator(server.host, server.port),
      });
    // Credentials are decided after the loop rather than inside it: whether one
    // may be applied or withdrawn depends on which servers still reference it,
    // and a config record in the same batch may be about to add or remove the
    // last reference. Record order is not defined, so deciding inline would
    // make the outcome depend on it.
    final secretRecords = <DecryptedRecord>[];
    // Live configs for servers this device excluded: see [rescheduleOutranked].
    final outranked = <DecryptedRecord>[];
    // Servers this device re-included whose own retraction still outranks
    // them: see the tombstone branch below.
    final revived = <(ServerConfig, int)>[];
    // Credentials of those servers, as `(ref, retracted at)`. A credential's
    // own edit time does not move when the user merely flips the switch back,
    // so unlike a config it cannot outrank its retraction on its own.
    final revivedSecrets = <(String, int)>[];
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
        // them. Bare ids are the legacy server-deletion form and still delete.
        // A `snippet:` tombstone is applied like a config below (a snippet is
        // non-secret settings, the same risk class as a config). The other
        // prefixed kinds — `secret:`, `hostkey:` — are deliberately a no-op:
        // `RecordCodec.decrypt` returns a deleted record straight from the
        // envelope's flag without opening anything, so a tombstone is the one
        // signal a sync server can assert entirely on its own. Honouring those
        // would hand it a primitive for emptying the vault (tombstone the
        // configs first, then the credentials no config still names) and for
        // stripping this device's TOFU pins. Configs already carried that
        // exposure before any of this; a credential vault and a set of host
        // key pins are not where to widen it. The fix is sealing tombstones —
        // an authenticator over id, kind and date, keyed like the payload —
        // not a per-apply special case, so the records stay staged for a
        // build that can check them. Sealing must cover `snippet:` tombstones
        // too: they are applied on arrival like configs, so an unsealed one
        // lets a sync server delete a snippet on every device (a lost snippet,
        // the same bounded cost configs already accept).
        if (dec.deleted) {
          // Routed on the delimiter alone because a config id never carries
          // one: every config is minted with `uuidV4()` (the editor's draft
          // id and the ssh_config import), and the prefixed kinds are the
          // only ids that contain it.
          if (!dec.id.contains(_recordKindDelimiter)) {
            if (excluded.contains(dec.id)) continue;
            // Our own retraction, for a server this device is no longer
            // excluding: the user turned the switch back off. Deleting here
            // would honour a decision that has since been reversed — and the
            // re-included config cannot win it back on its own, because the
            // tombstone may have been re-dated past this device's clock by
            // [rescheduleOutranked]. So the live record is re-dated instead,
            // the mirror of that escalation, and the delete is skipped.
            // Not named `local`: that is the record store this method
            // writes through, and shadowing it here would let a later edit
            // reach for `local.putLocal` and silently get a ServerConfig.
            final localServer = await configStore.getServer(dec.id);
            // Only this device's own retraction is revived past. A peer's
            // tombstone for the same server — both devices excluded it, and
            // the peer's exclusion outranks this device's re-inclusion —
            // deletes a config this device just re-included, with nothing to
            // say so. Dropping the guard would resurrect configs legitimately
            // deleted elsewhere, so the residual stands until a delete can
            // carry its intent; pinned by "a peer's later exclusion outranks
            // a re-inclusion".
            if (localServer != null && dec.deviceId == deviceId) {
              revived.add((localServer, dec.updatedAt));
              continue;
            }
            await configStore.deleteServer(dec.id);
            continue;
          }
          // Our own retraction of a credential: the mirror of the config
          // revival above, and the other half of it — re-including a server
          // republishes its config, but the credential record stays withdrawn
          // from the account behind a tombstone the credential's own stamp
          // cannot beat. The vault still holds it (a `secret:` tombstone is
          // never honoured against the vault — see the routing comment
          // above), so this is about the copy peers can reach, not about this
          // device's own.
          //
          // Only this device's own retraction, exactly as for a config and
          // for the same reason: a peer's tombstone says a server *they*
          // excluded shared this credential, which is not a decision this
          // device can read as reversed. What that leaves is the documented
          // orphan residual, not a credential this device loses.
          if (dec.id.startsWith(_secretIdPrefix) && dec.deviceId == deviceId) {
            revivedSecrets.add((
              dec.id.substring(_secretIdPrefix.length),
              dec.updatedAt,
            ));
            continue;
          }
          // A `snippet:` tombstone IS applied, unlike `secret:`/`hostkey:`: a
          // snippet is non-secret settings, the same risk class as a config an
          // unsealed tombstone can already delete on a sync server's say-so, so
          // honouring it costs at most a lost snippet, never vault or trust
          // material. The refused kinds stay staged for a sealed-tombstone
          // build (they simply fall through this branch to the `continue`).
          final snippets = snippetStore;
          if (snippets != null &&
              dec.id.length > _snippetIdPrefix.length &&
              dec.id.startsWith(_snippetIdPrefix)) {
            await snippets
                .deleteSnippet(dec.id.substring(_snippetIdPrefix.length));
          }
          continue;
        }

        switch (dec.kind) {
          case RecordKind.serverConfig:
            if (excluded.contains(dec.id)) {
              outranked.add(dec);
              continue;
            }

            final pulled = ServerConfig.fromJson(dec.data);
            // The exclusion shield above keys on the *record* id, and this
            // write would key on the payload's. A record whose two ids
            // disagree — schema drift, a buggy peer, anything hand-made by a
            // device that has the key — would slip a config past the shield,
            // and land under an id no tombstone can ever name.
            if (pulled.id != dec.id) {
              skip(
                dec.id,
                StateError(
                  'config id ${pulled.id} does not match record id ${dec.id}',
                ),
                StackTrace.current,
              );
              continue;
            }
            await configStore.putServer(pulled);
          case RecordKind.hostKey:
            final pin = HostKey.fromJson(dec.data);
            // The same id invariant the config and secret paths enforce: a
            // pin is stored under its payload's locator, and a record whose
            // id names another would plant trust for an address no record
            // ever named, with nothing in the log to say so.
            if (dec.id != pin.recordId) {
              skip(
                dec.id,
                StateError(
                  'host key locator ${pin.locator} does not match record id '
                  '${dec.id}',
                ),
                StackTrace.current,
              );
              continue;
            }
            if (excludedLocators.contains(pin.locator)) continue;
            await hostKeyStore.put(pin);
          case RecordKind.secret:
            secretRecords.add(dec);
          case RecordKind.snippet:
            final store = snippetStore;
            if (store == null) continue;

            final snippet = Snippet.fromJson(dec.data);
            // LWW and tombstones name the envelope id; the store writes the
            // payload id. They must identify the same snippet or this record
            // can overwrite one whose newer edit or deletion already won.
            if (dec.id != '$_snippetIdPrefix${snippet.id}') {
              skip(
                dec.id,
                StateError(
                  'snippet id ${snippet.id} does not match record id ${dec.id}',
                ),
                StackTrace.current,
              );
              continue;
            }
            await store.putSnippet(snippet);
          case RecordKind.assistantSettings:
            final store = assistantStore;
            if (store == null) continue;

            final assistant = AssistantSettings.fromJson(dec.data);
            // `fromJson` degrades a missing field to '' rather than throwing,
            // so that a record from a newer build stays readable. A provider
            // name is the one field that can never legitimately be empty — it
            // is written from an enum — so an empty one means the payload is
            // not a configuration, and adopting it would replace a working
            // assistant with nothing on every device that pulled it.
            // And a stamp of zero, for the same reason one is never
            // published: zero means "never edited here", so no compliant
            // client puts one on the wire and two devices cannot legitimately
            // tie at it. Refusing it here costs no convergence — unlike
            // widening the comparison below, which would refuse a real tie —
            // and it keeps a record parked by an older build, or by a client
            // that does not follow this rule, from being adopted over a
            // working configuration by every device still reading zero.
            if (!_isViableAssistantRecord(assistant)) {
              continue;
            }

            // This record won last-write-wins against the synced *mirror*,
            // which is only as fresh as the last [collectLocal]. Unlike a
            // server config, the assistant configuration is edited straight
            // into its store between rounds — so an edit made while a round
            // was already in flight is newer than anything the mirror knows,
            // and applying an older pulled record over it would lose the edit
            // silently, then re-collect and publish the loss.
            //
            // Strictly older, not older-or-equal: a tie between two records
            // is already resolved at the record layer by device id and
            // sequence, and skipping ties here would stop two devices ever
            // converging on one of them. The tie that resolution never sees is
            // a local edit that did not reach the mirror this round — made
            // after [collectLocal] ran, or withheld by it because a key it
            // references could not be read. That edit loses to a pulled record
            // sharing its stamp, which is the narrow price of convergence and
            // why the edit stamp is minted as fine-grained as the clock
            // allows.
            if (assistant.updatedAt < await store.assistantSettingsUpdatedAt()) {
              continue;
            }

            await store.putAssistantSettings(assistant);
          case RecordKind.bookmark:
          case RecordKind.unknown:
            continue;
        }
      } catch (error, stackTrace) {
        skip(enc.id, error, stackTrace);
      }
    }

    await _applySecretRecords(secretRecords, skip);

    // Both re-dating passes report through `skip` too, so they run before
    // the log line, not after it: a tombstone that could not be minted or a
    // revival that could not be staged was landing in `skippedIds` a moment
    // after the only reader of `skippedIds` had already spoken.
    final redated = await rescheduleOutranked(outranked, skip) +
        await _revive(revived, skip) +
        await _reviveSecrets(revivedSecrets, servers, skip);
    if (skippedIds.isNotEmpty) {
      developer.log(
        'Skipped synced records: ${skippedIds.join(', ')}',
        name: _syncLoggerName,
        level: _warningLogLevel,
        error: firstError,
        stackTrace: firstStackTrace,
      );
    }
    return redated;
  }

  /// Re-date a re-included server past the retraction it is still losing to.
  ///
  /// Excluding under a clock this device runs behind re-dates the tombstone to
  /// beat the copy that beat it — which can be past this device's own clock.
  /// Turning the switch back off then stamps an honest "now" that still loses,
  /// so the server would stay retracted everywhere else and this device would
  /// apply its own stale retraction and delete the config it had just brought
  /// back. Persisting the bump is what makes it stick: a fresh timestamp each
  /// round would be a new winning write every five minutes, which is the churn
  /// [_retract]'s stable date exists to avoid.
  Future<int> _revive(
    List<(ServerConfig, int)> servers,
    void Function(String, Object, StackTrace) skip,
  ) async {
    var bumpedCount = 0;
    for (final (config, retractedAt) in servers) {
      if (config.updatedAt > retractedAt) continue;
      // Fail-soft per record, like the loop that produced this list: a
      // transient store error on one server would otherwise throw out of
      // `applyToStores`, discarding the sync outcome the round had already
      // earned and skipping the second pass — turning one flaky write into a
      // whole failed round.
      try {
        final bumped = config.copyWith(updatedAt: retractedAt + 1);
        // The staged record first, the store second. The bump is a
        // deterministic function of the retraction's date, so a failed
        // `putServer` is retried identically next round — but a failed
        // `putLocal` *after* a successful `putServer` is never retried,
        // because the store then reports `updatedAt > retractedAt` and the
        // guard above drops this server from `revived` forever. The bump
        // would never reach a peer, while the losing pre-bump record still
        // would, and the next pull's tombstone would delete the config the
        // user had just brought back.
        await local.putLocal(await codec.encrypt(DecryptedRecord(
          id: bumped.id,
          kind: RecordKind.serverConfig,
          updatedAt: bumped.updatedAt,
          deviceId: deviceId,
          data: bumped.toJson(),
        )));
        await configStore.putServer(bumped);
        bumpedCount++;
      } catch (error, stackTrace) {
        skip(config.id, error, stackTrace);
      }
    }
    // What was bumped, not what was offered: a server already outranking its
    // own retraction needs nothing, and counting it would spend an extra sync
    // round on a batch that changed nothing.
    return bumpedCount;
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
    // The id invariant enforced here rather than left to the call site, like
    // the kind check in [rescheduleOutranked]: every id this method reasons
    // about is `secret:` + the vault ref, which is what [_shieldedSecretIds]
    // builds and what the shield is compared against. A record arriving under
    // any other id could not be shielded by construction, and would go to
    // `Secret.fromJson` to either throw into the skip diagnostics or, worse,
    // parse and be written into the vault as a credential nothing named.
    for (final dec in records.where((d) => !d.id.startsWith(_secretIdPrefix))) {
      // Through `skip`, not a log line of its own: correctly not written, but
      // every other drop in this method lands in `skippedIds`, and a peer
      // minting secret ids differently should show up where a reader is
      // already looking rather than in a channel of its own.
      skip(
        dec.id,
        StateError('secret record id is not `$_secretIdPrefix`-prefixed'),
        StackTrace.current,
      );
    }
    // After the id check, so a peer minting ids differently shows up on a
    // device that syncs no secrets too — otherwise the problem looks
    // device-specific while it is being chased.
    final vault = secretVault;
    if (!syncSecrets || vault == null) return;
    // A store read after the loop above has already written configs and host
    // keys: fail-soft like every other failure in this method, or one flaky
    // read throws out of `applyToStores` past the re-dating passes and the
    // log, and the round's outcome goes with it.
    // One predicate, computed once: the two loops below have to agree with
    // each other and with the check above on what a secret record *is*, and a
    // copy each would let one be edited without the others.
    final prefixed =
        records.where((d) => d.id.startsWith(_secretIdPrefix)).toList();
    final Set<String> shielded;
    try {
      shielded = await _shieldedSecretIds();
    } catch (error, stackTrace) {
      for (final dec in prefixed) {
        skip(dec.id, error, stackTrace);
      }
      return;
    }
    for (final dec in prefixed) {
      if (shielded.contains(dec.id)) continue;
      try {
        final secret = Secret.fromJson(dec.data);
        // The shield keys on the record id and the vault write keys on the
        // payload's: a record whose two disagree would slip a credential past
        // the shield and land it under a ref the shield never named — the
        // same hole the config path closes for its own id.
        if (dec.id != '$_secretIdPrefix${secret.id}') {
          skip(
            dec.id,
            StateError(
              'secret id ${secret.id} does not match record id ${dec.id}',
            ),
            StackTrace.current,
          );
          continue;
        }
        if (dec.data.containsKey('updatedAt') &&
            secret.updatedAt != dec.updatedAt) {
          skip(
            dec.id,
            StateError('secret timestamp does not match its record'),
            StackTrace.current,
          );
          continue;
        }
        // An older copy must not land on a newer local edit. Before a
        // credential carried a version of its own, the record store's
        // last-write-wins did this job: every referenced credential was
        // published every round, so an older remote never reached here as a
        // winner. Publishing is opt-in now, so a credential this device does
        // not publish has no record of its own standing in front of it, and
        // this floor is all that is left. Strictly newer, so a tie still
        // resolves where it always did — in the record layer, which breaks it
        // by device and seq; this only refuses what is plainly stale.
        // An entry that will not decrypt is absent for this purpose, not
        // something to protect. The floor above exists to keep a newer local
        // edit, and an entry with no readable version has none to keep — while
        // the record being weighed against it is the only thing that can
        // repair the damage. Letting the read throw instead sends the record
        // to `skip`, which leaves the vault holding a credential the user
        // cannot use and sync unable to replace it, on this round and every
        // round after. Before a credential carried a version at all this path
        // simply overwrote, so failing closed here would be a new way to lose
        // one.
        //
        // Narrow on purpose: the vault's own failures (a MAC that will not
        // verify, malformed JSON, a store that cannot be read) are all
        // exceptions, so anything deriving from `Error` is a bug in this
        // process and still reaches the per-record handler as one rather than
        // being read as "absent".
        Secret? existing;
        try {
          existing = await vault.getSecret(secret.id);
        } on Exception {
          // Left null: an unreadable entry is the absent case above.
        }
        if (existing != null && existing.updatedAt > dec.updatedAt) continue;
        // Legacy peers omit the payload stamp. Persist their envelope version
        // so subsequent local config edits never manufacture a newer one.
        await vault.putSecret(secret.copyWith(updatedAt: dec.updatedAt));
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
  /// vault, not the remote copy. And because a `secret:` tombstone is not
  /// honoured against the vault at all (see the routing comment in
  /// [applyToStores]), the *other* device keeps its copy of the credential as
  /// an orphan no config names — inert, and invisible in a UI that lists
  /// servers, but not gone. Both residuals close the same way: sealed
  /// tombstones, which let a delete be trusted and so escalated.
  ///
  /// Visible for testing because the guard below is the whole point: a test
  /// that can only reach it through [applyToStores] — which filters first —
  /// proves the filter, never the guard.
  @visibleForTesting
  Future<int> rescheduleOutranked(
    List<DecryptedRecord> records, [
    void Function(String, Object, StackTrace)? skip,
  ]) async {
    // Both invariants this doc comment spends paragraphs on are enforced here
    // rather than left to the call site to preserve forever. Every record
    // reaching the loop is re-tombstoned, so an unfiltered list handed in by
    // some future path would delete every pulled config on every device — the
    // one mistake in this file whose blast radius is the whole account, and
    // it should not be a filter away. The kind check is the other half:
    // minting a tombstone one millisecond past a live `secret:` record is
    // exactly the harm described above.
    //
    // The exclusion is re-read from the store rather than checked against a
    // staged tombstone, which is what it looks like it should be: by the time
    // a record is in this list it *beat* that tombstone, so the local store
    // holds the winning config under that id and the tombstone is gone.
    final excluded = <String>{
      for (final server in await configStore.listServers())
        if (server.excludeFromSync) server.id,
    };
    // Live records only, checked here for the same reason as the kind: a
    // tombstone re-dated past itself would be a bid two excluding devices
    // could trade forever. A pulled tombstone never carries a kind (decrypt
    // returns `unknown` for one), so the kind check already refuses it; the
    // flag is the invariant stated in its own words.
    final configs = records
        .where((dec) =>
            dec.kind == RecordKind.serverConfig &&
            !dec.deleted &&
            excluded.contains(dec.id))
        .toList();
    var mintedCount = 0;
    for (final dec in configs) {
      try {
        await _tombstone(dec.id, dec.kind, dec.updatedAt + 1);
        mintedCount++;
      } catch (error, stackTrace) {
        if (skip == null) rethrow;
        skip(dec.id, error, stackTrace);
      }
    }
    return mintedCount;
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
    // Named, because the gate only means what the comment above says while
    // this is the *re-dating* count and not, say, the number of records
    // applied — which would double every round's traffic on the hot path,
    // hidden inside the summed outcome.
    final redated = await applyToStores();
    if (redated == 0) {
      await _pruneConfirmedTombstones();
      return first;
    }
    final second = await engine.sync(api);
    await applyToStores();
    await _pruneConfirmedTombstones();
    return SyncOutcome(
      pulled: first.pulled + second.pulled,
      pushed: first.pushed + second.pushed,
      rounds: first.rounds + second.rounds,
    );
  }
}
