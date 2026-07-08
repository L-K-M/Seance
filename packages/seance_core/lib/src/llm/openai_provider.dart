import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provider.dart';
import 'sse.dart';

/// LLM provider speaking the OpenAI Chat Completions API. A configurable
/// [baseUrl] covers Ollama, LM Studio, vLLM, OpenRouter, and Groq — anything
/// exposing `/chat/completions`. For keyless local endpoints, leave [apiKey]
/// empty and no Authorization header is sent.
class OpenAiCompatibleProvider implements LlmProvider {
  @override
  final String model;
  final String baseUrl;
  final String apiKey;
  final http.Client _client;

  OpenAiCompatibleProvider({
    required this.baseUrl,
    this.apiKey = '',
    this.model = 'gpt-5.4-mini',
    http.Client? client,
  }) : _client = client ?? http.Client();

  Uri get _endpoint => Uri.parse('$baseUrl/chat/completions');

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
      };

  Map<String, dynamic> buildBody({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
    bool stream = false,
  }) {
    return {
      'model': model,
      'messages': messages
          .map((m) => {'role': m.role.name, 'content': m.content})
          .toList(),
      if (tools.isNotEmpty)
        'tools': tools
            .map((t) => {
                  'type': 'function',
                  'function': {
                    'name': t.name,
                    'description': t.description,
                    'parameters': t.inputSchema,
                  },
                })
            .toList(),
      if (stream) 'stream': true,
    };
  }

  ChatTurn parseResponse(Map<String, dynamic> json) {
    final choices = (json['choices'] as List?) ?? const [];
    if (choices.isEmpty) return const ChatTurn(text: '');
    final message =
        (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>;
    final text = message['content'] as String? ?? '';
    final calls = <ToolCall>[];
    for (final tc in (message['tool_calls'] as List?) ?? const []) {
      final m = tc as Map<String, dynamic>;
      final fn = m['function'] as Map<String, dynamic>;
      final rawArgs = fn['arguments'];
      Map<String, dynamic> args;
      if (rawArgs is String) {
        args = rawArgs.isEmpty
            ? {}
            : (jsonDecode(rawArgs) as Map).cast<String, dynamic>();
      } else if (rawArgs is Map) {
        args = rawArgs.cast<String, dynamic>();
      } else {
        args = {};
      }
      calls.add(ToolCall(
        id: m['id'] as String? ?? '',
        name: fn['name'] as String? ?? '',
        arguments: args,
      ));
    }
    return ChatTurn(text: text, toolCalls: calls);
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
    if (res.statusCode >= 400) {
      throw http.ClientException(
          'OpenAI-compatible API error HTTP ${res.statusCode}: ${res.body}');
    }
    return parseResponse(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<List<String>> listModels() async {
    final res =
        await _client.get(Uri.parse('$baseUrl/models'), headers: _headers);
    if (res.statusCode >= 400) {
      throw http.ClientException(
          'OpenAI-compatible API error HTTP ${res.statusCode}: ${res.body}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (json['data'] as List?) ?? const [];
    return data
        .map((m) => (m as Map<String, dynamic>)['id'] as String?)
        .whereType<String>()
        .toList();
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
          'OpenAI-compatible stream failed: HTTP ${res.statusCode}');
    }
    await for (final event in parseSseJson(res.stream)) {
      final choices = event['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final delta =
          (choices.first as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;
      final text = delta?['content'] as String?;
      if (text != null && text.isNotEmpty) yield text;
    }
  }
}
