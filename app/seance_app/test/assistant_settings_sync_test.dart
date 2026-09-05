import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/assistant_settings_sync.dart';
import 'package:seance_app/services/secure_master_key.dart';
import 'package:seance_core/seance_core.dart';

/// An in-memory keystore that can be locked, like the one the resilience test
/// uses. `read`/`write` are the only entry points [MasterKeyManager] takes.
class _Keystore extends FlutterSecureStorage {
  _Keystore();
  final Map<String, String> entries = {};
  bool locked = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (locked) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
    return entries[key];
  }

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
    if (locked) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
    if (value == null) {
      entries.remove(key);
    } else {
      entries[key] = value;
    }
  }
}

void main() {
  late _Keystore keystore;
  late MasterKeyManager keys;
  late AppSettings settings;
  late int saves;
  late AssistantSettingsSync sync;

  setUp(() {
    keystore = _Keystore();
    keys = MasterKeyManager(keystore);
    settings = AppSettings();
    saves = 0;
    sync = AssistantSettingsSync(
      settings: settings,
      masterKeys: keys,
      saveSettings: () async => saves++,
    );
  });

  group('publishing', () {
    test('nothing is published before the assistant is configured', () async {
      // Two fresh installs must not push rival defaults at each other.
      expect(settings.assistantUpdatedAt, 0);
      expect(await sync.getAssistantSettings(), isNull);
    });

    test('publishes the configuration with the keys it references', () async {
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = 'anthropic';
      settings.zaiApiKeyRef = 'zai';
      settings.searxngUrl = 'https://searx.example.com';
      settings.redactionEnabled = false;
      await keys.putApiKey('anthropic', 'sk-llm');
      await keys.putApiKey('zai', 'sk-zai');
      // Neither of these is referenced by the assistant configuration, and
      // neither may ever leave this device: one protects the account, the
      // other decrypts everything in it.
      await keystore.write(key: 'seance.apikey.sync.token', value: 'tok');
      await keystore.write(key: 'seance.vault.masterKey.v1', value: 'vault');

      final published = (await sync.getAssistantSettings())!;

      expect(published.providerKind, 'anthropic');
      expect(published.model, settings.llmModel);
      expect(published.searxngUrl, 'https://searx.example.com');
      expect(published.zaiApiKeyRef, 'zai');
      expect(published.redactSecrets, isFalse);
      expect(published.updatedAt, 99);
      expect(published.apiKeys, {'anthropic': 'sk-llm', 'zai': 'sk-zai'});
      // The keys are gathered from the references, never by sweeping the
      // keystore — so nothing unreferenced can be swept up with them.
      final encoded = published.toJson().toString();
      expect(encoded, isNot(contains('tok')));
      expect(encoded, isNot(contains('vault')));
    });

    test('a locked keyring publishes the configuration without its keys',
        () async {
      // getApiKey answers null rather than throwing, so a keystore that is
      // down costs the keys, not the whole sync round.
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = 'anthropic';
      await keys.putApiKey('anthropic', 'sk-llm');
      keystore.locked = true;

      final published = (await sync.getAssistantSettings())!;
      expect(published.apiKeys, isEmpty);
      expect(published.llmApiKeyRef, 'anthropic');
    });
  });

  group('adopting', () {
    AssistantSettings arriving({
      String providerKind = 'openaiCompatible',
      Map<String, String> apiKeys = const {'openai': 'sk-remote'},
    }) => AssistantSettings(
          providerKind: providerKind,
          baseUrl: 'https://api.openai.com/v1',
          model: 'gpt-5',
          llmApiKeyRef: 'openai',
          searxngUrl: 'https://searx.example.com',
          zaiApiKeyRef: 'zai',
          redactSecrets: false,
          apiKeys: apiKeys,
          updatedAt: 500,
        );

    test('adopts the configuration and its keys, then saves', () async {
      await sync.putAssistantSettings(arriving());

      expect(settings.llmKind, LlmProviderKind.openaiCompatible);
      expect(settings.llmBaseUrl, 'https://api.openai.com/v1');
      expect(settings.llmModel, 'gpt-5');
      expect(settings.llmApiKeyRef, 'openai');
      expect(settings.searxngUrl, 'https://searx.example.com');
      expect(settings.zaiApiKeyRef, 'zai');
      expect(settings.redactionEnabled, isFalse);
      expect(settings.assistantUpdatedAt, 500);
      expect(await keys.getApiKey('openai'), 'sk-remote');
      expect(saves, 1);
      // The chat provider is built once per configuration version and would
      // otherwise keep using the old model and key.
      expect(sync.applied, isTrue);
    });

    test('a provider this build does not know keeps the one configured',
        () async {
      // Decoding an unknown name into a wrong guess is worse than keeping
      // what works — the same choice ServerConfig makes for a colour.
      settings.llmKind = LlmProviderKind.anthropic;
      await sync.putAssistantSettings(
        arriving(providerKind: 'some-future-provider'),
      );
      expect(settings.llmKind, LlmProviderKind.anthropic);
      // Everything it *could* understand still lands.
      expect(settings.llmModel, 'gpt-5');
    });

    test('a locked keyring still adopts the configuration', () async {
      // The key is re-applied on a later round: the record is pulled again
      // every time, so a keyring that comes back catches up on its own.
      keystore.locked = true;
      await sync.putAssistantSettings(arriving());

      expect(settings.llmModel, 'gpt-5');
      expect(settings.assistantUpdatedAt, 500);
      expect(saves, 1);
    });

    test('a record with no keys leaves the local ones alone', () async {
      await keys.putApiKey('openai', 'sk-local');
      await sync.putAssistantSettings(arriving(apiKeys: const {}));
      expect(await keys.getApiKey('openai'), 'sk-local');
    });
  });
}
