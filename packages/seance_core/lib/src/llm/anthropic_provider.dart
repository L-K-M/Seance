import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provider.dart';
import 'sse.dart';

/// LLM provider speaking the Anthropic Messages API.
class AnthropicProvider implements LlmProvider {
  @override
  final String model;
  final String baseUrl;
  final String apiKey;
  final int maxTokens;
  final http.Client _client;

  AnthropicProvider({
    required this.apiKey,
    this.model = 'claude-haiku-4-5-20251001',
    this.baseUrl = 'https://api.anthropic.com',
    this.maxTokens = 1024,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Uri get _endpoint => Uri.parse('$baseUrl/v1/messages');

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      };

  /// Split out for testing: build the request body for a set of messages.
  Map<String, dynamic> buildBody({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
    bool stream = false,
  }) {
    final system = messages
        .where((m) => m.role == LlmRole.system)
        .map((m) => m.content)
        .join('\n\n');
    final turns = messages
        .where((m) => m.role != LlmRole.system)
        .map((m) => {
              'role': m.role == LlmRole.assistant ? 'assistant' : 'user',
              'content': m.content,
            })
        .toList();
    return {
      'model': model,
      'max_tokens': maxTokens,
      if (system.isNotEmpty) 'system': system,
      'messages': turns,
      if (tools.isNotEmpty)
        'tools': tools
            .map((t) => {
                  'name': t.name,
                  'description': t.description,
                  'input_schema': t.inputSchema,
                })
            .toList(),
      if (stream) 'stream': true,
    };
  }

  /// Split out for testing: parse a Messages API response body.
  ChatTurn parseResponse(Map<String, dynamic> json) {
    final content = (json['content'] as List?) ?? const [];
    final textBuf = StringBuffer();
    final calls = <ToolCall>[];
    for (final block in content.cast<Map<String, dynamic>>()) {
      switch (block['type']) {
        case 'text':
          textBuf.write(block['text'] as String? ?? '');
        case 'tool_use':
          calls.add(ToolCall(
            id: block['id'] as String? ?? '',
            name: block['name'] as String? ?? '',
            arguments:
                ((block['input'] as Map?)?.cast<String, dynamic>()) ?? {},
          ));
      }
    }
    return ChatTurn(text: textBuf.toString(), toolCalls: calls);
  }

  @override
  Future<ChatTurn> chat({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
  }) async {
    final res = await _client.post(
      _endpoint,
      headers: _headers,
      body: jsonEncode(buildBody(messages: messages, tools: tools)),
    );
    _throwIfError(res);
    return parseResponse(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<CommandSuggestion> generateCommand({
    required String prompt,
    HostContext context = HostContext.unknown,
  }) async {
    final turn = await chat(messages: [
      const LlmMessage.system(kCommandSystemPrompt),
      LlmMessage.user('${context.toPromptBlock()}\nRequest: $prompt'),
    ]);
    return parseCommandJson(turn.text);
  }

  @override
  Stream<String> streamChat({required List<LlmMessage> messages}) async* {
    final req = http.Request('POST', _endpoint)
      ..headers.addAll(_headers)
      ..body = jsonEncode(buildBody(messages: messages, stream: true));
    final res = await _client.send(req);
    if (res.statusCode >= 400) {
      throw http.ClientException(
          'Anthropic stream failed: HTTP ${res.statusCode}');
    }
    await for (final event in parseSseJson(res.stream)) {
      if (event['type'] == 'content_block_delta') {
        final delta = event['delta'] as Map<String, dynamic>?;
        final text = delta?['text'] as String?;
        if (text != null) yield text;
      }
    }
  }

  void _throwIfError(http.Response res) {
    if (res.statusCode >= 400) {
      throw http.ClientException(
          'Anthropic API error HTTP ${res.statusCode}: ${res.body}');
    }
  }
}
