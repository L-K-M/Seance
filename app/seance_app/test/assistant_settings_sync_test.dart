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
      settings.llmModel = 'claude-custom';
      settings.braveApiKeyRef = 'brave';
      settings.zaiApiKeyRef = 'zai';
      settings.searxngUrl = 'https://searx.example.com';
      settings.redactionEnabled = false;
      await keys.putApiKey('anthropic', 'sk-llm');
      await keys.putApiKey('brave', 'sk-brave');
      await keys.putApiKey('zai', 'sk-zai');
      // Neither of these is referenced by the assistant configuration, and
      // neither may ever leave this device: one protects the account, the
      // other decrypts everything in it.
      await keystore.write(key: 'seance.apikey.sync.token', value: 'tok');
      await keystore.write(key: 'seance.vault.masterKey.v1', value: 'vault');

      final published = (await sync.getAssistantSettings())!;

      expect(published.providerKind, 'anthropic');
      expect(published.model, 'claude-custom');
      expect(published.braveApiKeyRef, 'brave');
      expect(published.searxngUrl, 'https://searx.example.com');
      expect(published.zaiApiKeyRef, 'zai');
      expect(published.redactSecrets, isFalse);
      expect(published.updatedAt, 99);
      expect(published.apiKeys, {
        'anthropic': 'sk-llm',
        'brave': 'sk-brave',
        'zai': 'sk-zai',
      });
      // The keys are gathered from the references, never by sweeping the
      // keystore — so nothing unreferenced can be swept up with them.
      final encoded = published.toJson().toString();
      expect(encoded, isNot(contains('tok')));
      expect(encoded, isNot(contains('vault')));
    });

    test('a locked keyring publishes nothing rather than a keyless copy',
        () async {
      // getApiKey answers null rather than throwing, so without a check the
      // round would put a *newer* keyless record over the keyed one on the
      // account — and never republish the keys, because by then the stamps
      // agree. A round skipped costs five minutes.
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = 'anthropic';
      await keys.putApiKey('anthropic', 'sk-llm');
      keystore.locked = true;

      expect(await sync.getAssistantSettings(), isNull);

      // And it catches up on its own once the keyring is back.
      keystore.locked = false;
      expect((await sync.getAssistantSettings())!.apiKeys,
          {'anthropic': 'sk-llm'});
    });

    test('a reference to a key that was never stored is not a locked keyring',
        () async {
      // Same null from getApiKey, opposite meaning: nothing is coming back
      // for this name, so waiting for it would stop publishing forever.
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = 'anthropic';
      settings.llmModel = 'claude-custom';
      settings.braveApiKeyRef = 'brave';
      settings.zaiApiKeyRef = 'zai';
      await keys.putApiKey('anthropic', 'sk-llm');

      final published = (await sync.getAssistantSettings())!;
      expect(published.apiKeys, {'anthropic': 'sk-llm'});
      expect(published.zaiApiKeyRef, 'zai');
    });
  });

  group('adopting', () {
    AssistantSettings arriving({
      String providerKind = 'openaiCompatible',
      String model = 'gpt-5',
      Map<String, String> apiKeys = const {'openai': 'sk-remote'},
    }) => AssistantSettings(
          providerKind: providerKind,
          baseUrl: 'https://api.openai.com/v1',
          model: model,
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
      settings.llmBaseUrl = 'https://prior.example.com';
      settings.llmModel = 'prior-model';
      settings.llmApiKeyRef = 'prior-ref';
      await sync.putAssistantSettings(
        arriving(providerKind: 'some-future-provider'),
      );
      // Asserted against the values that were configured, not against the
      // production defaults they happen to equal — a regression that wrote
      // some other constant matching a default would pass that.
      expect(settings.llmKind, LlmProviderKind.anthropic);
      expect(settings.llmBaseUrl, 'https://prior.example.com');
      expect(settings.llmModel, 'prior-model');
      expect(settings.llmApiKeyRef, 'prior-ref');
      // And nothing else is taken either. Adopting the half this build
      // understands would leave the account with two disagreeing
      // configurations and matching stamps to hide it.
      expect(settings.searxngUrl, isNull);
      expect(settings.zaiApiKeyRef, isNull);
      expect(settings.redactionEnabled, isTrue);
      expect(settings.assistantUpdatedAt, 0);
      expect(sync.applied, isFalse);
    });

    test('a locked keyring still adopts the configuration', () async {
      // The key is re-applied on a later round: the record is pulled again
      // every time, so a keyring that comes back catches up on its own.
      keystore.locked = true;
      await sync.putAssistantSettings(arriving());

      expect(settings.llmModel, 'gpt-5');
      expect(settings.assistantUpdatedAt, 500);
      expect(saves, 1);

      // The catch-up this test's comment claims, asserted: the record is
      // pulled again every round, and the key write is retried because the
      // stored value still differs from the one the record carries.
      keystore.locked = false;
      sync.applied = false;
      await sync.putAssistantSettings(arriving());
      expect(await keys.getApiKey('openai'), 'sk-remote');
      expect(sync.applied, isTrue);
    });

    test('a record with no keys leaves the local ones alone', () async {
      await keys.putApiKey('openai', 'sk-local');
      await sync.putAssistantSettings(arriving(apiKeys: const {}));
      expect(await keys.getApiKey('openai'), 'sk-local');
    });

    test('only the keys the configuration references are written', () async {
      // Publishing never sweeps the keystore; importing whatever names a
      // record happens to carry would give that care straight back.
      await sync.putAssistantSettings(arriving(apiKeys: const {
        'openai': 'sk-remote',
        'sync.token': 'stolen',
        'unrelated': 'sk-other',
      }));
      expect(await keys.getApiKey('openai'), 'sk-remote');
      expect(await keys.getApiKey('sync.token'), isNull);
      expect(await keys.getApiKey('unrelated'), isNull);
    });

    test('a round that changes nothing does not rebuild the provider',
        () async {
      // The coordinator hands this record over every round, so an
      // unconditional `applied` would rebuild the chat provider — and rewrite
      // the keystore — every five minutes for a configuration that has not
      // moved.
      await sync.putAssistantSettings(arriving());
      expect(sync.applied, isTrue);

      sync.applied = false;
      await sync.putAssistantSettings(arriving());
      expect(sync.applied, isFalse);

      // A rotated key is a change even though every field matches.
      await sync.putAssistantSettings(
        arriving(apiKeys: const {'openai': 'sk-rotated'}),
      );
      expect(sync.applied, isTrue);
      expect(await keys.getApiKey('openai'), 'sk-rotated');

      // And so is a field.
      sync.applied = false;
      await sync.putAssistantSettings(
        arriving(apiKeys: const {'openai': 'sk-rotated'}, model: 'gpt-5-mini'),
      );
      expect(sync.applied, isTrue);
    });
  });

  group('assistantSyncFingerprint', () {
    test('covers what travels and nothing else', () {
      // A Save with nothing changed must not stamp: the stamp is the whole of
      // the last-write-wins comparison, so a write with no edit behind it
      // would beat a configuration another device published in the meantime.
      final before = assistantSyncFingerprint(settings);
      expect(assistantSyncFingerprint(settings), before);

      // A device-local value is not part of the account-shaped half.
      settings.terminalFontSize = settings.terminalFontSize + 1;
      expect(assistantSyncFingerprint(settings), before);

      for (final change in <void Function()>[
        () => settings.llmKind = LlmProviderKind.openaiCompatible,
        () => settings.llmBaseUrl = 'https://api.openai.com/v1',
        () => settings.llmModel = 'gpt-5',
        () => settings.llmApiKeyRef = 'openai',
        () => settings.searxngUrl = 'https://searx.example.com',
        () => settings.braveApiKeyRef = 'brave',
        () => settings.zaiApiKeyRef = 'zai',
        () => settings.redactionEnabled = !settings.redactionEnabled,
      ]) {
        final was = assistantSyncFingerprint(settings);
        change();
        expect(assistantSyncFingerprint(settings), isNot(was));
      }
    });

    test('a separator inside a field cannot forge another one', () {
      // These are free text that can arrive from another device, so any
      // character a separator could be is one a field could contain. Length
      // prefixes are what make the encoding unambiguous.
      settings.llmBaseUrl = 'a\u0000b';
      settings.llmModel = 'c';
      final first = assistantSyncFingerprint(settings);
      settings.llmBaseUrl = 'a';
      settings.llmModel = 'b\u0000c';
      expect(assistantSyncFingerprint(settings), isNot(first));
    });

    test('a field ending where the next begins is still a change', () {
      // Joined rather than concatenated, so "ab" + "" and "a" + "b" cannot
      // read as the same configuration.
      settings.llmBaseUrl = 'ab';
      settings.llmModel = '';
      final joined = assistantSyncFingerprint(settings);
      settings.llmBaseUrl = 'a';
      settings.llmModel = 'b';
      expect(assistantSyncFingerprint(settings), isNot(joined));
    });
  });
}
