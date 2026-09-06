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
    // addresses no keystore entry at all.
    final decoded = AssistantSettings.fromJson(
      settings().toJson()
        ..['apiKeys'] = {'anthropic': '', '': 'sk-1', 'zai': 'z'},
    );
    expect(decoded.apiKeys, {'zai': 'z'});
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

  test('copyWith clears the optional refs and keeps everything else', () {
    // The clear flags are the one place a nullable copyWith can silently turn
    // "cleared here" back into "kept", and nothing exercised them.
    final cleared = settings(apiKeys: const {'zai': 'z'})
        .copyWith(clearSearxngUrl: true)
        .copyWith(clearZaiApiKeyRef: true);

    expect(cleared.searxngUrl, isNull);
    expect(cleared.zaiApiKeyRef, isNull);
    expect(cleared.toJson().containsKey('searxngUrl'), isFalse);
    expect(cleared.toJson().containsKey('zaiApiKeyRef'), isFalse);
    // Everything the flags do not name survives them.
    expect(cleared.providerKind, 'anthropic');
    expect(cleared.llmApiKeyRef, 'anthropic');
    expect(cleared.redactSecrets, isFalse);
    expect(cleared.apiKeys, {'zai': 'z'});
    expect(cleared.updatedAt, 42);
  });
}
