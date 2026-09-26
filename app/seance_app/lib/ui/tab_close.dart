import 'package:flutter/material.dart';

import '../app_state.dart';
import 'session_label.dart';

/// Close [tabId] behind the guards its close button has always had: an
/// editor with unsaved changes asks first; a session asks for each of its
/// editors (they close with it) and before deleting the managed local copies
/// its close takes with it. Declining any of them leaves every tab open.
///
/// The tab strip's close button and the close-tab shortcut both come here,
/// so no way of closing a tab can skip a guard another one has (SEA-009).
/// [context] hosts the dialogs; it must be under the app's navigator.
Future<void> confirmAndCloseTab(
  BuildContext context,
  AppState state,
  String tabId,
) async {
  final tab = state.tabById(tabId);
  if (tab == null) return;
  if (tab is EditorTab) {
    if (await _editorMayClose(context, tab)) await state.closeTab(tabId);
    return;
  }
  if (tab is! TerminalSession) return;
  // Its editor tabs die with the session (the checkouts they write to are
  // deleted): a declined unsaved-buffer confirm aborts the whole close.
  final session = tab;
  for (final editor in state.editorTabsOwnedBy(session)) {
    if (!await _editorMayClose(context, editor)) return;
  }
  final localCopyCount =
      (session.files?.localCopies.length ?? 0) +
      session.retainedLocalCopies.length;
  if (localCopyCount > 0) {
    // The guard lives here rather than above: a session with no local
    // copies needs no dialog and no context, so it still closes.
    if (!context.mounted) return;
    final close = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close session and local edits?'),
        content: Text(
          '$localCopyCount downloaded ${localCopyCount == 1 ? 'file has' : 'files have'} '
          'a managed local copy. Closing this tab deletes '
          '${localCopyCount == 1 ? 'it' : 'them'}, including changes that '
          'have not been uploaded.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close and Delete'),
          ),
        ],
      ),
    );
    if (close != true) return;
  }
  await state.closeTab(tabId);
}

/// Whether an editor tab's buffer may be dropped. A clean buffer needs no
/// ask; a dirty one is asked through the editor's own confirm dialog when
/// its state is mounted, or — when the widget is somehow unreachable —
/// through a plain dialog on the caller's context, so a close never
/// silently does nothing while unsaved text is at stake.
Future<bool> _editorMayClose(BuildContext context, EditorTab tab) async {
  if (!tab.dirty.value) return true;
  final confirmed = await tab.editorKey.currentState?.confirmDiscard();
  if (confirmed != null) return confirmed;
  if (!context.mounted) return false;
  final discard = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Discard unsaved changes?'),
      content: Text(
        '${sanitizeRemoteLabel(tab.remotePath)} has unsaved changes.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep editing'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return discard ?? false;
}
