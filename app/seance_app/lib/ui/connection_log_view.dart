import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'top_toast.dart';

/// A collapsible view of a raw SSH connection transcript, with a copy button.
///
/// Takes the text rather than a session so both places that show a transcript
/// — a failed terminal tab and the server editor's connection test — read the
/// same, including the "(no log captured)" placeholder and the copy affordance
/// people reach for when they are about to paste it into a bug report.
class ConnectionLogView extends StatelessWidget {
  final String text;
  const ConnectionLogView({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Connection log'),
        childrenPadding: EdgeInsets.zero,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: text.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: text));
                      showTopToastIn(context, message: 'Log copied');
                    },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
            ),
          ),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                text.isEmpty ? '(no log captured)' : text,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
