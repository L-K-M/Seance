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
    await http.runWithClient(
      () => expectLater(state.syncNow(), throwsA(isA<ApiError>())),
      () => transport,
    );

    // Adopted, as the round's first half managed.
    expect(services.settings.llmModel, 'gpt-5');
    expect(services.assistantSettingsChanged, isTrue);
    // And consumed, which is the whole point: an already-built chat provider
    // notices none of a new provider, model or key on its own.
    expect(state.llmConfigVersion, 1);
    state.dispose();
  });
}
