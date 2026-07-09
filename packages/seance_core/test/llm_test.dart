import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seance_core/src/llm/anthropic_provider.dart';
import 'package:seance_core/src/llm/chat_controller.dart';
import 'package:seance_core/src/llm/danger_linter.dart';
import 'package:seance_core/src/llm/openai_provider.dart';
import 'package:seance_core/src/llm/provider.dart';
import 'package:seance_core/src/llm/search.dart';
import 'package:seance_core/src/llm/sse.dart';
import 'package:test/test.dart';

/// Scripted provider that returns queued turns and records what it was sent.
class FakeProvider implements LlmProvider {
  final List<ChatTurn> _turns;
  final List<List<LlmMessage>> received = [];
  final List<List<ToolSpec>> receivedTools = [];
  int _i = 0;
  FakeProvider(this._turns);

  @override
  String get model => 'fake';

  @override
  Future<ChatTurn> chat(
      {required List<LlmMessage> messages, List<ToolSpec> tools = const []}) async {
    received.add(messages);
    receivedTools.add(tools);
    return _turns[_i++];
  }

  @override
  Future<List<String>> listModels() async => const [];

  @override
  Future<CommandSuggestion> generateCommand(
          {required String prompt, HostContext context = HostContext.unknown}) =>
      throw UnimplementedError();

  @override
  Stream<String> streamChat({required List<LlmMessage> messages}) =>
      const Stream.empty();
}

class FakeSearch implements SearchProvider {
  final List<String> queries = [];
  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    queries.add(query);
    return [SearchResult(title: 'Result', url: 'https://x', snippet: 'snip')];
  }
}

