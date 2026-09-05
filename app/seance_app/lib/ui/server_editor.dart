import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../services/app_settings.dart';
import 'server_appearance.dart';
import 'server_grouping.dart';
import 'top_toast.dart';

/// Add or edit a server. Password / private-key material is written to the
/// encrypted vault; the config stores only a reference.
Future<void> showServerEditor(
    BuildContext context, AppState state, ServerConfig? existing) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: _ServerEditor(state: state, existing: existing),
      ),
    ),
  );
}

class _ServerEditor extends StatefulWidget {
  final AppState state;
  final ServerConfig? existing;
  const _ServerEditor({required this.state, this.existing});

  @override
  State<_ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<_ServerEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _label;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _group;
  final _password = TextEditingController();
  final _keyPem = TextEditingController();
  final _keyPath = TextEditingController();
  final _keyPassphrase = TextEditingController();
  final _loginScript = TextEditingController();

  late AuthMethod _auth;
  late ServerColor? _color;
  late ServerIcon? _icon;
  bool _referenceKeyFile = true;
  late bool _syncSecret;
  late bool _excludeFromSync;
  bool _busy = false;

  /// The security-scoped bookmark backing [_keyPath]'s current text, and the
  /// path it was minted for. Set by Browse… (or loaded for an existing
  /// server); dropped at save when the user hand-edits the path afterwards,
  /// since a bookmark only opens the exact file it was created from.
  String? _keyBookmark;
  String? _keyBookmarkPath;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _label = TextEditingController(text: e?.label ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? 22}');
    _user = TextEditingController(text: e?.username ?? '');
    _group = TextEditingController(text: e?.group ?? '');
    _color = e?.color;
    _icon = e?.icon;
    // Default new servers to password: ssh-agent is offered but not yet
    // supported by the backend, so defaulting to it would dead-end the very
    // first "add a server and connect".
    _auth = e?.authMethod ?? AuthMethod.password;
    _keyPath.text = e?.identityFilePath ?? '';
    _referenceKeyFile = e?.identityFilePath != null;
    _loginScript.text = e?.loginScript ?? '';
    if (e != null) {
      // Load the stored grant with the path it was actually minted for (which
      // a synced edit may have diverged from), so re-saving can't re-bless a
      // bookmark under a path it doesn't open.
      final stored =
          widget.state.services.settings.identityFileBookmarks[e.id];
      _keyBookmark = stored?.bookmark;
      _keyBookmarkPath = stored?.path;
    }
    // New credentials default to syncable (a no-op until the global "sync saved
    // passwords & keys" is on); existing servers keep their stored choice.
    _syncSecret = e?.syncSecret ?? true;
    _excludeFromSync = e?.excludeFromSync ?? false;
  }

  @override
  void dispose() {
    for (final c in [
      _label,
      _host,
      _port,
      _user,
      _group,
      _password,
      _keyPem,
      _keyPath,
      _keyPassphrase,
      _loginScript
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? 'Add server' : 'Edit server',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextFormField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label'),
              validator: _required,
            ),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _host,
                    decoration: const InputDecoration(labelText: 'Host'),
                    validator: _required,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    decoration: const InputDecoration(labelText: 'Port'),
                    keyboardType: TextInputType.number,
                    validator: _validatePort,
                  ),
                ),
              ],
            ),
            TextFormField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Username'),
              validator: _required,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<AuthMethod>(
              initialValue: _auth,
              decoration: const InputDecoration(labelText: 'Authentication'),
              items: const [
                DropdownMenuItem(
                    value: AuthMethod.agent, child: Text('ssh-agent')),
                DropdownMenuItem(
                    value: AuthMethod.password, child: Text('Password')),
                DropdownMenuItem(
                    value: AuthMethod.privateKey, child: Text('Private key')),
              ],
              onChanged: (v) => setState(() => _auth = v ?? AuthMethod.agent),
            ),
            const SizedBox(height: 8),
            ..._authFields(),
            const SizedBox(height: 20),
            ..._syncFields(),
            const SizedBox(height: 20),
            ..._loginScriptFields(),
            const SizedBox(height: 20),
            ..._appearanceFields(),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _authFields() {
    switch (_auth) {
      case AuthMethod.agent:
        return [
          const Text('Keys are provided by your ssh-agent; nothing is stored.'),
          const SizedBox(height: 8),
          Text(
            'ssh-agent auth isn\'t supported yet — connecting will fail. '
            'Choose Password or Private key for now.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ];
      case AuthMethod.password:
        return [
          TextFormField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          _syncSecretToggle(),
        ];
      case AuthMethod.privateKey:
        return [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Reference a key file on disk'),
            subtitle: const Text("Don't store the key — read it at connect"),
            value: _referenceKeyFile,
            onChanged: (v) => setState(() => _referenceKeyFile = v),
          ),
          if (_referenceKeyFile)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _keyPath,
                    decoration: const InputDecoration(
                        labelText: 'Identity file path',
                        hintText: '~/.ssh/id_ed25519'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _browseForKey,
                  child: const Text('Browse…'),
                ),
              ],
            )
          else
            TextFormField(
              controller: _keyPem,
              maxLines: 5,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                  labelText: 'Private key (PEM/OpenSSH)',
                  border: OutlineInputBorder()),
            ),
          TextFormField(
            controller: _keyPassphrase,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'Key passphrase (optional)'),
          ),
          // Only the stored key (not the referenced-file case) is a secret that
          // could sync.
          if (!_referenceKeyFile) _syncSecretToggle(),
        ];
    }
  }

  /// An optional command to run in this server's shell once it opens. Typed
  /// into the session rather than executed on a side channel, so `cd`, `tmux
  /// attach`, and friends do what they would if the user had typed them —
  /// which is also the honest description to show for it.
  List<Widget> _loginScriptFields() {
    return [
      const Divider(),
      const SizedBox(height: 8),
      TextFormField(
        controller: _loginScript,
        maxLines: 3,
        minLines: 1,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: const InputDecoration(
          labelText: 'Login script (optional)',
          hintText: 'e.g. cd ~/work && tmux attach -t work || tmux new -s work',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        'Runs as if typed at the prompt right after connecting. Its text and '
        'output land in scrollback — keep secrets out. Blank for none.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).hintColor,
            ),
      ),
    ];
  }

  /// How this server is filed and marked in the list: its group, its accent
  /// colour, and its icon. All three are optional and none of them affect how
  /// the connection is made — they exist so a list of thirty boxes can be read
  /// at a glance, and so "am I on prod?" has an answer you don't have to read.
  List<Widget> _appearanceFields() {
    final existing = existingServerGroups(widget.state.servers);
    return [
      const Divider(),
      const SizedBox(height: 8),
      Row(
        children: [
          // Colour and icon combine, so they are previewed together rather
          // than left to be imagined from two separate pickers.
          ServerBadge(color: _color, icon: _icon),
          const SizedBox(width: 12),
          Text('Appearance', style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _group,
        decoration: const InputDecoration(
          labelText: 'Group',
          hintText: 'Production, Home lab, … — blank for none',
        ),
      ),
      if (existing.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            // Retyping an existing group by hand is how you end up with
            // "Prod " and "prodution" as separate sections. Case already
            // folds together; the chips take care of the rest.
            for (final group in existing)
              ActionChip(
                label: Text(group),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _group.text = group),
              ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      Text('Colour', style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final color in <ServerColor?>[null, ...ServerColor.values])
            _ColorSwatch(
              color: color,
              selected: _color == color,
              onTap: () => setState(() => _color = color),
            ),
        ],
      ),
      const SizedBox(height: 16),
      Text('Icon', style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final icon in <ServerIcon?>[null, ...ServerIcon.values])
            _IconChoice(
              icon: icon,
              accent: _color,
              selected: _icon == icon,
              onTap: () => setState(() => _icon = icon),
            ),
        ],
      ),
    ];
  }

  /// Per-server opt-in for including this credential in sync. Gated globally by
  /// the "Sync saved passwords & keys" setting, so it's a no-op until that's on.
  ///
  /// Excluding the whole server settles the question, so the switch reads off
  /// and takes no input then. What it *stores* is still the user's own choice
  /// ([_syncSecret]) rather than the displayed false: clearing the exclusion
  /// has to give them back the answer they picked, not silently opt their
  /// credential out on the way through.
  Widget _syncSecretToggle() => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Allow this credential to sync'),
        subtitle: Text(_excludeFromSync
            ? 'Not used while this server is excluded from sync.'
            : 'End-to-end encrypted. Also needs sync set up with '
                '"Sync saved passwords & keys" enabled.'),
        value: _syncSecret && !_excludeFromSync,
        onChanged:
            _excludeFromSync ? null : (v) => setState(() => _syncSecret = v),
      );

  /// Whether this server takes part in sync at all.
  ///
  /// Worth saying out loud in the subtitle, because "exclude" understates what
  /// the switch does to a server that has already synced: the retraction is a
  /// tombstone, so the other devices lose their copy. Only this device keeps
  /// one, which is the point — but it is not something to find out afterwards.
  List<Widget> _syncFields() => [
        const Divider(),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Exclude from sync'),
          subtitle: Text(_excludeFromSync
              ? 'Kept on this device only. A copy that synced earlier is '
                  'removed from the sync server and from your other devices.'
              : 'Keep this server on this device only — never upload it.'),
          value: _excludeFromSync,
          onChanged: (v) => setState(() => _excludeFromSync = v),
        ),
      ];

  /// Pick an identity file. On macOS this also mints the security-scoped
  /// bookmark that keeps a key outside ~/.ssh readable across relaunches.
  Future<void> _browseForKey() async {
    final picked = await widget.state.services.identityBookmarks.pick();
    if (picked == null || !mounted) return;
    setState(() {
      _keyPath.text = picked.path;
      _keyBookmark = picked.bookmark;
      _keyBookmarkPath = picked.bookmark == null ? null : picked.path;
    });
  }

  static String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  static String? _validatePort(String? v) {
    final port = int.tryParse((v ?? '').trim());
    if (port == null || port < 1 || port > 65535) return '1–65535';
    return null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = widget.existing;
    final id = existing?.id ?? uuidV4();

    String? secretRef = existing?.secretRef;
    Secret? secret;

    if (_auth == AuthMethod.password && _password.text.isNotEmpty) {
      secretRef ??= uuidV4();
      secret = Secret(
          id: secretRef, kind: SecretKind.password, value: _password.text);
    } else if (_auth == AuthMethod.privateKey &&
        !_referenceKeyFile &&
        _keyPem.text.isNotEmpty) {
      // Guard on isNotEmpty (like the password branch): the PEM field starts
      // blank when editing an existing server, so without this, editing any
      // other field and saving would overwrite the stored key with "".
      secretRef ??= uuidV4();
      secret = Secret(
        id: secretRef,
        kind: SecretKind.privateKey,
        value: _keyPem.text,
        keyPassphrase:
            _keyPassphrase.text.isEmpty ? null : _keyPassphrase.text,
      );
    }

    final identityFilePath =
        (_auth == AuthMethod.privateKey && _referenceKeyFile)
            ? _keyPath.text.trim()
            : null;
    final config = ServerConfig(
      id: id,
      label: _label.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text) ?? 22,
      username: _user.text.trim(),
      authMethod: _auth,
      secretRef: secret != null ? secretRef : (existing?.secretRef),
      identityFilePath: identityFilePath,
      syncSecret: _syncSecret,
      // Normalized here rather than trusted from the field, so a trailing
      // space typed into the group name can't fork a second section that
      // looks identical to the one the user meant to join.
      group: normalizeServerGroup(_group.text),
      color: _color,
      icon: _icon,
      loginScript: normalizeLoginScript(_loginScript.text),
      excludeFromSync: _excludeFromSync,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );

    // Trim-insensitively: the saved path is trimmed, while a Browse…-picked
    // path is verbatim (macOS filenames may carry edge whitespace — the
    // bookmark, which opens by file identity, still works there).
    final bookmarkMatchesPath = identityFilePath != null &&
        _keyBookmark != null &&
        identityFilePath == _keyBookmarkPath?.trim();
    try {
      // The vault write inside throws (VaultLockedException) when the OS
      // keyring is unavailable — tell the user instead of wedging the editor
      // with _busy stuck on.
      await widget.state.saveServer(
        config,
        secret: secret,
        identityFileBookmark: bookmarkMatchesPath
            ? IdentityFileBookmark(
                path: identityFilePath, bookmark: _keyBookmark!)
            : null,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showTopToastIn(context, message: 'Could not save: $e');
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }
}

