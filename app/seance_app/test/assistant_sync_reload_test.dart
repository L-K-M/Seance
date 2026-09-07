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
            latestSeq: 1,
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
  });

  group('switching on at the zero stamp', () {
    /// An empty account: nothing to adopt, so the switch's second half — the
    /// publish — is the only thing that can happen.
    MockClient emptyAccount(void Function(String id) onPushed) => MockClient(
          (request) async {
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode(
                  const PullResponse(records: [], latestSeq: 0).toJson(),
                ),
                HttpStatus.ok,
              );
            }
            // By id, not by counting requests: the round pushes whatever else
            // this device holds, and "a POST happened" would pass for a
            // server config while the assistant record stayed behind.
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            for (final record in body['records'] as List<dynamic>) {
              onPushed((record as Map<String, dynamic>)['id'] as String);
            }
            return http.Response(
              jsonEncode(
                const PushResponse(results: [], latestSeq: 0).toJson(),
              ),
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

      expect(services.settings.assistantUpdatedAt, isNot(0),
          reason: 'a configured device must stamp what it is about to publish');
      expect(pushed, contains(AssistantSettings.recordId));
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