void main() {
  group('AnthropicProvider', () {
    final p = AnthropicProvider(apiKey: 'k', model: 'claude-haiku-4-5-20251001');

    test('buildBody splits system from turns and maps tools', () {
      final body = p.buildBody(messages: [
        const LlmMessage.system('sys'),
        const LlmMessage.user('hi'),
      ], tools: [
        ChatTools.webSearch
      ]);
      expect(body['system'], 'sys');
      expect((body['messages'] as List).length, 1);
      expect((body['messages'] as List).first['role'], 'user');
      expect((body['tools'] as List).first['name'], 'web_search');
      expect((body['tools'] as List).first.containsKey('input_schema'), isTrue);
    });

    test('parseResponse reads text and tool_use blocks', () {
      final turn = p.parseResponse({
        'content': [
          {'type': 'text', 'text': 'sure'},
          {
            'type': 'tool_use',
            'id': 't1',
            'name': 'web_search',
            'input': {'query': 'q'}
          },
        ]
      });
      expect(turn.text, 'sure');
      expect(turn.toolCalls.single.name, 'web_search');
      expect(turn.toolCalls.single.arguments['query'], 'q');
    });

    test('generateCommand parses fenced JSON and merges linter danger',
        () async {
      final client = MockClient((req) async {
        expect(req.headers['x-api-key'], 'k');
        expect(req.headers['anthropic-version'], isNotNull);
        return http.Response(
          jsonEncode({
            'content': [
              {
                'type': 'text',
                'text':
                    '```json\n{"command": "rm -rf /", "explanation": "x", "danger": "none"}\n```'
              }
            ]
          }),
          200,
        );
      });
      final prov = AnthropicProvider(apiKey: 'k', client: client);
      final s = await prov.generateCommand(prompt: 'wipe it');
      expect(s.command, 'rm -rf /');
      // Model said "none", the linter overrides to critical.
      expect(s.modelDanger, isNull);
      expect(s.effectiveDanger, DangerSeverity.critical);
    });

    test('surfaces API errors', () async {
      final client =
          MockClient((req) async => http.Response('nope', 429));
      final prov = AnthropicProvider(apiKey: 'k', client: client);
      expect(() => prov.chat(messages: [const LlmMessage.user('hi')]),
          throwsA(isA<http.ClientException>()));
    });

    test('listModels GETs /v1/models with the api key', () async {
      Uri? seen;
      String? key;
      final client = MockClient((req) async {
        seen = req.url;
        key = req.headers['x-api-key'];
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'claude-opus-4-8', 'display_name': 'Opus'},
              {'id': 'claude-haiku-4-5-20251001'},
            ]
          }),
          200,
        );
      });
      final prov = AnthropicProvider(apiKey: 'k', client: client);
      final models = await prov.listModels();
      expect(seen, Uri.parse('https://api.anthropic.com/v1/models'));
      expect(key, 'k');
      expect(models, ['claude-opus-4-8', 'claude-haiku-4-5-20251001']);
    });
  });

  group('OpenAiCompatibleProvider', () {
    test('omits auth header when keyless (local Ollama)', () {
      final p = OpenAiCompatibleProvider(baseUrl: 'http://localhost:11434/v1');
      final body = p.buildBody(messages: [const LlmMessage.user('hi')]);
      expect(body['model'], isNotNull);
      expect((body['messages'] as List).first['role'], 'user');
    });

    test('parseResponse decodes tool_calls with JSON-string arguments', () {
      final p = OpenAiCompatibleProvider(baseUrl: 'http://x/v1');
      final turn = p.parseResponse({
        'choices': [
          {
            'message': {
              'content': '',
              'tool_calls': [
                {
                  'id': 'c1',
                  'function': {
                    'name': 'paste_to_prompt',
                    'arguments': '{"command": "ls -la"}'
                  }
                }
              ]
            }
          }
        ]
      });
      expect(turn.toolCalls.single.name, 'paste_to_prompt');
      expect(turn.toolCalls.single.arguments['command'], 'ls -la');
    });

    test('generateCommand posts with bearer auth and parses plain JSON',
        () async {
      final client = MockClient((req) async {
        expect(req.headers['authorization'], 'Bearer secret');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content':
                      '{"command":"ls","explanation":"list","danger":"none"}'
                }
              }
            ]
          }),
          200,
        );
      });
      final prov = OpenAiCompatibleProvider(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'secret',
          client: client);
      final s = await prov.generateCommand(prompt: 'list files');
      expect(s.command, 'ls');
      expect(s.effectiveDanger, isNull);
    });

    test('listModels GETs /models and returns the ids', () async {
      Uri? seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'llama3.1'},
              {'id': 'qwen2.5'},
            ]
          }),
          200,
        );
      });
      final prov = OpenAiCompatibleProvider(
          baseUrl: 'http://localhost:11434/v1', client: client);
      final models = await prov.listModels();
      expect(seen, Uri.parse('http://localhost:11434/v1/models'));
      expect(models, ['llama3.1', 'qwen2.5']);
    });
  });

  group('parseCommandJson', () {
    test('handles prose-wrapped JSON', () {
      final s = parseCommandJson(
          'Here you go: {"command":"pwd","explanation":"cwd","danger":"none"} hope that helps');
      expect(s.command, 'pwd');
    });

    test('throws when there is no JSON object', () {
      expect(() => parseCommandJson('no json here'),
          throwsA(isA<FormatException>()));
    });
  });

  group('parseSseJson', () {
    test('extracts JSON data lines and skips [DONE]', () async {
      final raw = [
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"He"}}',
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"llo"}}',
        ': keep-alive comment',
        'data: [DONE]',
      ].join('\n');
      final events =
          await parseSseJson(Stream.value(utf8.encode(raw))).toList();
      expect(events.length, 2);
      final text = events
          .map((e) => (e['delta'] as Map)['text'] as String)
          .join();
      expect(text, 'Hello');
    });
  });

  group('ChatController', () {
    test('stages a paste (first line only, never executes) and returns reply',
        () async {
      final provider = FakeProvider([
        const ChatTurn(text: '', toolCalls: [
          ToolCall(
              id: 'c1',
              name: 'paste_to_prompt',
              arguments: {'command': 'tar -xzf a.tgz\nrm -rf /'}),
        ]),
        const ChatTurn(text: 'Done — review the command and press Enter.'),
      ]);
      final pasted = <String>[];
      final chat = ChatController(
        provider: provider,
        onPaste: pasted.add,
      );
      final result = await chat.send('unpack a.tgz');
      // Only the first line was staged; the newline (and rm -rf /) is gone.
      expect(pasted.single, 'tar -xzf a.tgz');
      expect(result.stagedCommands.single, 'tar -xzf a.tgz');
      expect(result.reply, contains('press Enter'));
    });

    test('runs web_search via the backend and records the query', () async {
      final provider = FakeProvider([
        const ChatTurn(text: '', toolCalls: [
          ToolCall(
              id: 'c1',
              name: 'web_search',
              arguments: {'query': 'how to use rsync'}),
        ]),
        const ChatTurn(text: 'Use rsync -av src dst.'),
      ]);
      final search = FakeSearch();
      final chat = ChatController(
        provider: provider,
        onPaste: (_) {},
        searchProvider: search,
      );
      final result = await chat.send('how do I copy a dir to a server?');
      expect(search.queries.single, 'how to use rsync');
      expect(result.searchQueries.single, 'how to use rsync');
      expect(result.reply, contains('rsync'));
    });

    test('redacts secrets in terminal context before sending', () async {
      final provider = FakeProvider([const ChatTurn(text: 'ok')]);
      final chat = ChatController(provider: provider, onPaste: (_) {});
      final result = await chat.send(
        'why did this fail?',
        terminalContext: 'export TOKEN=ghp_0123456789abcdef0123456789abcdef0123',
      );
      final sentContext =
          result.sent.firstWhere((s) => s.label.contains('terminal'));
      expect(sentContext.content, isNot(contains('ghp_0123456789')));
      expect(sentContext.content, contains('«redacted»'));
    });

    test(
      'dispatches exactly the permitted rounds then disables tools',
      () async {
        final provider = FakeProvider([
          const ChatTurn(
            text: '',
            toolCalls: [
              ToolCall(
                id: 'c1',
                name: 'web_search',
                arguments: {'query': 'first'},
              ),
            ],
          ),
          const ChatTurn(
            text: '',
            toolCalls: [
              ToolCall(
                id: 'c2',
                name: 'web_search',
                arguments: {'query': 'second'},
              ),
            ],
          ),
          const ChatTurn(text: 'Final answer.'),
        ]);
        final search = FakeSearch();
        final chat = ChatController(
          provider: provider,
          onPaste: (_) {},
          searchProvider: search,
          maxToolIterations: 2,
        );

        final result = await chat.send('research this');

        expect(search.queries, ['first', 'second']);
        expect(provider.received, hasLength(3));
        expect(provider.receivedTools[0], ChatTools.all);
        expect(provider.receivedTools[1], ChatTools.all);
        expect(provider.receivedTools[2], isEmpty);
        expect(result.reply, 'Final answer.');
      },
    );

    test('does not drop the last permitted tool action', () async {
      final provider = FakeProvider([
        const ChatTurn(
          text: '',
          toolCalls: [
            ToolCall(
              id: 'c1',
              name: 'paste_to_prompt',
              arguments: {'command': 'pwd'},
            ),
          ],
        ),
        const ChatTurn(text: 'Review the staged command.'),
      ]);
      final pasted = <String>[];
      final chat = ChatController(
        provider: provider,
        onPaste: pasted.add,
        maxToolIterations: 1,
      );

      final result = await chat.send('where am I?');

      expect(pasted, ['pwd']);
      expect(result.stagedCommands, ['pwd']);
      expect(provider.receivedTools.last, isEmpty);
    });

    test('returns a nonblank fallback for a disabled tool-only turn', () async {
      final provider = FakeProvider([
        const ChatTurn(
          text: '',
          toolCalls: [
            ToolCall(
              id: 'c1',
              name: 'web_search',
              arguments: {'query': 'allowed'},
            ),
          ],
        ),
        const ChatTurn(
          text: '',
          toolCalls: [
            ToolCall(
              id: 'c2',
              name: 'paste_to_prompt',
              arguments: {'command': 'not-allowed'},
            ),
          ],
        ),
      ]);
      final pasted = <String>[];
      final chat = ChatController(
        provider: provider,
        onPaste: pasted.add,
        maxToolIterations: 1,
      );

      final result = await chat.send('help');

      expect(result.reply, isNotEmpty);
      expect(result.reply, contains('tool-use limit'));
      expect(pasted, isEmpty);
      expect(provider.receivedTools.last, isEmpty);
    });

    test('keeps modeled roles alternating after a pure tool call', () async {
      final provider = FakeProvider([
        const ChatTurn(
          text: '',
          toolCalls: [
            ToolCall(
              id: 'c1',
              name: 'paste_to_prompt',
              arguments: {'command': 'ls'},
            ),
          ],
        ),
        const ChatTurn(text: 'Ready.'),
      ]);
      final chat = ChatController(
        provider: provider,
        onPaste: (_) {},
        maxToolIterations: 1,
      );

      await chat.send('list files');

      expect(provider.received[1].map((message) => message.role), [
        LlmRole.system,
        LlmRole.user,
        LlmRole.assistant,
        LlmRole.user,
      ]);
    });

    test('rejects a negative tool iteration limit', () {
      expect(
        () => ChatController(
          provider: FakeProvider(const []),
          onPaste: (_) {},
          maxToolIterations: -1,
        ),
        throwsArgumentError,
      );
    });
  });
}
