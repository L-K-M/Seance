import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

/// Prompts for keyboard-interactive auth (e.g. a 2FA/TOTP code). Returns one
/// answer per prompt, in order. An empty list cancels the attempt.
Future<List<String>> showKeyboardInteractiveDialog(
  BuildContext context,
  KeyboardInteractiveChallenge challenge,
) async {
  final result = await showDialog<List<String>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _KeyboardInteractiveDialog(challenge: challenge),
  );
  return result ?? const <String>[];
}

String _trustedTarget(ServerConfig server) {
  final rawHost = server.host;
  final host = rawHost.contains(':') &&
          !(rawHost.startsWith('[') && rawHost.endsWith(']'))
      ? '[$rawHost]'
      : rawHost;
  return '${server.username}@$host:${server.port}';
}

/// Owns the prompt controllers in its [State] so they are disposed in
/// [State.dispose] — after the route's exit animation, once the fields are
/// truly unmounted. Disposing right after `await showDialog(...)` is too
/// early: the fields stay mounted through the reverse transition and the
/// framework can still write to a controller (e.g. `clearComposing()` when
/// the focused field loses focus) — a use-after-dispose that throws in debug
/// builds whenever an IME composing region is active. Same lifecycle as the
/// snippet placeholder dialog (regression: test/placeholder_dialog_test.dart).
class _KeyboardInteractiveDialog extends StatefulWidget {
  const _KeyboardInteractiveDialog({required this.challenge});

  final KeyboardInteractiveChallenge challenge;

  @override
  State<_KeyboardInteractiveDialog> createState() =>
      _KeyboardInteractiveDialogState();
}

class _KeyboardInteractiveDialogState
    extends State<_KeyboardInteractiveDialog> {
  late final List<TextEditingController> _controllers = [
    for (final _ in widget.challenge.prompts) TextEditingController(),
  ];

  final Set<int> _revealed = {};

  // Only the dialog's own route may be popped: a rapid second activation
  // during the exit animation — or a callback from a dialog obscured by a
  // newer route — would otherwise pop whatever sits below instead.
  void _close(List<String> answers) {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.pop(context, answers);
  }

  void _submit() =>
      _close([for (final controller in _controllers) controller.text]);

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Long challenges must remain reachable above the software keyboard.
      scrollable: true,
      title: const Text('Authentication'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Request from',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          SelectableText(
            _trustedTarget(widget.challenge.server),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          if (widget.challenge.name.isNotEmpty ||
              widget.challenge.instruction.isNotEmpty) ...[
            Text(
              'Server message',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            if (widget.challenge.name.isNotEmpty)
              Text(widget.challenge.name),
            if (widget.challenge.instruction.isNotEmpty)
              Text(widget.challenge.instruction),
            const SizedBox(height: 12),
          ],
          for (var i = 0; i < widget.challenge.prompts.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _controllers[i],
                autofocus: i == 0,
                keyboardType: TextInputType.visiblePassword,
                // Echo metadata is absent; reveal only on explicit user request.
                obscureText: !_revealed.contains(i),
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  labelText: widget.challenge.prompts[i],
                  suffixIcon: IconButton(
                    tooltip: _revealed.contains(i) ? 'Hide answer' : 'Show answer',
                    icon: Icon(_revealed.contains(i)
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () => setState(() {
                      if (!_revealed.remove(i)) _revealed.add(i);
                    }),
                  ),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => _close(const <String>[]),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Submit'),
        ),
      ],
    );
  }
}
