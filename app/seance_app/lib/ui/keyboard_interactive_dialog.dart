import 'package:flutter/material.dart';

/// Prompts for keyboard-interactive auth (e.g. a 2FA/TOTP code). Returns one
/// answer per prompt, in order. An empty list cancels the attempt.
Future<List<String>> showKeyboardInteractiveDialog(
  BuildContext context,
  List<String> prompts,
  String name,
  String instruction,
) async {
  final result = await showDialog<List<String>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _KeyboardInteractiveDialog(
      prompts: prompts,
      name: name,
      instruction: instruction,
    ),
  );
  return result ?? const <String>[];
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
  const _KeyboardInteractiveDialog({
    required this.prompts,
    required this.name,
    required this.instruction,
  });

  final List<String> prompts;
  final String name;
  final String instruction;

  @override
  State<_KeyboardInteractiveDialog> createState() =>
      _KeyboardInteractiveDialogState();
}

class _KeyboardInteractiveDialogState
    extends State<_KeyboardInteractiveDialog> {
  late final List<TextEditingController> _controllers = [
    for (final _ in widget.prompts) TextEditingController(),
  ];

  final Set<int> _revealed = {};

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
      title: Text(widget.name.isEmpty ? 'Authentication' : widget.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.instruction.isNotEmpty) ...[
            Text(widget.instruction),
            const SizedBox(height: 12),
          ],
          for (var i = 0; i < widget.prompts.length; i++)
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
                  labelText: widget.prompts[i],
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
          onPressed: () => Navigator.pop(context, <String>[]),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, [for (final c in _controllers) c.text]),
          child: const Text('Submit'),
        ),
      ],
    );
  }
}
