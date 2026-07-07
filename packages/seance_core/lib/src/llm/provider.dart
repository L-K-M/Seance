import 'dart:convert';

import 'danger_linter.dart';

enum LlmRole { system, user, assistant }

class LlmMessage {
  final LlmRole role;
  final String content;
  const LlmMessage(this.role, this.content);

  const LlmMessage.system(this.content) : role = LlmRole.system;
  const LlmMessage.user(this.content) : role = LlmRole.user;
  const LlmMessage.assistant(this.content) : role = LlmRole.assistant;
}

/// Context about the remote host, gathered cheaply at connect time and on each
/// prompt, that materially improves command generation.
class HostContext {
  final String? os; // e.g. "Linux"
  final String? distro; // e.g. "Ubuntu 24.04"
  final String? shell; // e.g. "bash"
  final String? cwd;
  final int? lastExitCode;

  const HostContext({
    this.os,
    this.distro,
    this.shell,
    this.cwd,
    this.lastExitCode,
  });

  static const HostContext unknown = HostContext();

  String toPromptBlock() {
    final b = StringBuffer('Remote host context:\n');
    b.writeln('- OS: ${os ?? 'unknown'}');
    if (distro != null) b.writeln('- Distro: $distro');
    b.writeln('- Shell: ${shell ?? 'unknown'}');
    if (cwd != null) b.writeln('- CWD: $cwd');
    if (lastExitCode != null) b.writeln('- Last exit code: $lastExitCode');
    return b.toString();
  }
}

/// A command generated from a natural-language prompt. [modelDanger] is what the
/// model self-reported; [linterDanger] is our independent check. The UI shows
/// the more severe of the two and never auto-runs the command.
class CommandSuggestion {
  final String command;
  final String explanation;
  final DangerSeverity? modelDanger;

  const CommandSuggestion({
    required this.command,
    required this.explanation,
    this.modelDanger,
  });

  DangerSeverity? get linterDanger => DangerLinter.worst(command);

  /// The effective severity to surface to the user.
  DangerSeverity? get effectiveDanger {
    final m = modelDanger, l = linterDanger;
    if (m == DangerSeverity.critical || l == DangerSeverity.critical) {
      return DangerSeverity.critical;
    }
    if (m == DangerSeverity.warning || l == DangerSeverity.warning) {
      return DangerSeverity.warning;
    }
    return null;
  }
}

/// A tool the model may call during a chat turn.
class ToolSpec {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema; // JSON Schema

  const ToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
}

/// A tool invocation requested by the model.
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  const ToolCall(
      {required this.id, required this.name, required this.arguments});
}

/// The result of one chat turn: assistant [text] plus any [toolCalls] the model
/// wants executed before continuing.
class ChatTurn {
  final String text;
  final List<ToolCall> toolCalls;
  const ChatTurn({required this.text, this.toolCalls = const []});
}

/// Which wire protocol a provider speaks.
enum LlmProviderKind { anthropic, openaiCompatible }

/// A named provider "mode" (Wave Terminal's pattern): the transport, endpoint,
/// model, and — resolved separately, never stored in config — the API key.
class LlmProviderConfig {
  final String name;
  final LlmProviderKind kind;
  final String baseUrl;
  final String model;

  /// The keychain entry name holding the API key (never the key itself, and
  /// never synced). Empty for keyless local endpoints like Ollama.
  final String apiKeyRef;

  const LlmProviderConfig({
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.model,
    this.apiKeyRef = '',
  });
}

abstract class LlmProvider {
  String get model;

  /// One-shot: turn a natural-language prompt into a reviewed command.
  Future<CommandSuggestion> generateCommand({
    required String prompt,
    HostContext context = HostContext.unknown,
  });

  /// One chat turn (non-streaming), optionally exposing [tools].
  Future<ChatTurn> chat({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
  });

  /// Streamed text deltas for the same messages (no tool use).
  Stream<String> streamChat({required List<LlmMessage> messages});
}

/// System prompt for command generation. Kept here so both providers share it.
const String kCommandSystemPrompt = '''
You translate a natural-language request into a single shell command for the
described remote host. Respond with ONLY a JSON object, no prose, of the form:
{"command": "<one shell command>", "explanation": "<one sentence>", "danger": "none|warning|critical"}
Rules:
- Exactly one command. No comments, no markdown fences.
- Prefer the host's actual shell and OS.
- Set "danger" to "critical" for destructive/irreversible operations
  (deleting data, overwriting devices, powering off), "warning" for risky ones.
- If the request is impossible or unsafe, put an empty string in "command" and
  explain why.
''';

/// Extracts the command-suggestion JSON from a model reply, tolerating markdown
/// fences or surrounding prose. Throws [FormatException] if no object is found.
CommandSuggestion parseCommandJson(String reply) {
  final jsonText = _extractJsonObject(reply);
  final map = jsonDecode(jsonText) as Map<String, dynamic>;
  return CommandSuggestion(
    command: (map['command'] as String? ?? '').trim(),
    explanation: (map['explanation'] as String? ?? '').trim(),
    modelDanger: _dangerFromName(map['danger'] as String?),
  );
}

DangerSeverity? _dangerFromName(String? name) {
  switch (name) {
    case 'critical':
      return DangerSeverity.critical;
    case 'warning':
      return DangerSeverity.warning;
    default:
      return null;
  }
}

String _extractJsonObject(String text) {
  final fenced =
      RegExp(r'```(?:json)?\s*([\s\S]*?)```', multiLine: true).firstMatch(text);
  final candidate = fenced != null ? fenced.group(1)! : text;
  final start = candidate.indexOf('{');
  final end = candidate.lastIndexOf('}');
  if (start < 0 || end <= start) {
    throw FormatException('No JSON object in model reply: $text');
  }
  return candidate.substring(start, end + 1);
}
