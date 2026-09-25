import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/external_file_opener.dart';
import 'package:seance_app/services/local_settings_backend.dart';
import 'package:seance_app/services/secure_master_key.dart';
import 'package:seance_app/services/settings_backend.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// An in-memory keystore whose writes can be made to fail per entry, the way
/// a locked keyring refuses them.
class _Keystore extends FlutterSecureStorage {
  final Map<String, String> values = {};
  final Set<String> refuseWrites = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (refuseWrites.contains(key)) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values.remove(key);
}

/// The logic the Settings screen used to hold, now behind the backend both the
/// route and the settings window use: the assistant save's adoption guards and
/// keys-first ordering, and the sync switches' rollbacks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Keystore keystore;
  late AppServices services;
  late AppState state;
  late LocalSettingsBackend backend;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-settings-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    keystore = _Keystore();
    services = await AppServices.initialize(
      masterKeyManager: MasterKeyManager(keystore),
    );
    state = AppState(services);
    backend = LocalSettingsBackend(state);
  });

  tearDown(() async {
    state.dispose();
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    await directory.delete(recursive: true);
  });

  File settingsFile() => File('${directory.path}/settings.json');

  Map<String, dynamic> onDisk() =>
      jsonDecode(settingsFile().readAsStringSync()) as Map<String, dynamic>;

  /// Every later settings write fails: the atomic write renames onto the
  /// file's path, and a directory is there instead.
  Future<void> breakSettingsWrites() async {
    if (settingsFile().existsSync()) settingsFile().deleteSync();
    await Directory('${settingsFile().path}/blocker').create(recursive: true);
  }

  AssistantDraft draft({
    LlmProviderKind kind = LlmProviderKind.openaiCompatible,
    String baseUrl = ' https://llm.example/v1 ',
    String model = ' a-model ',
    bool zai = false,
    String llmKey = '',
    String zaiKey = '',
    int? versionSeen,
  }) => AssistantDraft(
    fields: AssistantFields(
      kind: kind,
      baseUrl: baseUrl,
      model: model,
      searxngUrl: '',
      zaiEnabled: zai,
      redactionEnabled: true,
    ),
    llmApiKey: llmKey,
    zaiApiKey: zaiKey,
    versionSeen: versionSeen ?? backend.llmConfigVersion,
  );

  group('saveAssistant', () {
    test(
      'stores the keys, then the trimmed fields, under the provider ref',
      () async {
        final version = backend.llmConfigVersion;
        final result = await backend.saveAssistant(
          draft(zai: true, llmKey: ' sk-typed\n', zaiKey: ' zai-typed '),
        );

        expect(result.status, AssistantSaveStatus.saved);
        expect(result.keysStored, isTrue);
        expect(result.adoptedMeanwhile, isFalse);
        expect(result.zaiWithoutKey, isFalse);
        // The provider reload is the save's own bump, and its only one.
        expect(result.version, version + 1);
        expect(backend.llmConfigVersion, version + 1);
        expect(keystore.values['seance.apikey.openai'], 'sk-typed');
        expect(keystore.values['seance.apikey.zai'], 'zai-typed');

        final s = backend.settings;
        expect(s.llmKind, LlmProviderKind.openaiCompatible);
        expect(s.llmBaseUrl, 'https://llm.example/v1');
        expect(s.llmModel, 'a-model');
        expect(s.llmApiKeyRef, 'openai');
        expect(s.zaiApiKeyRef, 'zai');
        expect(onDisk()['llmModel'], 'a-model');
        expect(result.current.model, 'a-model');
      },
    );

    test(
      'refuses a draft loaded before an adoption, and writes nothing',
      () async {
        final before = backend.settings.toJson();
        // What a sync round adopting another device's configuration does.
        await state.reloadLlmProvider();

        final result = await backend.saveAssistant(
          draft(llmKey: 'sk-typed', versionSeen: backend.llmConfigVersion - 1),
        );

        expect(result.status, AssistantSaveStatus.adoptedBeforeSave);
        expect(result.version, backend.llmConfigVersion);
        expect(keystore.values, isNot(contains('seance.apikey.openai')));
        expect(backend.settings.toJson(), before);
      },
    );

    test(
      'a key the keystore refuses stops the save before the settings',
      () async {
        keystore.refuseWrites.add('seance.apikey.openai');
        final before = backend.settings.toJson();

        final result = await backend.saveAssistant(draft(llmKey: 'sk-typed'));

        expect(result.status, AssistantSaveStatus.keystoreFailed);
        expect(result.failedKey, AssistantKey.llm);
        expect(result.error, contains('OS keyring'));
        expect(backend.settings.toJson(), before);
      },
    );

    test('names the Z.AI key when that is the write that failed', () async {
      keystore.refuseWrites.add('seance.apikey.zai');

      final result = await backend.saveAssistant(
        draft(zai: true, zaiKey: 'zai-typed', llmKey: 'sk-typed'),
      );

      expect(result.status, AssistantSaveStatus.keystoreFailed);
      expect(result.failedKey, AssistantKey.zai);
      // Keys first, Z.AI's first of all: the LLM key was never attempted.
      expect(keystore.values, isNot(contains('seance.apikey.openai')));
    });

    test(
      'Z.AI on with no key stored saves, and says the search will skip',
      () async {
        final result = await backend.saveAssistant(draft(zai: true));

        expect(result.status, AssistantSaveStatus.saved);
        expect(result.zaiWithoutKey, isTrue);
        expect(result.keysStored, isFalse);
        expect(backend.settings.zaiApiKeyRef, 'zai');
      },
    );

    test('a blank or whitespace key keeps the stored one', () async {
      keystore.values['seance.apikey.openai'] = 'sk-stored';

      final result = await backend.saveAssistant(draft(llmKey: '   '));

      expect(result.status, AssistantSaveStatus.saved);
      expect(result.keysStored, isFalse);
      expect(keystore.values['seance.apikey.openai'], 'sk-stored');
    });

    test(
      'a failed settings write throws rather than reporting a save',
      () async {
        await breakSettingsWrites();

        await expectLater(backend.saveAssistant(draft()), throwsA(anything));
      },
    );
  });

  group('setSyncPrefs', () {
    test('persists all three switches', () async {
      final result = await backend.setSyncPrefs(
        autoSync: false,
        syncSecrets: true,
        syncAssistant: false,
      );

      expect(result.saveError, isNull);
      expect(result.autoSync, isFalse);
      expect(result.syncSecrets, isTrue);
      expect(onDisk()['autoSync'], isFalse);
      expect(onDisk()['syncSecrets'], isTrue);
    });

    test('a failed write puts every switch back and reports it', () async {
      final s = backend.settings;
      final autoSync = s.autoSync;
      final syncSecrets = s.syncSecrets;
      await breakSettingsWrites();

      final result = await backend.setSyncPrefs(
        autoSync: !autoSync,
        syncSecrets: !syncSecrets,
        syncAssistant: true,
      );

      expect(result.saveError, isNotNull);
      expect(result.autoSync, autoSync);
      expect(result.syncSecrets, syncSecrets);
      expect(result.syncAssistant, isFalse);
      expect(s.autoSync, autoSync);
      expect(s.syncSecrets, syncSecrets);
      expect(s.syncAssistant, isFalse);
    });

    test(
      'assistant sync that cannot run its first round is switched off',
      () async {
        // Enrolled with a server that cannot answer: the round that adopts or
        // publishes fails (a widget test answers every HTTP request with 400).
        services.settings.syncBaseUrl = 'https://sync.invalid';
        await services.masterKeys.putApiKey('sync.token', 'session-token');
        final result = await backend.setSyncPrefs(
          autoSync: backend.settings.autoSync,
          syncSecrets: backend.settings.syncSecrets,
          syncAssistant: true,
        );

        expect(result.assistantSyncError, isNotNull);
        expect(result.syncAssistant, isFalse);
        expect(backend.settings.syncAssistant, isFalse);
        expect(result.adopted, isFalse);
      },
    );
  });

  test('a failed keep-alive write puts the setting back and throws', () async {
    final before = backend.settings.keepSessionsAliveInBackground;
    await breakSettingsWrites();

    await expectLater(backend.setKeepSessionsAlive(!before), throwsA(anything));
    expect(backend.settings.keepSessionsAliveInBackground, before);
  });

  test(
    'the editor registry is stored as a copy, not the caller\'s object',
    () async {
      final mine = EditorRegistry.fromJson(
        backend.settings.editorRegistry.toJson(),
      )..defaultEditorId = EditorRegistry.builtInId;
      await backend.setEditorRegistry(mine);

      mine.defaultEditorId = EditorRegistry.systemDefaultId;

      expect(
        backend.settings.editorRegistry.defaultEditorId,
        EditorRegistry.builtInId,
      );
      expect(
        (onDisk()['editorRegistry'] as Map)['defaultEditorId'],
        EditorRegistry.builtInId,
      );
    },
  );
}
