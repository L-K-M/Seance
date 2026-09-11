import 'dart:convert';

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

  /// Runs on the next read and then clears itself, so a test can land an edit
  /// inside the await window a key lookup opens.
  void Function()? onNextRead;

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
    // Consumed before the locked branch can throw: left armed, an edit
    // placed at one read would fire at the first *unlocked* one instead —
    // a settings mutation landing somewhere no test asked for it.
    final hook = onNextRead;
    onNextRead = null;
    if (locked) {
      // Consumed above so it cannot fire at some later, unrelated read — but
      // dropping it silently is the same hazard pointing the other way: a
      // test that armed an edit would observe the pre-edit world and pass for
      // the wrong reason.
      if (hook != null) {
        throw StateError('onNextRead was armed for a read on a locked keyring');
      }
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
    hook?.call();
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
      // Off the defaults, or an encoder that always wrote the default
      // provider — or dropped the endpoint — would pass.
      settings.llmKind = LlmProviderKind.openaiCompatible;
      settings.llmBaseUrl = 'https://api.openai.com/v1';
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
      // Both through the production API, so each canary lands wherever the
      // manager actually puts it rather than where this test remembers: a
      // storage key renamed in `secure_master_key.dart` would otherwise leave
      // this one guarding an address nothing writes to any more, green and
      // disarmed.
      await keys.putApiKey('sync.token', 'leak-canary-sync-token');
      final masterKey = base64.encode(List.filled(32, 7));
      await keys.setKeystoreKey(List.filled(32, 7));

      final published = (await sync.getAssistantSettings())!;

      expect(published.providerKind, 'openaiCompatible');
      expect(published.baseUrl, 'https://api.openai.com/v1');
      expect(published.model, 'claude-custom');
      expect(published.braveApiKeyRef, 'brave');
      // The one ref the chat provider actually resolves, and the one the
      // `apiKeys` assertion below cannot stand in for: the keys are gathered
      // from the local refs before the record is built, so an encoder that
      // dropped this field would still publish `anthropic: sk-llm` and every
      // adopting device would treat the record as keyless.
      expect(published.llmApiKeyRef, 'anthropic');
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
      expect(encoded, isNot(contains('leak-canary-sync-token')));
      expect(encoded, isNot(contains(masterKey)));
      // And the same claim without naming an encoding: whatever
      // `setKeystoreKey` writes, and whatever any later entry writes, none of
      // it may appear in the record except the three keys the configuration
      // actually references. Pinned to the base64 form alone, this canary
      // would go green and disarmed the day the master key is stored as hex
      // or sealed at rest.
      const referencedByTheConfiguration = {'sk-llm', 'sk-brave', 'sk-zai'};
      for (final stored in keystore.entries.values) {
        if (referencedByTheConfiguration.contains(stored)) continue;
        expect(encoded, isNot(contains(stored)));
      }
    });

    test('an edit landing mid-collection cannot tear the published record',
        () async {
      // Assistant edits stamp `settings` from the UI path without taking the
      // mutation queue, so one can land in any of the keystore reads this
      // method makes. Read back afterwards, the record would carry the new
      // stamp and the new refs beside keys gathered for the old ones — a
      // record naming a key it does not carry, at a stamp that outranks the
      // keyed one it replaces.
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = 'anthropic';
      await keys.putApiKey('anthropic', 'sk-old');
      keystore.onNextRead = () {
        settings.llmApiKeyRef = 'openai';
        settings.assistantUpdatedAt = 500;
      };

      final published = (await sync.getAssistantSettings())!;

      // The invariant, stated as itself: a record's refs and its keys have to
      // describe the same moment.
      expect(published.apiKeys, contains(published.llmApiKeyRef));
      // And which moment it is: the one the collection started from, whole.
      // The edit publishes on the next round, with its own keys.
      expect(published.llmApiKeyRef, 'anthropic');
      expect(published.updatedAt, 99);
      // And the edit did land: if the keystore read this hook hangs on ever
      // goes away — a cache in `MasterKeyManager`, say — every assertion above
      // would pass with the hook never firing.
      expect(settings.llmApiKeyRef, 'openai');
      expect(settings.assistantUpdatedAt, 500);
    });

    test('the sync token is never a key reference, published or adopted',
        () async {
      // It shares the API-key namespace with the assistant's keys, and a
      // record is exactly as careful as the device that wrote it: one naming
      // it as a ref would publish this device's token, or overwrite it.
      await keys.putApiKey('sync.token', 'tok');
      // Configured rather than left at the defaults the assertions below
      // happen to equal, like every other prior in this file: a default
      // changed in `AppSettings` would otherwise fail this test pointing at
      // the defaults rather than at the refusal it is about.
      settings.llmKind = LlmProviderKind.anthropic;
      settings.llmBaseUrl = 'https://api.anthropic.com';
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = 'sync.token';
      // Withheld rather than published without the key: a record naming the
      // token as a ref is refused whole by every peer, so publishing one
      // would park a record on the account that nothing adopts while this
      // device's configuration silently never propagated.
      expect(await sync.getAssistantSettings(), isNull);
      settings.llmApiKeyRef = 'anthropic';

      await sync.putAssistantSettings(AssistantSettings(
        providerKind: 'openaiCompatible',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5',
        llmApiKeyRef: 'sync.token',
        redactSecrets: true,
        apiKeys: const {'sync.token': 'stolen'},
        updatedAt: 500,
      ));
      expect(await keys.getApiKey('sync.token'), 'tok');
      // Refused whole, not adopted minus the key: an adopted ref of
      // `sync.token` would have the chat provider resolve this device's
      // token as its API key and send it to whatever endpoint the record
      // named.
      expect(sync.applied, isFalse);
      expect(settings.llmKind, LlmProviderKind.anthropic);
      // The one value this test configured away from the production default,
      // so a partial apply that wrote the record's ref and skipped the rest
      // is caught here rather than passing on the fields it happened to
      // leave alone.
      expect(settings.llmApiKeyRef, 'anthropic');
      expect(settings.llmBaseUrl, 'https://api.anthropic.com');
      expect(settings.assistantUpdatedAt, 99);

      // Any of the three references, not only the LLM's. The Brave one too:
      // it and Z.AI are symmetric by design, which is exactly what a
      // copy-paste slip in the guard would quietly break.
      await sync.putAssistantSettings(const AssistantSettings(
        providerKind: 'openaiCompatible',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5',
        llmApiKeyRef: 'openai',
        braveApiKeyRef: 'sync.token',
        redactSecrets: true,
        apiKeys: {},
        updatedAt: 500,
      ));
      expect(sync.applied, isFalse);
      expect(settings.braveApiKeyRef, isNull);
      expect(settings.llmApiKeyRef, 'anthropic');

      await sync.putAssistantSettings(const AssistantSettings(
        providerKind: 'openaiCompatible',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5',
        llmApiKeyRef: 'openai',
        zaiApiKeyRef: 'sync.token',
        redactSecrets: true,
        apiKeys: {},
        updatedAt: 500,
      ));
      expect(sync.applied, isFalse);
      expect(settings.zaiApiKeyRef, isNull);
      expect(settings.llmApiKeyRef, 'anthropic');
      expect(settings.assistantUpdatedAt, 99);
    });

    test('a key this device held and lost withholds the round', () async {
      // `getApiKey` answers null for a reference that never had a key *and*
      // for one the keystore has lost. Published keyless, the second puts a
      // record naming a key it does not carry on the account under the stamp
      // the keyed one has, where the tiebreak can evict the copy that still
      // has it — and nothing republishes, because the stamps agree.
      settings.assistantUpdatedAt = 99;
      // Named rather than left to the shipped default: this test is about
      // one reference, and reading which one out of `AppSettings`'s defaults
      // makes a change there fail here with no hint why.
      settings.llmApiKeyRef = 'anthropic';
      await keys.putApiKey('anthropic', 'sk-llm');
      expect((await sync.getAssistantSettings())!.apiKeys,
          containsPair('anthropic', 'sk-llm'));
      expect(settings.heldAssistantKeyRefs, contains('anthropic'));

      // The wipe: the entry is gone, the keystore answers, settings.json is
      // untouched.
      keystore.entries.clear();
      expect(await sync.getAssistantSettings(), isNull);

      // A reference that never held anything still publishes — the Z.AI
      // switch on with the field blank is a real configuration.
      settings.llmApiKeyRef = 'never-stored';
      expect(await sync.getAssistantSettings(), isNotNull);

      // And re-entering the key resumes publishing for the original ref.
      settings.llmApiKeyRef = 'anthropic';
      await keys.putApiKey('anthropic', 'sk-again');
      expect((await sync.getAssistantSettings())!.apiKeys,
          containsPair('anthropic', 'sk-again'));
    });

    test('a key recorded only by publishing survives a restart', () async {
      // The wipe guard reads `heldAssistantKeyRefs` out of `settings.json`,
      // and the collect path is the only thing that records a key entered in
      // Settings — this device never adopted it, so the apply path never saw
      // it. Recorded in memory alone, the next launch reads "reference set,
      // key absent, keystore fine" as the never-stored state and publishes
      // the keyless copy the guard exists to hold back, under the stamp the
      // keyed record already has.
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = 'anthropic';
      // Captured around the production call rather than spelled out, for the
      // reason the leak canary above gives: a storage key renamed in
      // `secure_master_key.dart` would leave a literal here removing an
      // address nothing writes to, and the wipe this test simulates would
      // quietly stop happening.
      final before = keystore.entries.keys.toSet();
      await keys.putApiKey('anthropic', 'sk-llm');
      final written = keystore.entries.keys.toSet().difference(before);
      expect(written, hasLength(1));

      // Asserted as a *save*, not by re-reading the object: the set is on the
      // object either way, so serializing this instance cannot tell a
      // recorded key from a persisted one. What a restart actually reads is
      // the last thing written to disk.
      expect((await sync.getAssistantSettings())!.apiKeys,
          containsPair('anthropic', 'sk-llm'));
      expect(settings.heldAssistantKeyRefs, contains('anthropic'));
      expect(saves, 1, reason: 'a newly held key has to reach the disk');

      // Once, though: `add` answers false from here on, and a save per round
      // for a configuration that has not moved is the churn every other
      // guard in this class is written against.
      await sync.getAssistantSettings();
      expect(saves, 1);

      // And the guard that set exists for, over the settings as persisted.
      final afterRestart = AssistantSettingsSync(
        settings: AppSettings.fromJson(settings.toJson()),
        masterKeys: keys,
        saveSettings: () async {},
      );
      keystore.entries.removeWhere((key, _) => written.contains(key));
      expect(await afterRestart.getAssistantSettings(), isNull);
    });

    test('a flush that fails does not leave a name half-remembered', () async {
      // `_held.add` answers false from the second call on, so a save that
      // throws leaves the name in memory, off disk, and with nothing left to
      // raise the flush again. The next launch reads it as never held and the
      // wipe guard goes silent for exactly the key it exists to protect.
      var failing = true;
      var flushes = 0;
      final flaky = AssistantSettingsSync(
        settings: settings,
        masterKeys: keys,
        saveSettings: () async {
          if (failing) throw StateError('the settings file is unwritable');
          flushes++;
        },
      );
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = 'anthropic';
      await keys.putApiKey('anthropic', 'sk-llm');

      // The round still publishes — the key was read, and a settings file
      // that will not open is not a reason to withhold the record.
      expect(await flaky.getAssistantSettings(), isNotNull);
      expect(settings.heldAssistantKeyRefs, isEmpty,
          reason: 'a name that never reached disk must not read as held');

      failing = false;
      expect(await flaky.getAssistantSettings(), isNotNull);
      expect(settings.heldAssistantKeyRefs, contains('anthropic'));
      expect(flushes, 1, reason: 'the retry is what persists it');
    });

    test('a key that reads back stops being a known-failed write', () async {
      // `_unwritten` records a reference this device adopted and failed to
      // store. The apply side drops a name when its own retry lands — but the
      // other recovery never goes through the apply side at all: the user
      // re-enters the key in Settings under the same reference, or the
      // keystore comes back, and the collect path reads it. That path added
      // to `_held` and never removed from `_unwritten`, so the name stayed
      // recorded as dropped for a key this device demonstrably holds, in
      // `settings.json`, for good.
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = 'anthropic';
      settings.unwrittenAssistantKeyRefs.add('anthropic');
      // The getter could return a copy, in which case the add above is a
      // no-op and the assertion below would pass having tested nothing.
      expect(settings.unwrittenAssistantKeyRefs, contains('anthropic'));
      await keys.putApiKey('anthropic', 'sk-llm');

      expect(await sync.getAssistantSettings(), isNotNull,
          reason: 'the key reads, so nothing withholds the round');
      expect(settings.unwrittenAssistantKeyRefs, isEmpty);
      // And on disk, not only in memory — the whole reason the set lives in
      // `settings.json` is to survive a launch.
      expect(
          AppSettings.fromJson(settings.toJson()).unwrittenAssistantKeyRefs,
          isEmpty);
    });

    test('a key read before an abort still reaches the disk', () async {
      // The flush lived after the loop, and all three of its guards left by
      // `return` — so a name recorded as held before a later ref aborted the
      // round stayed in memory only. `add` answers false from the next round
      // on, so nothing raised the flag again: the name never reached disk
      // until some unrelated save happened by, and a restart in between read
      // it back as never held.
      settings.assistantUpdatedAt = 99;
      settings.llmApiKeyRef = 'anthropic';
      settings.braveApiKeyRef = 'brave';
      // The second reference is one this device adopted and failed to store,
      // which is the abort that fires after the first has been read.
      settings.unwrittenAssistantKeyRefs.add('brave');
      await keys.putApiKey('anthropic', 'sk-llm');

      expect(await sync.getAssistantSettings(), isNull,
          reason: 'a ref this device failed to store withholds the round');
      expect(saves, 1,
          reason: 'the name read before the abort has to reach the disk');
      expect(
          AppSettings.fromJson(settings.toJson()).heldAssistantKeyRefs,
          contains('anthropic'),
          reason: 'and be there for the next launch to read');
    });

    test('clearing a reference clears the history that blocked it', () async {
      // The documented way to take a key off the account — clear the
      // reference and save while opted in — has to keep publishing, so the
      // held set is pruned to what the configuration still names.
      settings.assistantUpdatedAt = 99;
      settings.zaiApiKeyRef = 'zai';
      await keys.putApiKey('anthropic', 'sk-llm');
      await keys.putApiKey('zai', 'sk-zai');
      await sync.getAssistantSettings();
      expect(settings.heldAssistantKeyRefs, contains('zai'));

      // The prune happens where `_unwritten`'s does: on the adopt path, which
      // is where the configuration's references are settled for the round.
      await sync.putAssistantSettings(const AssistantSettings(
        providerKind: 'anthropic',
        baseUrl: 'https://api.anthropic.com',
        model: 'claude-haiku-4-5-20251001',
        llmApiKeyRef: 'anthropic',
        redactSecrets: true,
        apiKeys: {},
        updatedAt: 500,
      ));
      expect(settings.zaiApiKeyRef, isNull,
          reason: 'the adopted record names no Z.AI key');
      expect(settings.heldAssistantKeyRefs, isNot(contains('zai')));
      // And publishing is unblocked again, which is the point of the prune.
      expect(await sync.getAssistantSettings(), isNotNull);
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
      // Both of the never-stored refs, not only the last one the loop sees: a
      // decision taken per configuration rather than per name would keep this
      // green while dropping every reference but one.
      expect(published.braveApiKeyRef, 'brave');
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
      // And nothing invented for the refs the record names without carrying a
      // key: the mirror of the publish side's no-sweep canary. An apply path
      // that copied the LLM key to every named ref would plant wrong material
      // in the keystore with this suite still green.
      expect(await keys.getApiKey('brave'), isNull);
      expect(await keys.getApiKey('zai'), isNull);
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
      // "Refused whole" includes the keystore. Validation runs ahead of the
      // key loop, and it has to: a refusal that wrote the record's keys first
      // would leave secrets from a configuration this build declined to adopt
      // sitting under names nothing here references, which nothing prunes and
      // nothing reads.
      expect(await keys.getApiKey('openai'), isNull);
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
      var restartSaves = 0;
      final restarted = AppSettings.fromJson(settings.toJson());
      final afterRestart = AssistantSettingsSync(
        settings: restarted,
        masterKeys: keys,
        saveSettings: () async => restartSaves++,
      );
      expect(await afterRestart.getAssistantSettings(), isNull);
      // Counted, not ignored: every name this round consults is already on
      // disk, so a save here would be one per withheld round — the churn the
      // rest of this group is written against — and the no-op closure this
      // instance used to take accepted any number of them.
      expect(restartSaves, 0);

      // Surviving the restart is half of it. The other half is clearing on
      // the restarted object: the set is read back from disk, and a retry
      // that never removed from it would leave this device permanently
      // unpublished one restart after a single locked round.
      await afterRestart.putAssistantSettings(arriving());
      expect(restarted.unwrittenAssistantKeyRefs, isEmpty);
      expect(await afterRestart.getAssistantSettings(), isNotNull);
    });

    test('a key the record only confirms is recorded as held', () async {
      // The write branch records what it writes, but this is the other way a
      // device comes to hold a key it must not later publish keyless: the
      // user typed it in Settings under a name the configuration did not yet
      // reference, and the arriving record is the first thing to name it.
      // The value already matches, so nothing is written — and without a
      // record of it here, nothing on this device knows it was ever held.
      settings.llmApiKeyRef = 'somewhere-else';
      await keys.putApiKey('openai', 'sk-remote');
      expect(settings.heldAssistantKeyRefs, isNot(contains('openai')));

      await sync.putAssistantSettings(arriving());

      expect(settings.heldAssistantKeyRefs, contains('openai'));
      // Which is what the wipe guard then has to work from.
      keystore.entries.remove('seance.apikey.openai');
      expect(await sync.getAssistantSettings(), isNull);
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

      final savesAfterAdopt = saves;
      // Strictly newer than the record just adopted. At the shared default
      // stamp a build that refused equal stamps — which this one does not,
      // deliberately, so two devices can converge — would produce the same
      // `applied` false and the same absent save, and this test would pass
      // for a policy it is not about.
      await sync.putAssistantSettings(
        arriving(providerKind: 'some-future-provider')
            .copyWith(updatedAt: 600),
      );
      expect(sync.applied, isFalse);
      // And nothing of it reached disk, like the refusal test asserts: the
      // coordinator hands this record over every round, so a skip that saved
      // would burn a settings write every five minutes forever.
      expect(saves, savesAfterAdopt);
    });

    test('a record older than the stamp this device holds is refused',
        () async {
      // The coordinator compares stamps as well, but its comparison and this
      // write are an await apart, and an assistant edit does not take the
      // mutation queue — so an edit landing in that window would be
      // overwritten here and the loss published on the next round.
      await sync.putAssistantSettings(arriving());
      final savesAfterAdopt = saves;

      await sync.putAssistantSettings(
        arriving(model: 'older').copyWith(updatedAt: 100),
      );

      expect(settings.llmModel, 'gpt-5');
      expect(settings.assistantUpdatedAt, 500);
      expect(saves, savesAfterAdopt);
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

    test('applied reports what the round did to settings, not to the disk',
        () async {
      // `applied` is a per-round answer the caller rebuilds the chat provider
      // on. It is cleared on entry, so an exception escaping mid-apply can
      // never leave the previous round's `true` standing — and it is set the
      // moment `settings` changes, because `settings` is what the running app
      // reads. A failed *save* leaves the adopted configuration in memory and
      // on screen; a provider left unrebuilt then serves the old model and key
      // until a restart, and no later round fixes it: the record re-delivers
      // at the same stamp with the same fingerprint, so nothing changes again.
      //
      // One instance across all three rounds: a fresh one starts false and
      // could not tell a cleared flag from an untouched one.
      var failSave = false;
      final flaky = AssistantSettingsSync(
        settings: settings,
        masterKeys: keys,
        saveSettings: () async {
          if (failSave) throw StateError('disk full');
        },
      );
      await flaky.putAssistantSettings(arriving());
      expect(flaky.applied, isTrue);

      failSave = true;
      await expectLater(
        flaky.putAssistantSettings(arriving(model: 'gpt-6')),
        throwsA(isA<StateError>()),
      );
      expect(flaky.applied, isTrue,
          reason: 'the configuration the app is running on did change');
      expect(settings.llmModel, 'gpt-6');

      // And the clearing still works, which the assertion above no longer
      // shows: a round that returns before touching `settings` reports false
      // even with a `true` standing from the round before it.
      await flaky.putAssistantSettings(arriving(model: 'gpt-7')
          .copyWith(updatedAt: settings.assistantUpdatedAt - 1));
      expect(flaky.applied, isFalse);
      expect(settings.llmModel, 'gpt-6');
    });

    test('a locked keyring still adopts the configuration', () async {
      // The key is re-applied on a later round: the record is pulled again
      // every time, so a keyring that comes back catches up on its own.
      keystore.locked = true;
      await sync.putAssistantSettings(arriving());

      // The flag the caller rebuilds the chat provider on, in the one round
      // where the keystore failed: settings changed, so it is true. Tied to
      // the key write instead, a locked device would go on answering with the
      // old model until the keyring came back — and the round that brings the
      // key does rebuild, so nothing later would notice.
      expect(sync.applied, isTrue);
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
      //
      // Stored first, so the assertion below can tell "never imported" from
      // "deleted": an adoption that swept the entries its record does not
      // mention would take keys the user keeps outside the assistant
      // configuration with it, and read as absent either way.
      await keys.putApiKey('unrelated', 'sk-local-only');
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
      expect(await keys.getApiKey('unrelated'), 'sk-local-only',
          reason: 'neither written from the record nor swept away');
    });

    test('a round that changes nothing does not rebuild the provider',
        () async {
      // The coordinator hands this record over every round, so an
      // unconditional `applied` would rebuild the chat provider — and rewrite
      // the keystore — every five minutes for a configuration that has not
      // moved.
      await sync.putAssistantSettings(arriving());
      expect(sync.applied, isTrue);
      final savesAfterAdopt = saves;

      await sync.putAssistantSettings(arriving());
      expect(sync.applied, isFalse);
      // The comment above names the keystore rewrite as the other half of
      // this hazard: a round that re-saved every five minutes would keep the
      // test green on `applied` alone.
      expect(saves, savesAfterAdopt);

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
      final savesAfterFieldChange = saves;

      // And the *new* baseline settles too: a comparison that never reset
      // after a field-level diff would leave every later round applying.
      await sync.putAssistantSettings(
        arriving(apiKeys: const {'openai': 'sk-rotated'}, model: 'gpt-5-mini'),
      );
      expect(sync.applied, isFalse);
      // Both halves again, at the later baseline: one expression answers for
      // the flag and the save today, and splitting them is exactly the change
      // that would leave a settled configuration rewriting the disk while
      // `applied` stayed honest.
      expect(saves, savesAfterFieldChange);
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
      // Nor is the sync layer's own bookkeeping: a pending key retry landing
      // would otherwise make an unchanged Save read as an edit and stamp.
      settings.unwrittenAssistantKeyRefs.add('openai');
      // Its sibling is the same hazard from the other side: a key the record
      // only *confirms* this device holds is recorded on an ordinary round,
      // so folding that set in would make the next Save read as an edit and
      // stamp `now` over a configuration another device published meanwhile.
      // Measured: with it folded in and this line absent, the whole suite
      // stays green.
      settings.heldAssistantKeyRefs.add('confirmed-ref');
      // The getters could return copies, and then the adds above would be
      // no-ops and the assertions below would pass having tested nothing.
      expect(settings.unwrittenAssistantKeyRefs, contains('openai'));
      expect(settings.heldAssistantKeyRefs, contains('confirmed-ref'));
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
      // Every separator a naive `join` might pick, not just the one this test
      // happened to choose: length-prefixing defeats all of them, and a
      // refactor to `join('|')` would pass a \u0000-only probe.
      for (final sep in ['\u0000', '\u0001', '\u001f', '|', ':', '\n', ' ']) {
        settings.llmBaseUrl = 'a${sep}b';
        settings.llmModel = 'c';
        final first = assistantSyncFingerprint(settings);
        settings.llmBaseUrl = 'a';
        settings.llmModel = 'b${sep}c';
        expect(
          assistantSyncFingerprint(settings),
          isNot(first),
          reason: 'U+${sep.codeUnitAt(0).toRadixString(16).padLeft(4, '0')} '
              'as a separator would forge a collision',
        );
      }
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
