import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_core/seance_core.dart';

const _baseUrl = 'https://sync.test';
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// A round that adopts the assistant record and *then* fails must still
/// rebuild the chat provider.
///
/// The pull runs before the push, and `runSync` keeps `assistantSettingsChanged`
/// in a `finally` for exactly this case — but the flag is reset at the top of
/// the next round, which then finds the settings already adopted and reports
/// nothing applied. Consumed only on success, the adoption is invisible and the
/// assistant answers with the old provider, model and key until some unrelated
/// edit happens to rebuild it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-assistant-sync-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    services.settings.syncBaseUrl = _baseUrl;
    services.settings.syncAssistant = true;
    await services.masterKeys.putApiKey('sync.token', 'session-token');
  });

  tearDown(() async {
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  test('a round that adopts and then fails still rebuilds the provider',
      () async {
    final codec = RecordCodec(services.vaultKey!);
    // A server this device keeps off the account. The copy arriving for it is
    // outranked and re-dated, which is what makes the coordinator take its
    // second pass — the one that fails here, after the assistant record has
    // already been applied.
    const excluded = ServerConfig(
      id: 'excluded-server',
      label: 'local only',
      host: 'local.example.com',
      username: 'me',
      excludeFromSync: true,
      createdAt: 100,
      updatedAt: 100,
    );
    await services.configStore.putServer(excluded);

    final records = [
      await codec.encrypt(DecryptedRecord(
        id: AssistantSettings.recordId,
        kind: RecordKind.assistantSettings,
        updatedAt: 500,
        deviceId: 'other-device',
        data: const AssistantSettings(
          providerKind: 'openaiCompatible',
          baseUrl: 'https://api.openai.com/v1',
          model: 'gpt-5',
          llmApiKeyRef: 'openai',
          redactSecrets: true,
          apiKeys: {'openai': 'sk-remote'},
          updatedAt: 500,
        ).toJson(),
      )),
      await codec.encrypt(DecryptedRecord(
        id: excluded.id,
        kind: RecordKind.serverConfig,
        updatedAt: 500,
        deviceId: 'other-device',
        data: excluded.copyWith(label: 'from the account').toJson(),
      )),
    ];

    // The engine drains the pull before the coordinator applies anything: the
    // first GET carries the records, the second observes that nothing new
    // arrived. Only then does `applyToStores` run, and its re-dating is what
    // sends the coordinator back for the third — which is the first one this
    // server refuses.
    var gets = 0;
    final transport = MockClient((request) async {
      if (request.method == 'GET') {
        gets++;
        if (gets >= 3) {
          return http.Response('down', HttpStatus.internalServerError);
        }
        return http.Response(
          jsonEncode(PullResponse(
            records: gets == 1
                ? [
                    for (var i = 0; i < records.length; i++)
                      records[i].withSeq(i + 1),
                  ]
                : const [],
            latestSeq: records.length,
          ).toJson()),
          HttpStatus.ok,
        );
      }
      return http.Response(
        jsonEncode(
          PushResponse(results: const [], latestSeq: records.length).toJson(),
        ),
        HttpStatus.ok,
      );
    });

    final state = AppState(services);
    addTearDown(state.dispose);
    final versionBefore = state.llmConfigVersion;
    await http.runWithClient(
      () => expectLater(state.syncNow(), throwsA(isA<ApiError>())),
      () => transport,
    );

    // The failure came from the pull after the adoption, not from an earlier
    // request — otherwise the assertions below would fail for the wrong
    // reason.
    expect(gets, greaterThanOrEqualTo(3));
    // Adopted, as the round's first half managed.
    expect(services.settings.llmModel, 'gpt-5');
    // The whole configuration, not just the model: the failure this guards
    // is "answers with the old provider, model and key", and a key that
    // never reached the keystore would leave the rebuilt provider mute.
    expect(services.settings.llmBaseUrl, 'https://api.openai.com/v1');
    expect(await services.masterKeys.getApiKey('openai'), 'sk-remote');
    expect(services.assistantSettingsChanged, isTrue);
    // And consumed, which is the whole point: an already-built chat provider
    // notices none of a new provider, model or key on its own.
    expect(state.llmConfigVersion, versionBefore + 1);
  });

  test('an edit never stamps below the record this device holds', () async {
    // The stamp is the whole of the last-write-wins comparison. A clock that
    // runs behind the device this configuration was pulled from would make a
    // fresh edit lose to the record it had just adopted — and the next round
    // would re-apply that record over the edit, silently.
    final state = AppState(services);
    addTearDown(state.dispose);
    final ahead = DateTime.now().millisecondsSinceEpoch +
        const Duration(days: 365).inMilliseconds;
    services.settings.assistantUpdatedAt = ahead;

    await state.assistantSettingsEdited();

    expect(services.settings.assistantUpdatedAt, greaterThan(ahead));
  });

  test('a round queued behind an adopting one does not hide the adoption',
      () async {
    // `runSync` resets `assistantSettingsChanged` as its first statement, and
    // a round queued on the mutation queue starts as soon as the adopting one
    // releases it. The adoption flag is sampled while the round still holds
    // the queue, so which of the two resumes first cannot matter. (Today the
    // awaiting caller does — an async return reaches its awaiter a microtask
    // ahead of the completer's release — so this passes with the flag read
    // after the release too; it pins the scenario, not the ordering.)
    final codec = RecordCodec(services.vaultKey!);
    final record = await codec.encrypt(DecryptedRecord(
      id: AssistantSettings.recordId,
      kind: RecordKind.assistantSettings,
      updatedAt: 500,
      deviceId: 'other-device',
      data: const AssistantSettings(
        providerKind: 'openaiCompatible',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5',
        llmApiKeyRef: 'openai',
        redactSecrets: true,
        apiKeys: {'openai': 'sk-remote'},
        updatedAt: 500,
      ).toJson(),
    ));
    var gets = 0;
    var seq = 1;
    final transport = MockClient((request) async {
      if (request.method == 'GET') {
        gets++;
        return http.Response(
          jsonEncode(PullResponse(
            records: gets == 1 ? [record.withSeq(1)] : const [],
            // The head as this mock has actually handed it out, not the
            // constant it started at: the pushes below advance it, and
            // answering the old value would have the client watch the
            // account's head go backwards between the two rounds — a state
            // no server can be in, and one a client is free to reject.
            latestSeq: seq,
          ).toJson()),
          HttpStatus.ok,
        );
      }
      // Accept whatever the second round publishes, so it ends cleanly.
      final pushed = PushRequest.fromJson(
        jsonDecode(request.body) as Map<String, dynamic>,
      ).records;
      return http.Response(
        jsonEncode(PushResponse(
          results: [
            for (final r in pushed)
              PushResult(id: r.id, seq: ++seq, accepted: true),
          ],
          latestSeq: seq,
        ).toJson()),
        HttpStatus.ok,
      );
    });

    final state = AppState(services);
    addTearDown(state.dispose);
    final versionBefore = state.llmConfigVersion;
    await http.runWithClient(
      () => Future.wait([state.syncNow(), state.syncNow()]),
      () => transport,
    );

    expect(services.settings.llmModel, 'gpt-5');
    expect(gets, greaterThanOrEqualTo(3), reason: 'both rounds pulled');
    // Rebuilt exactly once: by the round that adopted, not by the one that
    // found nothing new.
    expect(state.llmConfigVersion, versionBefore + 1);
    // And the flag is the queued round's by the end — which is the whole
    // reason the adopting round samples it before releasing the queue.
    expect(services.assistantSettingsChanged, isFalse);
  });

  test('switching on with the toggle still off neither syncs nor stamps',
      () async {
    // With the toggle off `runSync` builds no assistant store, so a round can
    // adopt nothing — and falling through would stamp `now` on this device's
    // configuration and persist it, an inflated stamp that outranks the
    // account's record when the switch is genuinely turned on later.
    services.settings.syncAssistant = false;
    services.settings.assistantUpdatedAt = 5;
    var requests = 0;
    final transport = MockClient((request) async {
      requests++;
      return http.Response(
        jsonEncode(const PullResponse(records: [], latestSeq: 0).toJson()),
        HttpStatus.ok,
      );
    });

    final state = AppState(services);
    addTearDown(state.dispose);
    await http.runWithClient(
      () => state.assistantSyncSwitchedOn(),
      () => transport,
    );

    expect(requests, 0);
    expect(services.settings.assistantUpdatedAt, 5);
  });

  test('reloadLlmProvider bumps the config version exactly once', () async {
    // `_save` in the settings screen tells an adoption that landed during its
    // awaits from its own reload by counting: any bump beyond the one it makes
    // itself is somebody else's. That constant lives in a different file from
    // the method it counts, so an early return added here — "nothing
    // configured, nothing to reload" — would make every save report that the
    // settings changed on another device, reload the fields, and refuse.
    final state = AppState(services);
    addTearDown(state.dispose);

    // With nothing configured first — the early return a future optimisation
    // would most plausibly add ("no provider, nothing to reload").
    final before = state.llmConfigVersion;
    await state.reloadLlmProvider();
    expect(state.llmConfigVersion, before + 1);

    // And with a key stored, where the reload has something to do. Twice in a
    // row with the same configuration too: a bump conditional on the config
    // *changing* would break the count just as surely.
    await services.masterKeys.putApiKey('anthropic', 'sk-configured');
    await state.reloadLlmProvider();
    expect(state.llmConfigVersion, before + 2);
    await state.reloadLlmProvider();
    expect(state.llmConfigVersion, before + 3);

    // The other half of the arithmetic `_save` does: it subtracts its own
    // single bump and reads anything left over as somebody else's adoption,
    // so the two calls it makes around that reload must not bump at all.
    final steady = state.llmConfigVersion;
    await services.saveSettings();
    expect(state.llmConfigVersion, steady, reason: 'saveSettings must not bump');
    await state.assistantSettingsEdited();
    expect(state.llmConfigVersion, steady,
        reason: 'publishing an edit must not bump');
  });

  group('switching on at the zero stamp', () {
    /// An empty account: nothing to adopt, so the switch's second half — the
    /// publish — is the only thing that can happen.
    // Account-wide and monotonic, like a real server's: per-request it
    // restarted at 1 on every push, so a second round in one test would have
    // seen the sequence go backwards.
    var seq = 0;
    // Group-level state, so it has to start each test where the comment above
    // says it does: read across tests, the head a round sees would depend on
    // how many records the ones before it pushed — arbitrary under
    // `--test-randomize-ordering-seed`, and confusing in a single-test run.
    setUp(() => seq = 0);
    MockClient emptyAccount(void Function(String id) onPushed) => MockClient(
          (request) async {
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode(
                  // Monotonic here too: the account head this mock reports is
                  // the one its own acknowledgements have reached.
                  PullResponse(records: const [], latestSeq: seq).toJson(),
                ),
                HttpStatus.ok,
              );
            }
            // By id, not by counting requests: the round pushes whatever else
            // this device holds, and "a POST happened" would pass for a
            // server config while the assistant record stayed behind.
            final pushed = PushRequest.fromJson(
              jsonDecode(request.body) as Map<String, dynamic>,
            ).records;
            for (final record in pushed) {
              onPushed(record.id);
            }
            // Acknowledged, as a server does. Answering `results: []` to
            // every push simulates a server that silently drops what it is
            // sent, so a client that treated an unacknowledged record as
            // unsynced would look identical to one that published.
            var next = seq;
            seq += pushed.length;
            return http.Response(
              jsonEncode(PushResponse(
                results: [
                  for (final record in pushed)
                    PushResult(id: record.id, seq: ++next, accepted: true),
                ],
                latestSeq: seq,
              ).toJson()),
              HttpStatus.ok,
            );
          },
        );

    test('an install configured before this feature shipped publishes',
        () async {
      // The upgrade path, and the whole reason the guard cannot be the stamp
      // alone: `assistantUpdatedAt` was added by this feature, so every device
      // that already had a working assistant reads zero. Silent here, it
      // adopts nothing from an empty account and publishes nothing, and the
      // switch does nothing at all until the settings happen to be edited.
      services.settings.assistantUpdatedAt = 0;
      // Off, so the publish is this method's own second round rather than the
      // debounce it would otherwise hand to — the branch the switch takes for
      // a user who has just watched a round run.
      services.settings.autoSync = false;
      await services.masterKeys.putApiKey('anthropic', 'sk-configured');

      final pushed = <String>[];
      final state = AppState(services);
      addTearDown(state.dispose);
      await http.runWithClient(
        () => state.assistantSyncSwitchedOn(),
        () => emptyAccount(pushed.add),
      );

      expect(services.settings.assistantUpdatedAt, greaterThan(0),
          reason: 'a configured device must stamp what it is about to publish');
      expect(pushed, contains(AssistantSettings.recordId));
    });

    test('a device that already has a stamp does not stamp again', () async {
      // Not a zero-stamp case, and the reason the guard reads the stamp
      // rather than only the adoption flag: this device's record is already
      // the account's — the round above pushed it, or it was there and
      // nothing outranked it. Stamping again republishes identical content
      // under a newer date, making this device the permanent winner of a
      // record it may not have authored, and it is the only thing standing
      // between a round queued behind this one and a false "adopted nothing".
      services.settings.assistantUpdatedAt = 500;
      services.settings.autoSync = false;
      await services.masterKeys.putApiKey('anthropic', 'sk-configured');

      final state = AppState(services);
      addTearDown(state.dispose);
      final pushed = <String>[];
      await http.runWithClient(
        () => state.assistantSyncSwitchedOn(),
        () => emptyAccount(pushed.add),
      );

      expect(services.settings.assistantUpdatedAt, 500);
      // The stamp suppresses re-stamping, not publishing: the round's own
      // `collectLocal` still puts the record on the account. Discarding the
      // pushed ids here could not tell that from a device that had silently
      // stopped syncing its assistant altogether.
      expect(pushed, contains(AssistantSettings.recordId));
    });

    test('an upgrading configured device adopts rather than clobbers',
        () async {
      // The other half of the upgrade path, and the one with something to
      // lose: stamp 0 and genuinely configured, but the account already holds
      // a phone's record. The empty-account test cannot tell "publishes
      // because it is configured" from "publishes because there was nothing
      // to adopt".
      services.settings.assistantUpdatedAt = 0;
      services.settings.autoSync = false;
      services.settings.llmModel = 'my-local-model';
      await services.masterKeys.putApiKey('anthropic', 'sk-configured');

      final codec = RecordCodec(services.vaultKey!);
      final remote = await codec.encrypt(DecryptedRecord(
        id: AssistantSettings.recordId,
        kind: RecordKind.assistantSettings,
        updatedAt: 900,
        deviceId: 'phone',
        data: const AssistantSettings(
          providerKind: 'anthropic',
          baseUrl: 'https://api.anthropic.com',
          model: 'the-phone-model',
          llmApiKeyRef: 'anthropic',
          redactSecrets: true,
          apiKeys: {'anthropic': 'sk-phone'},
          updatedAt: 900,
        ).toJson(),
      ));

      final pushed = <String>[];
      var seq = 1;
      final transport = MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode(PullResponse(
              records: [remote.withSeq(1)],
              latestSeq: 1,
            ).toJson()),
            HttpStatus.ok,
          );
        }
        final records = PushRequest.fromJson(
          jsonDecode(request.body) as Map<String, dynamic>,
        ).records;
        for (final record in records) {
          pushed.add(record.id);
        }
        return http.Response(
          jsonEncode(PushResponse(
            results: [
              for (final record in records)
                PushResult(id: record.id, seq: ++seq, accepted: true),
            ],
            latestSeq: seq,
          ).toJson()),
          HttpStatus.ok,
        );
      });

      final state = AppState(services);
      addTearDown(state.dispose);
      await http.runWithClient(
        () => state.assistantSyncSwitchedOn(),
        () => transport,
      );

      // Adopted, not published over: the switch's own copy says it replaces
      // the assistant setup on this device.
      expect(services.settings.llmModel, 'the-phone-model');
      expect(services.settings.assistantUpdatedAt, 900);
      expect(pushed, isNot(contains(AssistantSettings.recordId)),
          reason: 'a device that adopted has nothing of its own to publish');
    });

    test('a fresh install publishes nothing over the account', () async {
      // The other half of the zero stamp, and the case the guard was written
      // for: no key anywhere, so nothing here is a configuration. Stamping
      // `now` would make this laptop's shipped defaults the account's newest
      // write and beat a phone that configured a real provider while sync was
      // off and enables the switch afterwards.
      services.settings.assistantUpdatedAt = 0;
      services.settings.autoSync = false;

      final pushed = <String>[];
      final state = AppState(services);
      addTearDown(state.dispose);
      await http.runWithClient(
        () => state.assistantSyncSwitchedOn(),
        () => emptyAccount(pushed.add),
      );

      expect(services.settings.assistantUpdatedAt, 0);
      expect(pushed, isNot(contains(AssistantSettings.recordId)),
          reason: 'defaults are not a configuration worth publishing');
    });
  });
}
