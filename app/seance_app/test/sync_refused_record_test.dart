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
const _maxBlobBytes = 64 * 1024;

/// A record the sync server refuses as too large is refused again on every
/// round, so the round that reports it must still show what it pulled.
///
/// `SyncCoordinator.run` applies everything else before it reports the
/// refusal, but the lists the UI draws from are re-read only when a round
/// returns. Without re-reading them on the refusal too, another device's edit
/// would be on disk and never on screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-refused-sync-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    services.settings.syncBaseUrl = _baseUrl;
    await services.masterKeys.putApiKey('sync.token', 'session-token');
  });

  tearDown(() async {
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  test('a refused record still lets the round show what it pulled', () async {
    await services.snippetStore.putSnippet(Snippet(
      id: 'big',
      title: 'deploy.sh',
      body: 'x' * (100 * 1024),
      createdAt: 1,
      updatedAt: 20,
    ));
    final pulled = await RecordCodec(services.vaultKey!).encrypt(
      DecryptedRecord(
        id: 'from-elsewhere',
        kind: RecordKind.serverConfig,
        updatedAt: 30,
        deviceId: 'other-device',
        data: const ServerConfig(
          id: 'from-elsewhere',
          label: 'added elsewhere',
          host: 'elsewhere.example.com',
          username: 'me',
          createdAt: 30,
          updatedAt: 30,
        ).toJson(),
      ),
    );

    // The real server's two answers: every pull carries the account and the
    // advertised cap, and a push holding a blob past the cap is refused whole.
    var seq = 1;
    final transport = MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode(PullResponse(
            records: [pulled.withSeq(1)],
            latestSeq: 1,
            limits: const PushLimits(maxBlobBytes: _maxBlobBytes),
          ).toJson()),
          HttpStatus.ok,
        );
      }
      final push = PushRequest.fromJson(
          jsonDecode(request.body) as Map<String, dynamic>);
      if (push.records.any((r) => r.blob.length > _maxBlobBytes)) {
        return http.Response(
          jsonEncode(const ApiError(
            code: 'payload_too_large',
            message: 'A record blob exceeds the 65536-byte limit',
          ).toJson()),
          HttpStatus.requestEntityTooLarge,
        );
      }
      return http.Response(
        jsonEncode(PushResponse(
          results: [
            for (final r in push.records)
              PushResult(id: r.id, seq: ++seq, accepted: true),
          ],
          latestSeq: seq,
        ).toJson()),
        HttpStatus.ok,
      );
    });

    final state = AppState(services);
    addTearDown(state.dispose);
    await http.runWithClient(
      () => expectLater(
        state.syncNow(),
        throwsA(isA<SyncRecordsRefused>()
            .having((e) => e.recordIds, 'recordIds', ['snippet:big'])),
      ),
      () => transport,
    );

    expect(state.servers.map((s) => s.label), ['added elsewhere'],
        reason: 'the pulled server reaches the list the UI draws');
    expect(state.snippets.single.title, 'deploy.sh',
        reason: 'the refused snippet stays on this device');
    expect(state.lastSyncError, contains('Snippet "deploy.sh"'),
        reason: 'the sync status names the record to fix');
  });
}
