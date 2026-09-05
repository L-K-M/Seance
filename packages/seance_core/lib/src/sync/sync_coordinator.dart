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
    for (final s in servers) {
      (s.excludeFromSync ? excludedLocators : syncedLocators)
          .add(hostKeyLocator(s.host, s.port));
    }

    for (final server in servers) {
      if (server.excludeFromSync) {
        await _retract(server);
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
  /// server — and off the devices that pulled it. Doing nothing instead would
  /// leave the blob on the server forever while this device silently stopped
  /// updating it, which is a worse answer than either syncing or not.
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
  Future<void> _retract(ServerConfig server) async {
    await _tombstone(server.id, RecordKind.serverConfig, server.updatedAt);
    final secretRef = server.secretRef;
    if (secretRef != null) {
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
  /// honouring tombstones.
  Future<void> applyToStores() async {
    // A server excluded from sync is local-only, so nothing pulled may touch
    // it: not the tombstone this device pushed to retract it (which comes back
    // on the next pull sequenced by the server), and not a copy another device
    // is still pushing because it has not seen that tombstone yet.
    final excluded = <String>{
      for (final server in await configStore.listServers())
        if (server.excludeFromSync) server.id,
    };
    final skippedIds = <String>[];
    Object? firstError;
    StackTrace? firstStackTrace;

    for (final enc in await local.allRecords()) {
      try {
        final dec = await codec.decrypt(enc);

        // Tombstones have no encrypted kind. Preserve legacy bare-id server
        // deletion; prefixed tombstones remain no-ops pending per-kind delete.
        if (dec.deleted) {
          if (!dec.id.contains(_recordKindDelimiter) &&
              !excluded.contains(dec.id)) {
            await configStore.deleteServer(dec.id);
          }
          continue;
        }

        switch (dec.kind) {
          case RecordKind.serverConfig:
            if (excluded.contains(dec.id)) continue;

            await configStore.putServer(ServerConfig.fromJson(dec.data));
          case RecordKind.hostKey:
            await hostKeyStore.put(HostKey.fromJson(dec.data));
          case RecordKind.secret:
            if (!syncSecrets || secretVault == null) continue;

            await secretVault!.putSecret(Secret.fromJson(dec.data));
          case RecordKind.snippet:
            final store = snippetStore;
            if (store == null) continue;

            await store.putSnippet(Snippet.fromJson(dec.data));
          case RecordKind.bookmark:
          case RecordKind.unknown:
            continue;
        }
      } catch (error, stackTrace) {
        skippedIds.add(enc.id);
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (skippedIds.isEmpty) return;

    developer.log(
      'Skipped synced records: ${skippedIds.join(', ')}',
      name: _syncLoggerName,
      level: _warningLogLevel,
      error: firstError,
      stackTrace: firstStackTrace,
    );
  }

  /// One full synchronization round.
  Future<SyncOutcome> run(SyncApi api) async {
    await collectLocal();
    final outcome = await SyncEngine(local).sync(api);
    await applyToStores();
    return outcome;
  }
}
