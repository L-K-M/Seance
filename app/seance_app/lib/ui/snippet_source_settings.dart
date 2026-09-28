import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../services/settings_backend.dart';
import 'settings_layout.dart';
import 'top_toast.dart';

/// Settings ▸ Snippets: the snippet sources — remote files of read-only
/// snippets, such as a raw file in a private git repository, which the
/// Snippets tab lists under each source's name.
class SnippetSourceSettings extends StatelessWidget {
  const SnippetSourceSettings({super.key, required this.backend});

  final SettingsBackend backend;

  static const String _formatHelp =
      'A snippet source is a JSON file Séance fetches over HTTPS, for example '
      'the raw URL of a file in a git repository:\n\n'
      '{"version": 1, "snippets": [\n'
      '  {"id": "disk-usage", "title": "Disk usage",\n'
      '   "body": "du -sh {{path}}"}\n'
      ']}\n\n'
      'Each id should stay the same when the snippet is edited. Unknown '
      'fields are ignored and invalid entries are skipped.\n\n'
      'Séance sends the access token as "Authorization: Bearer <token>", '
      'which Forgejo, Gitea, GitHub and GitLab accept for raw files. Use a '
      'read-only token. It is kept in the encrypted vault and reaches your '
      'other devices only with "Sync saved passwords & keys" on.\n\n'
      'Remote snippets are read-only here. Inserting one works like a local '
      'snippet: it is pasted into the prompt, never run.';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: backend,
      builder: (context, _) {
        final sources = backend.snippetSources;
        return SettingsPage(
          storageKey: const PageStorageKey('snippet-settings'),
          children: [
            Row(
              children: [
                const Expanded(
                  child: SettingsSectionHeader(
                    'Snippet sources',
                    helpTitle: 'About snippet sources',
                    help: _formatHelp,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _edit(context, null),
                  icon: const Icon(Icons.add),
                  label: const Text('Add source'),
                ),
              ],
            ),
            Text(
              'Subscribe to a JSON file of snippets, such as one in a private '
              'git repository. Its snippets appear read-only in the Snippets '
              'tab and refresh when Séance starts.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (sources.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No snippet sources yet.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              for (final source in sources)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_download_outlined),
                  title: Text(source.name),
                  subtitle: Text(
                    '${source.url}\n'
                    '${source.hasToken ? 'Access token set' : 'No access token'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _edit(context, source),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Source actions',
                    onSelected: (action) {
                      if (action == 'edit') _edit(context, source);
                      if (action == 'remove') _remove(context, source);
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit…')),
                      PopupMenuItem(value: 'remove', child: Text('Remove…')),
                    ],
                  ),
                ),
          ],
        );
      },
    );
  }

  Future<void> _edit(BuildContext context, SnippetSourceSummary? existing) =>
      showDialog<void>(
        context: context,
        builder: (_) =>
            _SnippetSourceDialog(backend: backend, existing: existing),
      );

  Future<void> _remove(
    BuildContext context,
    SnippetSourceSummary source,
  ) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${source.name}"?'),
        content: const Text(
          'Its snippets disappear from the Snippets tab on all your devices, '
          'and its access token is deleted from this device. The file itself '
          'is not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await backend.deleteSnippetSource(source.id);
    } catch (e) {
      showTopToast(overlay, message: 'Could not remove: $e');
    }
  }
}

class _SnippetSourceDialog extends StatefulWidget {
  const _SnippetSourceDialog({required this.backend, this.existing});

  final SettingsBackend backend;
  final SnippetSourceSummary? existing;

  @override
  State<_SnippetSourceDialog> createState() => _SnippetSourceDialogState();
}

class _SnippetSourceDialogState extends State<_SnippetSourceDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  final _token = TextEditingController();
  bool _removeToken = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.backend.saveSnippetSource(
        SnippetSourceDraft(
          id: widget.existing?.id,
          name: _name.text,
          url: _url.text,
          token: _token.text,
          removeToken: _removeToken,
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasToken = widget.existing?.hasToken ?? false;
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add snippet source' : 'Edit snippet source',
      ),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: widget.existing == null,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'e.g. Team snippets',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Give the source a name.'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'URL of the JSON file',
                    hintText:
                        'https://git.example.com/me/snippets/raw/branch/main/snippets.json',
                  ),
                  validator: (v) => validateSnippetSourceUrl(v ?? ''),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _token,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  enabled: !_removeToken,
                  decoration: InputDecoration(
                    labelText: 'Access token (optional)',
                    helperText: hasToken
                        ? 'Leave blank to keep the stored token.'
                        : 'Sent as a Bearer token. Stored in the vault.',
                  ),
                ),
                if (hasToken)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Remove the stored token'),
                    value: _removeToken,
                    onChanged: _saving
                        ? null
                        : (v) => setState(() {
                            _removeToken = v ?? false;
                            if (_removeToken) _token.clear();
                          }),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
