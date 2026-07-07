import 'package:flutter/material.dart';

/// Prompts for keyboard-interactive auth (e.g. a 2FA/TOTP code). Returns one
/// answer per prompt, in order. An empty list cancels the attempt.
Future<List<String>> showKeyboardInteractiveDialog(
  BuildContext context,
  List<String> prompts,
  String name,
  String instruction,
) async {
  final controllers = [for (final _ in prompts) TextEditingController()];
  final result = await showDialog<List<String>>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      return AlertDialog(
        title: Text(name.isEmpty ? 'Authentication' : name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (instruction.isNotEmpty) ...[
              Text(instruction),
              const SizedBox(height: 12),
            ],
            for (var i = 0; i < prompts.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: controllers[i],
                  autofocus: i == 0,
                  decoration: InputDecoration(labelText: prompts[i]),
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
                Navigator.pop(context, [for (final c in controllers) c.text]),
            child: const Text('Submit'),
          ),
        ],
      );
    },
  );
  for (final c in controllers) {
    c.dispose();
  }
  return result ?? const <String>[];
}
