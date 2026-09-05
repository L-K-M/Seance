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

  test('a record with no keys is byte-identical to one that dropped them', () {
    // So a device that syncs keys and one that does not produce the same
    // record for the same configuration, rather than one carrying an empty
    // map that reads as a difference.
    final withKeys = settings(apiKeys: const {'anthropic': 'sk-1'});
    expect(withKeys.toJson().containsKey('apiKeys'), isTrue);
    expect(withKeys.withoutKeys().toJson(), settings().toJson());
    expect(settings().toJson().containsKey('apiKeys'), isFalse);
    // Dropping nothing is the same object rather than a copy.
    expect(settings().withoutKeys().apiKeys, isEmpty);
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
      );
    }
  });
}
