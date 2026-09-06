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

    test('a configuration with no key reference is not a locked keyring',
        () async {
      // A keyless local gateway — an Ollama or LM Studio endpoint that wants
      // no key at all. If an absent reference read as "the key might be
      // locked", this device would never publish, every incoming record would
      // look newer than nothing, and it would silently adopt whatever any
      // other device pushed.
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = '';
      settings.llmModel = 'keyless-model';
      settings.braveApiKeyRef = null;
      settings.zaiApiKeyRef = null;

      final published = await sync.getAssistantSettings();
      expect(published, isNotNull);
      expect(published!.model, 'keyless-model');
      expect(published.apiKeys, isEmpty);
    });
  });

  group('adopting', () {
    AssistantSettings arriving({
      String providerKind = 'openaiCompatible',
      String model = 'gpt-5',
      String llmApiKeyRef = 'openai',
      Map<String, String> apiKeys = const {'openai': 'sk-remote'},
    }) => AssistantSettings(
          providerKind: providerKind,
          baseUrl: 'https://api.openai.com/v1',
          model: model,
          llmApiKeyRef: llmApiKeyRef,
          searxngUrl: 'https://searx.example.com',
          braveApiKeyRef: 'brave',
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
      // Brave travels too, and is fingerprinted — but nothing asserted it
      // arrived, so an import that dropped it would have lost every adopting
      // device its Brave key with the suite still green.
      expect(settings.braveApiKeyRef, 'brave');
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
      // Non-default priors for these too. They were asserted `isNull`, which
      // is also their default — so a partial apply that reset unreferenced
      // fields would have wiped a user's configured search settings on every
      // round and passed, which is exactly what the comment below claims is
      // covered.
      settings.searxngUrl = 'https://prior-searx.example.com';
      settings.braveApiKeyRef = 'prior-brave';
      settings.zaiApiKeyRef = 'prior-zai';
      // Set rather than left at the shipped default, which is the same value:
      // an apply that wrote the default here would otherwise pass.
      settings.redactionEnabled = true;
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
      expect(settings.searxngUrl, 'https://prior-searx.example.com');
      expect(settings.braveApiKeyRef, 'prior-brave');
      expect(settings.zaiApiKeyRef, 'prior-zai');
      // `redactionEnabled` keeps its prior of `true` against the record's
      // `false`, so this one detects adoption without needing a fixture
      // change — setting the prior to `false` would blind it.
      expect(settings.redactionEnabled, isTrue);
      expect(settings.assistantUpdatedAt, 0);
      expect(sync.applied, isFalse);
    });

    test('a key this device failed to store suspends publishing', () async {
      // The adoption keeps the configuration and its stamp when the keyring
      // is locked, retrying the key later. But `collectLocal` runs before
      // `applyToStores`, so the first round after the keyring recovers would
      // republish that same stamp minus the missing key — and an equal stamp
      // is broken by device id, so the keyless copy can evict the keyed one
      // it came from.
      keystore.locked = true;
      await sync.putAssistantSettings(arriving());
      expect(settings.assistantUpdatedAt, 500,
          reason: 'the configuration is still adopted');

      // Keyring back, key still missing: this device must not publish yet.
      keystore.locked = false;
      expect(await sync.getAssistantSettings(), isNull);

      // Once the retry lands, publishing resumes.
      await sync.putAssistantSettings(arriving());
      expect(await keys.getApiKey('openai'), 'sk-remote');
      expect((await sync.getAssistantSettings())!.apiKeys,
          containsPair('openai', 'sk-remote'));
    });

    test('the suspension survives a restart', () async {
      // The set naming those keys lives in the settings file, not in this
      // object: the app can be stopped between the failed write and the round
      // that retries it, and a set that starts empty on the next launch reads
      // "reference set, key absent, keystore fine" as the supported
      // never-stored state — and publishes the keyless copy the guard exists
      // to hold back.
      keystore.locked = true;
      await sync.putAssistantSettings(arriving());
      keystore.locked = false;

      // A second adapter over the same persisted settings is what a restart
      // looks like from here: same keystore, same settings.json, new object.
      final afterRestart = AssistantSettingsSync(
        settings: AppSettings.fromJson(settings.toJson()),
        masterKeys: keys,
        saveSettings: () async {},
      );
      expect(await afterRestart.getAssistantSettings(), isNull);
    });

    test('a key that reads back correct clears its suspension', () async {
      // Whatever put the key there — a retry, another screen, the user — the
      // keystore has just contradicted the record of the failed write. Going
      // on blocking publication on it would be blocking on stale evidence,
      // and the evidence is persisted now, so it would not clear itself.
      keystore.locked = true;
      await sync.putAssistantSettings(arriving());
      keystore.locked = false;
      await keys.putApiKey('openai', 'sk-remote');
      expect(settings.unwrittenAssistantKeyRefs, contains('openai'));

      // Same value as the record carries, so the write is skipped entirely.
      await sync.putAssistantSettings(arriving());
      expect(settings.unwrittenAssistantKeyRefs, isEmpty);
      expect(await sync.getAssistantSettings(), isNotNull);
    });

    test('a name the configuration stops referencing is dropped', () async {
      // The set is persisted, so an entry nothing will ever consult again
      // would sit in the settings file for the life of the install.
      keystore.locked = true;
      await sync.putAssistantSettings(arriving());
      keystore.locked = false;
      expect(settings.unwrittenAssistantKeyRefs, contains('openai'));

      await sync.putAssistantSettings(
        arriving(llmApiKeyRef: 'elsewhere', apiKeys: const {}),
      );
      expect(settings.unwrittenAssistantKeyRefs, isEmpty);
    });

    test('a keyless record is adopted without forgetting a stored key',
        () async {
      // The mirror of the publishing group's keyless case, which had none:
      // another device switching to a local gateway that wants no key. The
      // reference is dropped, and the key it stopped naming stays — a
      // configuration that no longer names a key is not an instruction to
      // delete it.
      await keys.putApiKey('openai', 'sk-local');
      await sync.putAssistantSettings(arriving(
        model: 'keyless-model',
        llmApiKeyRef: '',
        apiKeys: const {},
      ));

      expect(settings.llmApiKeyRef, '');
      expect(settings.llmModel, 'keyless-model');
      expect(settings.assistantUpdatedAt, 500);
      expect(sync.applied, isTrue);
      expect(await keys.getApiKey('openai'), 'sk-local');
    });

    test('a skipped record clears the applied flag the last one set',
        () async {
      // `applied` is a per-round answer and the coordinator hands a record
      // over every round. A record adopted last round leaving `true` standing
      // would rebuild the chat provider for one this round refused.
      await sync.putAssistantSettings(arriving());
      expect(sync.applied, isTrue);

      await sync.putAssistantSettings(
        arriving(providerKind: 'some-future-provider'),
      );
      expect(sync.applied, isFalse);
    });

    test('a stamp that moves alone saves but rebuilds nothing', () async {
      // Two devices making the same edit, or a revert on the publishing one:
      // every field the chat provider reads is already what the record says.
      // The stamp still has to be persisted or the coordinator re-delivers
      // the record forever — but rebuilding the provider would interrupt a
      // live session to arrive at the same client.
      await sync.putAssistantSettings(arriving());
      final savesAfterAdopt = saves;

      await sync.putAssistantSettings(arriving().copyWith(updatedAt: 900));
      expect(settings.assistantUpdatedAt, 900);
      expect(saves, savesAfterAdopt + 1, reason: 'the stamp must be persisted');
      expect(sync.applied, isFalse, reason: 'nothing the provider reads moved');
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
        // The search keys are referenced too, and only the LLM key was ever
        // asserted to arrive — an import that wrote that one and dropped
        // these would leave every adopting device with search references it
        // holds no keys for, and this suite green.
        'brave': 'sk-brave',
        'zai': 'sk-zai',
        'sync.token': 'stolen',
        'unrelated': 'sk-other',
      }));
      expect(await keys.getApiKey('openai'), 'sk-remote');
      expect(await keys.getApiKey('brave'), 'sk-brave');
      expect(await keys.getApiKey('zai'), 'sk-zai');
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

      await sync.putAssistantSettings(arriving());
      expect(sync.applied, isFalse);

      // A rotated key is a change even though every field matches.
      await sync.putAssistantSettings(
        arriving(apiKeys: const {'openai': 'sk-rotated'}),
      );
      expect(sync.applied, isTrue);
      expect(await keys.getApiKey('openai'), 'sk-rotated');

      // And so is a field.
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
      // Nor is the stamp itself, which is the one *travelling* field that
      // must stay out: if it leaked in, a no-edit Save after an adoption
      // would read as changed, stamp `now`, and beat a configuration another
      // device published in the meantime — the exact bug this whole
      // fingerprint exists to prevent.
      settings.assistantUpdatedAt = settings.assistantUpdatedAt + 1;
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
