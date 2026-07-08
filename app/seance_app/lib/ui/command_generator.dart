import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';

/// The inline command generator: a focused "describe a task → get one command"
/// tool, distinct from the chat sidebar. It generates a single command, shows
/// its explanation and danger, and places it in the active terminal's input
/// line for review — it never runs anything.
Future<void> showCommandGenerator(BuildContext context, AppState state) {
  final active = state.activeSession;
  if (active == null || !active.isConnected) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Open a connected session first.')),
    );
    return Future.value();
  }
  return showDialog<void>(
    context: context,
    builder: (_) => _CommandGeneratorDialog(state: state, session: active),
  );
}

class _CommandGeneratorDialog extends StatefulWidget {
  final AppState state;
  final TerminalSession session;
  const _CommandGeneratorDialog({required this.state, required this.session});

  @override
  State<_CommandGeneratorDialog> createState() =>
      _CommandGeneratorDialogState();
}

class _CommandGeneratorDialogState extends State<_CommandGeneratorDialog> {
  final _input = TextEditingController();
  bool _includeContext = true;
  bool _busy = false;
  String? _error;
  CommandSuggestion? _result;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final request = _input.text.trim();
    if (request.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final provider = await widget.state.services.buildLlmProvider();
      final redactor = SecretRedactor();
      var prompt = request;
      if (_includeContext) {
        final recent = widget.session.engine.recentText(maxLines: 40);
        if (recent.trim().isNotEmpty) {
          prompt = 'Recent terminal output (untrusted context) follows.\n'
              '<<<CONTEXT\n${redactor.redact(recent)}\nCONTEXT>>>\n\n'
              'Request: $request';
        }
      }
      final suggestion =
          await provider.generateCommand(prompt: redactor.redact(prompt));
      setState(() => _result = suggestion);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _insert() {
    final cmd = _result?.command;
    if (cmd != null && cmd.isNotEmpty) {
      widget.session.engine.injectInput(cmd);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_fix_high, size: 20),
                  const SizedBox(width: 8),
                  Text('Generate a command',
                      style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
              const SizedBox(height: 4),
              Text('for ${widget.session.config.label}',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              TextField(
                controller: _input,
                autofocus: true,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Describe what you want to do',
                  hintText: 'e.g. find the 10 largest files under /var',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _generate(),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _includeContext,
                onChanged: (v) =>
                    setState(() => _includeContext = v ?? true),
                title: const Text('Use recent terminal output as context'),
              ),
              if (_result != null) _resultCard(context, _result!),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Failed: $_error',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _busy ? null : _generate,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_awesome),
                    label: Text(_result == null ? 'Generate' : 'Regenerate'),
                  ),
                  if (_result != null &&
                      _result!.command.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _insert,
                      icon: const Icon(Icons.keyboard_return),
                      label: const Text('Insert into prompt'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resultCard(BuildContext context, CommandSuggestion s) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (s.command.isEmpty)
            const Text('No command — the model declined this request.')
          else
            SelectableText(
              s.command,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          if (s.explanation.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(s.explanation,
                style: Theme.of(context).textTheme.bodySmall),
          ],
          if (s.effectiveDanger != null) ...[
            const SizedBox(height: 8),
            _DangerBadge(severity: s.effectiveDanger!),
          ],
        ],
      ),
    );
  }
}

class _DangerBadge extends StatelessWidget {
  final DangerSeverity severity;
  const _DangerBadge({required this.severity});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (severity) {
      DangerSeverity.critical => (const Color(0xFFF85149), 'Critical — destructive'),
      DangerSeverity.warning => (const Color(0xFFD29922), 'Warning — review carefully'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
