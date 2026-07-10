import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import 'top_toast.dart';

/// The inline command generator: a focused "describe a task → get one command"
/// tool, distinct from the chat sidebar. It generates a single command and
/// places it in the active terminal's input line for review — it never runs
/// anything. Enter generates, inserts, and closes; the explanation and any
/// danger are surfaced in a snackbar so the streamlined flow still warns you.
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
  late final TextEditingController _input;
  bool _includeContext = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Prefill with whatever the user has already typed at the prompt but not
    // yet run, so the generator refines it instead of starting blank.
    final pending = widget.session.engine.pendingInput.trim();
    _input = TextEditingController(text: pending);
    _input.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _input.text.length,
    );
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final request = _input.text.trim();
    if (request.isEmpty || _busy) return;
    // Capture the root overlay now: it outlives this dialog, so the "inserted"
    // toast can show at the top after the dialog closes (a SnackBar would cover
    // the prompt the command was just inserted into).
    final overlay = Overlay.of(context, rootOverlay: true);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final provider = await widget.state.services.buildLlmProvider();
      final redactor = SecretRedactor(
          enabled: widget.state.services.settings.redactionEnabled);
      var prompt = request;
      if (_includeContext) {
        final recent = widget.session.engine.recentText(maxLines: 40);
        if (recent.trim().isNotEmpty) {
          prompt =
              'Recent terminal output (untrusted context) follows.\n'
              '<<<CONTEXT\n${redactor.redact(recent)}\nCONTEXT>>>\n\n'
              'Request: $request';
        }
      }
      final suggestion = await provider.generateCommand(
        prompt: redactor.redact(prompt),
      );

      if (suggestion.command.isEmpty) {
        // The model declined — stay open and explain why.
        setState(
          () => _error = suggestion.explanation.isNotEmpty
              ? suggestion.explanation
              : 'The model did not return a command.',
        );
        return;
      }

      final command = PasteSanitizer.sanitize(suggestion.command);
      final safeSuggestion = CommandSuggestion(
        command: command,
        explanation: suggestion.explanation,
        modelDanger: suggestion.modelDanger,
      );

      widget.session.engine.injectInput(command);
      if (mounted) Navigator.of(context).pop();
      _showInsertedToast(overlay, safeSuggestion);
    } on UnsafePasteException catch (e) {
      setState(() => _error = e.reason);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Notify — at the TOP, so it doesn't cover the prompt the command was just
  /// inserted into — that the command is in the prompt, with any danger note.
  void _showInsertedToast(OverlayState overlay, CommandSuggestion s) {
    final danger = s.effectiveDanger;
    final label = switch (danger) {
      DangerSeverity.critical => '⚠ critical — review before running',
      DangerSeverity.warning => '⚠ review before running',
      null => s.explanation.isNotEmpty ? s.explanation : 'Inserted into prompt',
    };
    showTopToast(
      overlay,
      message: 'Inserted: ${s.command}\n$label',
      background: danger == DangerSeverity.critical
          ? const Color(0xFF8E1519)
          : null,
      duration: Duration(seconds: danger == null ? 4 : 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_fix_high, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Generate a command',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'for ${widget.session.config.label}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _input,
                autofocus: true,
                maxLines: 1,
                textInputAction: TextInputAction.go,
                decoration: const InputDecoration(
                  labelText: 'Describe what you want to do',
                  hintText: 'e.g. find the 10 largest files under /var',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _generate(),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _includeContext,
                onChanged: (v) => setState(() => _includeContext = v ?? true),
                title: const Text('Use recent terminal output as context'),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Failed: $_error',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _busy ? null : _generate,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.keyboard_return),
                    label: const Text('Generate & insert'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