/// One choice in the colour row. The first is null — "no colour" — drawn as
/// the same neutral tone an untagged server gets in the list, so the option
/// shows what it does rather than describing it.
class _ColorSwatch extends StatelessWidget {
  final ServerColor? color;
  final bool selected;
  final VoidCallback onTap;

  static const double _size = 34;

  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = serverAccent(context, color);
    final fill = accent?.container ?? scheme.surfaceContainerHighest;
    final foreground = accent?.onContainer ?? scheme.onSurfaceVariant;
    return Tooltip(
      message: serverColorLabel(color),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2.5 : 1,
            ),
          ),
          // A tick rather than a ring alone: at 34px on a phone the ring is
          // easy to miss, and the swatches differ only by hue.
          child: selected
              ? Icon(Icons.check, size: 16, color: foreground)
              : null,
        ),
      ),
    );
  }
}

/// One choice in the icon row, previewed on the colour currently selected so
/// the pair can be judged together.
class _IconChoice extends StatelessWidget {
  final ServerIcon? icon;
  final ServerColor? accent;
  final bool selected;
  final VoidCallback onTap;

  static const double _size = 34;

  const _IconChoice({
    required this.icon,
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolved = serverAccent(context, accent);
    return Tooltip(
      message: serverIconLabel(icon),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            color: resolved?.container ?? scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: Icon(
            serverIconData(icon),
            size: 18,
            color: resolved?.onContainer ?? scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
