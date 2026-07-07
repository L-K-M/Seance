import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

/// Shows the trust-on-first-use prompt. On a *changed* key this is a hard,
/// visually alarming block that requires explicit re-pinning — never a
/// one-click dismiss. Returns true to trust (and pin) the presented key.
Future<bool> showHostKeyDialog(
    BuildContext context, HostKeyDecision decision) async {
  final changed = decision.isChanged;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        icon: Icon(changed ? Icons.gpp_bad : Icons.verified_user_outlined,
            color: changed ? scheme.error : null),
        title: Text(changed ? 'HOST KEY CHANGED' : 'Unknown host key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (changed)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'The key for ${decision.presented.host} does not match the '
                  'one you previously trusted. This can mean a man-in-the-middle '
                  'attack. Only continue if you know why the key changed.',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            Text('${decision.presented.host}:${decision.presented.port}'),
            const SizedBox(height: 8),
            _Fingerprint(
                label: changed ? 'New key' : 'Fingerprint',
                type: decision.presented.type,
                value: decision.presented.fingerprintSha256),
            if (changed && decision.pinned != null) ...[
              const SizedBox(height: 8),
              _Fingerprint(
                  label: 'Previously trusted',
                  type: decision.pinned!.type,
                  value: decision.pinned!.fingerprintSha256),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: changed
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError)
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(changed ? 'Trust the new key' : 'Trust and connect'),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

class _Fingerprint extends StatelessWidget {
  final String label;
  final String type;
  final String value;
  const _Fingerprint(
      {required this.label, required this.type, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        SelectableText(
          '$type\n$value',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ],
    );
  }
}
