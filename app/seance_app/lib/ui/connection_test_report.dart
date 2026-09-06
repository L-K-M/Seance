import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import 'connection_log_view.dart';

/// What a "Test connection" attempt found, as the server editor shows it.
///
/// Public and standalone so a widget test can assert what each outcome reads
/// like without standing up an `AppState`. The failure path matters most: it
/// is met when something is already wrong, so it has to say *what* rather than
/// only that the test failed — and it shows the same summary a real failed
/// connection does, from the same source, so the two can never disagree about
/// one host.
class ConnectionTestReport extends StatelessWidget {
  final ConnectionTestResult result;
  const ConnectionTestReport({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = result.ok ? scheme.primary : scheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              result.ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 18,
              color: accent,
              // The colours differ by hue alone, which is the one difference
              // some readers do not get; the icon is named so the outcome is
              // also spoken.
              semanticLabel: result.ok
                  ? 'Connection test succeeded'
                  : 'Connection test failed',
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                result.summary,
                style: theme.textTheme.bodyMedium?.copyWith(color: accent),
              ),
            ),
          ],
        ),
        for (final note in result.notes) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: SelectableText(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
        ],
        const SizedBox(height: 4),
        ConnectionLogView(text: result.log),
      ],
    );
  }
}
