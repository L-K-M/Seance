import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  final redactor = SecretRedactor();

  group('quoted secret assignments', () {
    test('masks nested JSON values and preserves neighboring fields', () {
      final input = jsonEncode({
        'auth': {
          'password': 'two secret words',
          'TOKEN': 'short',
          'api_key': '鍵🔑',
          'DB_PASSWORD': 'prefixed secret',
        },
        'host': 'example.test',
      });
      expect(jsonDecode(redactor.redact(input)), {
        'auth': {
          'password': '«redacted»',
          'TOKEN': '«redacted»',
          'api_key': '«redacted»',
          'DB_PASSWORD': '«redacted»',
        },
        'host': 'example.test',
      });
    });

    test('masks complete quoted shell and YAML values', () {
      expect(
        redactor.redact('''DB_PASSWORD="two secret words" other=visible
'passwd': 'another private phrase'
secret = "x"
api-key: unquoted-secret, host: example.test'''),
        '''DB_PASSWORD="«redacted»" other=visible
'passwd': '«redacted»'
secret = "«redacted»"
api-key: «redacted» host: example.test''',
      );
    });

    test(
      'handles escaped quotes and backslashes without exposing a suffix',
      () {
        final input = jsonEncode({
          'password': 'first "quoted" part \\ final secret',
          'host': 'visible',
        });
        expect(jsonDecode(redactor.redact(input)), {
          'password': '«redacted»',
          'host': 'visible',
        });
        expect(
          redactor.redact(r"token='it''s all private' next=visible"),
          "token='«redacted»' next=visible",
        );
      },
    );

    test('unquoted shell values keep punctuation inside the secret', () {
      for (final value in ['prefix,private', 'prefix}private', 'prefix]private']) {
        final result = redactor.redact('PASSWORD=$value next=visible');
        expect(result, 'PASSWORD=«redacted» next=visible');
      }
    });

    test('redacts truncated quoted values through the available tail', () {
      expect(
        redactor.redact('password="private words\nprivate continuation'),
        'password="«redacted»',
      );
      expect(
        redactor.redact('token="private trailing escape\\'),
        'token="«redacted»',
      );
    });

    test('preserves empty values, benign keys, prose and explicit disable', () {
      const text = '''{"password":"","host":"example.test"}
password strength matters; tokenization is useful
notpassword=value secretName=visible''';
      expect(redactor.redact(text), text);
      const private = '{"password":"two secret words"}';
      expect(SecretRedactor(enabled: false).redact(private), private);
    });

    test('keeps existing token, PEM and custom-pattern coverage', () {
      const text = '''DB_PASSWORD=opaque-value
sk-ant-abcdefghij0123456789XYZ
password=-----BEGIN OPENSSH PRIVATE KEY-----
private key material
-----END OPENSSH PRIVATE KEY-----
custom-private''';
      final result = SecretRedactor(
        extraPatterns: [RegExp('custom-private')],
      ).redact(text);
      for (final secret in [
        'opaque-value',
        'sk-ant-',
        'private key material',
        'custom-private',
      ]) {
        expect(result, isNot(contains(secret)));
      }
    });

    test('large malformed values and many adjacent fields stay bounded', () {
      // A missing closing quote must consume one suffix once, rather than
      // retrying a quoted-value regex from every nested assignment marker.
      final malformed = 'password="${'token=private ' * 100000}';
      expect(redactor.redact(malformed), 'password="«redacted»');
      final adjacent = '{${'"token":"private",' * 20000}"host":"visible"}';
      final result = redactor.redact(adjacent);
      expect(result, isNot(contains('private')));
      expect(result, endsWith('"host":"visible"}'));
      expect('«redacted»'.allMatches(result), hasLength(20000));
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  for (final anthropic in [false, true]) {
    test(
      '${anthropic ? 'Anthropic' : 'OpenAI'} wire payload is redacted',
      () async {
        final requests = <Map<String, dynamic>>[];
        final client = MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode(
              anthropic
                  ? {
                      'content': [
                        {'type': 'text', 'text': 'answer'},
                      ],
                    }
                  : {
                      'choices': [
                        {
                          'message': {'content': 'answer'},
                        },
                      ],
                    },
            ),
            200,
          );
        });
        final LlmProvider provider = anthropic
            ? AnthropicProvider(apiKey: 'test', client: client)
            : OpenAiCompatibleProvider(
                baseUrl: 'https://example.test/v1',
                client: client,
              );
        final controller = ChatController(provider: provider, onPaste: (_) {});
        await controller.send(
          'Inspect {"password":"typed private words"}',
          terminalContext:
              '{"token":"terminal private words","host":"visible"}',
        );
        await controller.send('Follow up without terminal context');

        for (final request in requests) {
          final wire = jsonEncode(request);
          expect(wire, isNot(contains('typed private words')));
          expect(wire, isNot(contains('terminal private words')));
          expect(wire, contains('«redacted»'));
        }
        expect(jsonEncode(requests.first), contains('visible'));
        expect(jsonEncode(requests.last), isNot(contains('visible')));
        client.close();
      },
    );
  }
}
