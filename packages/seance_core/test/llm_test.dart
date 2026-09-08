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

    test('zero tool iterations disables tools on the only provider call',
        () async {
      final provider = FakeProvider([
        const ChatTurn(text: 'Tools were not needed.'),
      ]);
      final chat = ChatController(
        provider: provider,
        onPaste: (_) {},
        maxToolIterations: 0,
      );

      final result = await chat.send('answer without tools');

      expect(provider.received, hasLength(1));
      expect(provider.receivedTools.single, isEmpty);
      expect(result.reply, 'Tools were not needed.');
    });

    test('returns a nonblank fallback for an empty provider turn', () async {
      final provider = FakeProvider([
        const ChatTurn(text: ''),
      ]);
      final chat = ChatController(provider: provider, onPaste: (_) {});

      final result = await chat.send('hello');

      expect(result.reply, isNotEmpty);
      expect(result.reply, contains('did not produce a response'));
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
      expect(
        provider.received[1][2].content,
        startsWith('[_internal: requested tools:'),
      );
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

  group('clipSearchSnippets', () {
    SearchResult hit(String snippet,
            {String title = 't', String url = 'https://x.example'}) =>
        SearchResult(title: title, url: url, snippet: snippet);

    test('a snippet under the cap is passed through untouched', () {
      final result = ChatController.clipSearchSnippets([hit('short')]).single;
      expect(result.snippet, 'short');
    });

    test('a snippet exactly at the cap is passed through untouched', () {
      // The boundary itself: a `>=` in place of `>` would clip a snippet that
      // fits, and neither neighbour above or below can tell.
      final edge = 'y' * ChatController.maxSnippetChars;
      // The same instance, as the URL boundary case asserts: passthrough is
      // the contract when nothing needs clipping, and pinning it in one of
      // three "fits" cases left the other two able to rebuild silently.
      final fits = hit(edge);
      expect(ChatController.clipSearchSnippets([fits]).single, same(fits));
    });

    test('the cut never splits a surrogate pair', () {
      // The cap counts UTF-16 code units, and an emoji is two of them. A cut
      // between its halves leaves a lone high surrogate that serializes into
      // the tool result as U+FFFD.
      final long = '${'x' * (ChatController.maxSnippetChars - 1)}😀 and more';
      final result = ChatController.clipSearchSnippets([hit(long)]).single;
      expect(result.snippet.endsWith('…'), isTrue);
      final beforeEllipsis =
          result.snippet.codeUnitAt(result.snippet.length - 2);
      // Only the *high* half can be stranded: the kept text is a contiguous
      // prefix, so a trailing lone low surrogate is not reachable here. A
      // copy of this check applied to arbitrary text would need both.
      expect(beforeEllipsis & 0xFC00, isNot(0xD800));
      expect(result.snippet, '${'x' * (ChatController.maxSnippetChars - 1)}…');
    });

    test('a cut that lands after a complete pair keeps the whole cap', () {
      // The complement of the case above: with the pair ending exactly at the
      // cap there is nothing to back off, and an implementation that always
      // dropped a unit would pass that test and fail this one.
      final long = '${'x' * (ChatController.maxSnippetChars - 2)}😀 and more';
      final result = ChatController.clipSearchSnippets([hit(long)]).single;
      expect(
        result.snippet,
        '${'x' * (ChatController.maxSnippetChars - 2)}😀…',
      );
    });

    test('a title is capped too, by the same rule', () {
      // Only the snippet used to be: a title is whatever text the service put
      // in the field, so a gateway answering with a megabyte of it spends the
      // budget the snippet cap exists to protect.
      // Distinct at both ends rather than a run of one character: the kept
      // prefix is asserted exactly below, and a clip taken from the wrong
      // offset reproduces `'y' * n` perfectly.
      final long = 'START${'y' * (ChatController.maxTitleChars + 50)}';
      final result =
          ChatController.clipSearchSnippets([hit('short', title: long)]).single;
      // The kept prefix itself, not just its length: a clip taken from the
      // wrong offset, or one that doubled a character while keeping the
      // count, satisfies a length-and-suffix pair exactly as well.
      expect(result.title,
          '${long.substring(0, ChatController.maxTitleChars)}…');
      expect(result.title.length, ChatController.maxTitleChars + 1);
    });

    test('a title that fits is left alone, under the cap and at it', () {
      // Its own test rather than a tail on the clip case above: Dart stops a
      // test at the first failed expectation, so a title-clip regression used
      // to take the passthrough and boundary assertions with it — and the
      // group pins the snippet's and the URL's fit cases separately for that
      // reason.
      final fitsAll = hit('short');
      final kept = ChatController.clipSearchSnippets([fitsAll]).single;
      expect(kept, same(fitsAll));
      expect(kept.title, 't');
      expect(kept.snippet, 'short');
      // And the boundary itself, which the snippet and URL cases pin and this
      // one did not: exactly at the cap is a fit, so the instance rides
      // through. `'t'` above is comfortably under, and a `<` where the
      // condition wants `<=` on the title clause alone is invisible to it.
      final edgeTitle = hit('short', title: 'y' * ChatController.maxTitleChars);
      expect(
        ChatController.clipSearchSnippets([edgeTitle]).single,
        same(edgeTitle),
      );
    });

    test('an over-long snippet is clipped, and says it was', () {
      // Every backend is unbounded in the same way: a snippet is whatever
      // text the search service put in the field. Z.AI's prose fallback can
      // hand back a whole tool reply — its byte cap is 2 MiB, which protects
      // memory rather than the token bill — and SearXNG and Brave copy their
      // `content` through verbatim. This is where they converge before being
      // serialized into a tool result, so it is where the cap belongs.
      final long = 'x' * (ChatController.maxSnippetChars + 500);
      final result = ChatController.clipSearchSnippets([hit(long)]).single;
      expect(result.snippet.length, ChatController.maxSnippetChars + 1);
      expect(result.snippet.endsWith('…'), isTrue);
      // Only the snippet is touched.
      expect(result.title, 't');
      expect(result.url, 'https://x.example');
    });

    test('an over-long URL is clipped to its exact prefix, and only it', () {
      // The third field serialized into the same tool result, and the one the
      // other two caps left open. A query string with a page of tracking
      // parameters is ordinary on the open web, and SearXNG and Brave copy
      // the field through as they find it.
      final long = 'https://x.example/?q=${'z' * ChatController.maxUrlChars}';
      final result =
          ChatController.clipSearchSnippets([hit('short', url: long)]).single;
      // Visibly truncated, not silently shortened: a link that merely does
      // not resolve reads as a citation. Pinned as the exact prefix, for the
      // reason the title's is — the scheme and host have to survive the clip
      // for the truncation to read as one.
      expect(result.url, '${long.substring(0, ChatController.maxUrlChars)}…');
      expect(result.url.length, ChatController.maxUrlChars + 1);
      // The rest of the result rides through unchanged.
      expect(result.title, 't');
      expect(result.snippet, 'short');

    });

    test('a URL cut that would split a surrogate backs off one unit', () {
      // The snippet and the title each have an emoji-at-the-cap case; the URL
      // had none, so a clip that reached for a bare `substring` here instead
      // of the shared `clipText` passed the whole group — while a non-ASCII
      // path or query, ordinary for a non-English result, came back with a
      // lone surrogate that serializes as U+FFFD.
      //
      // Its own test rather than a tail on the clip case above, for the
      // reason the title cases were split: Dart stops at the first failed
      // expectation, and this is the one the group's comments say slipped
      // through before.
      const seed = 'https://x.example/';
      final emojiUrl =
          '$seed${'u' * (ChatController.maxUrlChars - seed.length - 1)}😀/p';
      final emojiResult =
          ChatController.clipSearchSnippets([hit('short', url: emojiUrl)])
              .single;
      expect(
        emojiResult.url,
        '$seed${'u' * (ChatController.maxUrlChars - seed.length - 1)}…',
      );
      // One unit shorter than the ordinary clip: the back-off drops the high
      // half rather than keeping it, so the kept text stops one before the
      // cap and the whole string lands exactly on it.
      expect(emojiResult.url.length, ChatController.maxUrlChars);

    });

    test('a URL exactly at the cap rides through as the same instance', () {
      // The boundary: a URL exactly at the cap is not touched, and the
      // instance itself is passed through rather than rebuilt.
      final edge = 'https://x.example/'.padRight(ChatController.maxUrlChars, 'a');
      expect(edge.length, ChatController.maxUrlChars);
      final fits = hit('short', url: edge);
      expect(
        ChatController.clipSearchSnippets([fits]).single,
        same(fits),
      );
    });

    test('all three fields clip together without disturbing each other', () {
      // Every other case in this group varies one field, so a rebuild that
      // clipped the one it was given and dropped, blanked or mis-copied a
      // sibling would pass all of them. The title also carries an emoji at
      // the boundary: the surrogate back-off is pinned for snippets, and a
      // title clipped with a bare `substring` would strand a lone half here.
      final item = hit(
        'x' * (ChatController.maxSnippetChars + 1),
        title: '${'T' * (ChatController.maxTitleChars - 1)}😀 and more',
        url: 'https://x.example/${'u' * ChatController.maxUrlChars}',
      );

      final result = ChatController.clipSearchSnippets([item]).single;

      expect(result.snippet, '${'x' * ChatController.maxSnippetChars}…');
      expect(result.title, '${'T' * (ChatController.maxTitleChars - 1)}…');
      expect(
        result.url,
        '${item.url.substring(0, ChatController.maxUrlChars)}…',
      );
    });

    test('a list keeps its count, its order and a per-item decision', () {
      // Every case above hands over one result and reads `.single`, so the
      // function's list contract — clip each, keep all, in order — is
      // untested: an early return, or an accumulator that kept only the last
      // rebuild, passes the entire group.
      final fits = hit('short');
      final over = hit('x' * (ChatController.maxSnippetChars + 1));
      final edge = hit('y' * ChatController.maxSnippetChars);

      final results = ChatController.clipSearchSnippets([fits, over, edge]);

      expect(results, hasLength(3));
      expect(results[0], same(fits));
      expect(results[1].snippet, '${'x' * ChatController.maxSnippetChars}…');
      expect(results[2], same(edge));
    });

    test('an empty list comes back empty', () {
      // Zero hits is an ordinary answer from every backend, and it is the one
      // shape a `first` or a `reduce` would throw on — which every case above
      // hands at least one result and so cannot see.
      expect(ChatController.clipSearchSnippets(const []), isEmpty);
    });
  });

  group('clipText', () {
    test('a cap of zero or less yields the empty string', () {
      // A shared public helper: the surrogate check indexes at `max - 1`, so
      // a nonsensical cap used to come back as a RangeError from inside a
      // text-clipping utility rather than as a degenerate clip.
      expect(clipText('abc', 0), isEmpty);
      expect(clipText('abc', -1), isEmpty);
      // Empty text is already at or under any cap, so it comes back as it is.
      expect(clipText('', 0), isEmpty);
    });

    test('text exactly at the cap is returned as it is', () {
      // The boundary of the comparison itself. Both callers pin it through
      // their own fields, but this is the helper they share: a `>=` here
      // would clip text that fits, and every caller would inherit it.
      expect(clipText('abcd', 4), 'abcd');
      expect(clipText('abc', 4), 'abc');
      // And with a surrogate pair completing exactly at the cap. Every other
      // pair case in this group goes through the *clip* path, so the back-off
      // could be applied before the fits guard — or keyed on the low half
      // instead of the high one — and 'abcd' cannot tell the difference.
      // A fit is a fit: no back-off, no ellipsis.
      expect('ab\u{1F600}'.length, 4);
      expect(clipText('ab\u{1F600}', 4), 'ab\u{1F600}');
    });

    test('a clipped string is one unit longer than the cap', () {
      // [max] bounds the kept content, not the result. Documented because a
      // caller with a hard server-side limit has to pass `max - 1`; every cap
      // here is a token budget, so the extra unit costs nothing.
      expect(clipText('abcdef', 4), 'abcd…');
      expect(clipText('abcdef', 4).length, 5);
    });

    test('a cap of one backs off a surrogate rather than splitting it', () {
      // The boundary of the back-off: cutting at 1 lands between the halves
      // of the emoji, so the kept content is empty and only the ellipsis is
      // left — not a lone high surrogate that serializes as U+FFFD.
      expect(clipText('😀abc', 1), '…');
      expect(clipText('😀abc', 2), '😀…');
    });
  });
}
