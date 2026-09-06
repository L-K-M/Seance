import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

AssistantSettings settings({
  Map<String, String> apiKeys = const {},
  String? searxngUrl = 'https://searx.example.com',
}) => AssistantSettings(
      providerKind: 'anthropic',
      baseUrl: 'https://api.anthropic.com',
      model: 'claude-haiku-4-5-20251001',
      llmApiKeyRef: 'anthropic',
      searxngUrl: searxngUrl,
      zaiApiKeyRef: 'zai',
      redactSecrets: false,
      apiKeys: apiKeys,
      updatedAt: 42,
    );

void main() {
  test('round-trips, keys included', () {
    final original = settings(apiKeys: const {'anthropic': 'sk-1', 'zai': 'z'});
    final back = AssistantSettings.fromJson(original.toJson());

    expect(back.toJson(), equals(original.toJson()));
    expect(back.providerKind, 'anthropic');
    expect(back.model, 'claude-haiku-4-5-20251001');
    expect(back.redactSecrets, isFalse);
    expect(back.apiKeys, {'anthropic': 'sk-1', 'zai': 'z'});
    expect(back.updatedAt, 42);
  });

  test('an empty key map is omitted rather than serialized', () {
    // A configuration that references no keys — a local gateway that wants
    // none — must produce the same record as one whose keys were dropped,
    // rather than one carrying an empty map that reads as a difference.
    final withKeys = settings(apiKeys: const {'anthropic': 'sk-1'});
    expect(withKeys.toJson().containsKey('apiKeys'), isTrue);
    expect(withKeys.copyWith(apiKeys: const {}).toJson(), settings().toJson());
    expect(settings().toJson().containsKey('apiKeys'), isFalse);
  });

  test('a cleared field arrives cleared, not as an empty endpoint', () {
    final json = settings().toJson()..['searxngUrl'] = '';
    expect(AssistantSettings.fromJson(json).searxngUrl, isNull);
    expect(settings(searxngUrl: null).toJson().containsKey('searxngUrl'),
        isFalse);
  });

  test('redaction defaults on when a writer had no such field', () {
    // The safe reading of "an older writer" is the default the app ships with.
    final legacy = settings().toJson()..remove('redactSecrets');
    expect(AssistantSettings.fromJson(legacy).redactSecrets, isTrue);
  });

  test('the record id is a singleton and prefixed', () {
    // Prefixed because applyToStores reads a bare-id tombstone as a server
    // deletion; constant because that is what makes two devices converge onto
    // one row instead of two.
    expect(AssistantSettings.recordId, contains(':'));
    expect(AssistantSettings.recordId, 'assistant:settings');
  });

  test('toString counts the keys rather than printing them', () {
    final text = settings(apiKeys: const {'anthropic': 'sk-secret'}).toString();
    expect(text, isNot(contains('sk-secret')));
    expect(text, contains('1 redacted'));
  });

  test('a malformed keys map reads as no keys', () {
    for (final bad in [42, 'string', {'a': 1}]) {
      expect(
        AssistantSettings.fromJson(settings().toJson()..['apiKeys'] = bad)
            .apiKeys,
        isEmpty,
        reason: 'apiKeys=$bad should read as no keys',
      );
    }
  });

  test('a degenerate key entry is dropped rather than adopted', () {
    // The apply path writes exactly the keys a record carries, so a blank
    // value would overwrite a working key with nothing on every device that
    // adopted the record — the failure "an absent key means look locally"
    // exists to prevent, arriving as a present key instead. A blank name
    // addresses no keystore entry at all — and blank is whitespace too, as
    // it is for every other field of this record.
    final decoded = AssistantSettings.fromJson(
      settings().toJson()
        ..['apiKeys'] = {
          'anthropic': '',
          '': 'sk-1',
          ' ': 'sk-2',
          'brave': '  ',
          'zai': 'z',
        },
    );
    expect(decoded.apiKeys, {'zai': 'z'});
  });

  test('a degenerate key entry is not written either', () {
    // The reader drops it; a writer that kept it would produce a record its
    // own reader disagrees with.
    final json = settings(
      apiKeys: const {'anthropic': '', '': 'x', ' ': 'y', 'brave': ' ', 'zai': 'z'},
    ).toJson();
    expect(json['apiKeys'], {'zai': 'z'});
    expect(settings(apiKeys: const {'anthropic': ''}).toJson(),
        isNot(contains('apiKeys')));
  });

  test('a blank LLM key reference reads and writes as empty', () {
    // Like its optional siblings: a stray space is not a keystore entry.
    expect(
      AssistantSettings.fromJson(settings().toJson()..['llmApiKeyRef'] = ' ')
          .llmApiKeyRef,
      '',
    );
    final blank = AssistantSettings.fromJson(
      settings().toJson()..['llmApiKeyRef'] = '   ',
    );
    expect(blank.toJson()['llmApiKeyRef'], '');
    expect(AssistantSettings.fromJson(blank.toJson()).toJson(), blank.toJson());
  });

  test('a blank optional field is written as unset, not as blank', () {
    // fromJson reads a blank as "not set", so writing one out would be a
    // field the writer calls set and every reader — this class re-reading its
    // own record included — calls unset. Whitespace is blank: clearing a text
    // box down to a stray space is clearing it.
    for (final blank in ['', '   ']) {
      final json = settings(searxngUrl: blank).toJson();
      expect(json.containsKey('searxngUrl'), isFalse,
          reason: 'searxngUrl=${json['searxngUrl']} should be omitted');
      expect(AssistantSettings.fromJson(json).searxngUrl, isNull);
    }
  });

  test('a wrong-typed field decodes to its default rather than throwing', () {
    // Every other field here is deliberately tolerant, and the apply loop
    // skips one record per failure — so a strict cast on these four made a
    // divergent build's record fail differently from every other malformed
    // one. An empty provider is refused by the publish and apply sides alike.
    final decoded = AssistantSettings.fromJson(
      settings().toJson()
        ..['providerKind'] = 42
        ..['baseUrl'] = true
        ..['model'] = const {'en': 'gpt-5'}
        ..['redactSecrets'] = 'yes',
    );
    expect(decoded.providerKind, '');
    expect(decoded.baseUrl, '');
    expect(decoded.model, '');
    expect(decoded.redactSecrets, isTrue);
  });

  test('a padded field is normalized on the way in', () {
    // It passes the blank check, travels verbatim, and then matches no
    // keystore entry on the device that adopts it.
    final decoded = AssistantSettings.fromJson(
      settings().toJson()
        ..['llmApiKeyRef'] = '  anthropic  '
        ..['searxngUrl'] = ' https://searx.example.com ',
    );
    expect(decoded.llmApiKeyRef, 'anthropic');
    expect(decoded.searxngUrl, 'https://searx.example.com');
    // And a second decode of the same record changes nothing further.
    expect(AssistantSettings.fromJson(decoded.toJson()).toJson(),
        decoded.toJson());
  });

  test('updatedAt degrades the way Lww needs it to', () {
    // A record decoding to 0 loses to everything, which is what an absent
    // stamp should do; a double is the shape a JSON round-trip can produce.
    final json = settings().toJson();
    expect(AssistantSettings.fromJson({...json}..remove('updatedAt')).updatedAt,
        0);
    expect(
        AssistantSettings.fromJson({...json, 'updatedAt': 42.0}).updatedAt, 42);
  });

  test('copyWith clears the optional refs and keeps everything else', () {
    // The clear flags are the one place a nullable copyWith can silently turn
    // "cleared here" back into "kept", and nothing exercised them.
    // Brave is set first: the helper leaves it null, and clearing null
    // proves nothing about the flag.
    final cleared = settings(apiKeys: const {'zai': 'z'})
        .copyWith(braveApiKeyRef: 'brave')
        .copyWith(clearSearxngUrl: true)
        .copyWith(clearBraveApiKeyRef: true)
        .copyWith(clearZaiApiKeyRef: true);

    expect(cleared.searxngUrl, isNull);
    expect(cleared.braveApiKeyRef, isNull);
    expect(cleared.zaiApiKeyRef, isNull);
    expect(cleared.toJson().containsKey('searxngUrl'), isFalse);
    expect(cleared.toJson().containsKey('braveApiKeyRef'), isFalse);
    expect(cleared.toJson().containsKey('zaiApiKeyRef'), isFalse);
    // Everything the flags do not name survives them.
    expect(cleared.providerKind, 'anthropic');
    expect(cleared.llmApiKeyRef, 'anthropic');
    expect(cleared.redactSecrets, isFalse);
    expect(cleared.apiKeys, {'zai': 'z'});
    expect(cleared.updatedAt, 42);
  });
}
