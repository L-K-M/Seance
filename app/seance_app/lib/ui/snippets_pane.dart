import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import 'top_toast.dart';

/// The Snippets tab: reusable command templates, synced across devices. Tapping
/// one inserts it into the active terminal's prompt; if it has `{{placeholder}}`
/// tokens the user is asked to fill them in first. Never runs anything.
class SnippetsPane extends StatefulWidget {
  const SnippetsPane({super.key});

  @override
  State<SnippetsPane> createState() => _SnippetsPaneState();
}

class _SnippetsPaneState extends State<SnippetsPane> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final all = state.snippets;
        final q = _query.trim().toLowerCase();
        final filtered = q.isEmpty
            ? all
            : all
                  .where(
                    (s) =>
                        s.title.toLowerCase().contains(q) ||
                        s.body.toLowerCase().contains(q),
                  )
                  .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.bookmarks_outlined, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Snippets',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'New snippet',
                    icon: const Icon(Icons.add),
                    onPressed: () => _edit(context, state, null),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // A filter box, once there are enough snippets to warrant scrolling.
            if (all.length > 4)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: 'Filter snippets…',
                    border: const OutlineInputBorder(),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => setState(() {
                              _search.clear();
                              _query = '';
                            }),
                          ),
                  ),
                ),
              ),
            if (state.commandSuggestions.isNotEmpty) _Suggestions(state: state),
            Expanded(
              child: all.isEmpty
                  ? const _SnippetsEmpty()
                  : filtered.isEmpty
                  ? const _NoMatches()
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final s = filtered[i];
                        final count = s.placeholders.length;
                        return ListTile(
                          title: Text(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            count > 0
                                ? '$count placeholder${count == 1 ? '' : 's'} · ${_preview(s.body)}'
                                : _preview(s.body),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                          onTap: () => _insert(context, state, s),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) => v == 'edit'
                                ? _edit(context, state, s)
                                : _delete(context, state, s),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  static String _preview(String body) => body.replaceAll('\n', ' ').trim();

  Future<void> _insert(
    BuildContext context,
    AppState state,
    Snippet snippet,
  ) async {
    final session = state.activeSession;
    final messenger = ScaffoldMessenger.of(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    if (session == null || !session.isConnected) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Open a connected session first.')),
      );
      return;
    }
    var text = snippet.body;
    final names = snippet.placeholders;
    if (names.isNotEmpty) {
      final values = await showPlaceholderDialog(context, snippet.title, names);
      if (values == null) return; // cancelled
      text = snippet.fill(values);
    }
    try {
      text = PasteSanitizer.sanitize(text);
    } on UnsafePasteException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.reason)));
      return;
    }
    session.engine.injectInput(text);
    // Top toast so it doesn't cover the prompt the snippet was inserted into.
    showTopToast(
      overlay,
      message: 'Inserted "${snippet.title}" into the prompt',
      duration: const Duration(seconds: 3),
    );
  }

  Future<void> _edit(
    BuildContext context,
    AppState state,
    Snippet? existing,
  ) async {
    await showSnippetEditor(context, state, existing);
  }

  Future<void> _delete(
    BuildContext context,
    AppState state,
    Snippet snippet,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${snippet.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await state.deleteSnippet(snippet.id);
  }
}

/// Frequently-run commands (from the local, opt-in history) that aren't
/// snippets yet. Save one to turn it into a real, syncable snippet, or dismiss
/// it to stop it being suggested.
class _Suggestions extends StatelessWidget {
  final AppState state;
  const _Suggestions({required this.state});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Row(
              children: [
                Icon(Icons.lightbulb_outline, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Suggested from your history',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
          for (final cmd in state.commandSuggestions)
            ListTile(
              dense: true,
              title: Text(
                cmd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Save as snippet',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add, size: 20),
                    onPressed: () => state.addSuggestionAsSnippet(cmd),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => state.dismissSuggestion(cmd),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

class _SnippetsEmpty extends StatelessWidget {
  const _SnippetsEmpty();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bookmarks_outlined, size: 36),
            const SizedBox(height: 12),
            Text(
              'No snippets yet',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Save commands you reuse. Add {{placeholders}} and you\'ll be '
              'asked to fill them in each time you insert one. Snippets sync '
              'across your devices.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a filter matches no snippets.
class _NoMatches extends StatelessWidget {
  const _NoMatches();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No snippets match your filter.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

/// Add or edit a snippet.
Future<void> showSnippetEditor(
  BuildContext context,
  AppState state,
  Snippet? existing,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SnippetEditor(state: state, existing: existing),
  );
}

class _SnippetEditor extends StatefulWidget {
  final AppState state;
  final Snippet? existing;
  const _SnippetEditor({required this.state, this.existing});

  @override
  State<_SnippetEditor> createState() => _SnippetEditorState();
}

class _SnippetEditorState extends State<_SnippetEditor> {
  late final TextEditingController _title = TextEditingController(
    text: widget.existing?.title ?? '',
  );
  late final TextEditingController _body = TextEditingController(
    text: widget.existing?.body ?? '',
  );

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final body = _body.text;
    if (title.isEmpty || body.trim().isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = widget.existing;
    final snippet = existing == null
        ? Snippet(
            id: uuidV4(),
            title: title,
            body: body,
            createdAt: now,
            updatedAt: now,
          )
        : existing.copyWith(title: title, body: body, updatedAt: now);
    await widget.state.saveSnippet(snippet);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New snippet' : 'Edit snippet'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              minLines: 3,
              maxLines: 10,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Command',
                hintText: r'e.g. tail -f {{logfile}} | grep {{pattern}}',
                helperText: r'Use {{name}} for values to fill in on insert',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Ask the user to fill in [names]; returns name→value, or null if cancelled.
Future<Map<String, String>?> showPlaceholderDialog(
  BuildContext context,
  String title,
  List<String> names,
) async {
  final controllers = {for (final n in names) n: TextEditingController()};
  try {
    return await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < names.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: controllers[names[i]],
                      autofocus: i == 0,
                      decoration: InputDecoration(
                        labelText: names[i],
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              for (final e in controllers.entries) e.key: e.value.text,
            }),
            child: const Text('Insert'),
          ),
        ],
      ),
    );
  } finally {
    for (final c in controllers.values) {
      c.dispose();
    }
  }
}
