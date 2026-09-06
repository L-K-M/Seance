import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../services/app_settings.dart';
import 'connection_test_report.dart';
import 'server_appearance.dart';
import 'server_grouping.dart';
import 'top_toast.dart';

/// Whether turning "exclude from sync" on needs confirming before it takes.
///
/// Only when there is something to retract: a server being added has never
/// been anywhere, one already excluded has been retracted once already, and
/// with no sync account configured there is no other device that could lose
/// it. Turning the switch back off is never destructive.
///
/// [syncConfigured] is read as it is *now*, which is not quite the same
/// question. A server that synced before the account was unlinked still has a
/// copy out there, and the stored exclusion would retract it on the first
/// round after re-linking, unprompted. Answering that properly needs a "has
/// ever synced" bit this device does not keep, and the alternative — always
/// confirming — puts a dialog in front of someone who has never had a sync
/// account at all. The narrow gap is recorded here rather than papered over.
///
/// A top-level function so the rule can be asserted directly — no widget test
/// in this app stands up an [AppState], and this is the part of the dialog
/// worth pinning down.
bool excludingNeedsConfirmation({
  required ServerConfig? existing,
  required bool syncConfigured,
}) => existing != null && !existing.excludeFromSync && syncConfigured;

/// The dialog [excludingNeedsConfirmation] gates, as a function so a test can
/// tap its buttons without standing up an editor or an [AppState].
///
/// Dismissing it — barrier tap, Escape — resolves to null, which has to read
/// as "no": the caller is about to delete data on other devices, and the one
/// input that means the user never answered must not be the one that proceeds.
Future<bool> confirmSyncExclusion(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Exclude from sync?'),
      content: const Text(
        'If this server synced earlier, it is removed from the sync server '
        'and from your other devices, along with any credential that synced '
        'with it. This device keeps its copy.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Exclude'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

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

  /// The id a *new* server will be saved under, minted once rather than per
  /// save so a test connection and the save that follows describe one server,
  /// and so a save that failed and is retried does not mint a second identity.
  final String _draftId = uuidV4();

  /// The connection test: whether one is running, what the last one found,
  /// and which attempt is current. The counter is the cancellation flag — the
  /// SSH layer has no cancel seam, so a superseded or abandoned attempt is
  /// left to finish and its result dropped, which is what the terminal pane
  /// does with a tab that closed mid-connect.
  bool _testing = false;
  ConnectionTestResult? _testResult;
  int _testAttempt = 0;

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
    for (final field in _connectionFields) {
      field.addListener(_dropTestResult);
    }
  }

  /// Every text field in the form, so [dispose] releases them all.
  List<TextEditingController> get _fields => [
        _label,
        _host,
        _port,
        _user,
        _group,
        _password,
        _keyPem,
        _keyPath,
        _keyPassphrase,
        _loginScript,
      ];

  /// The fields a connection test's outcome actually depends on.
  ///
  /// Narrower than [_fields] because [_dropTestResult] does not merely grey
  /// out a stale result — it bumps `_testAttempt`, which abandons a test
  /// still in flight. Renaming a server, moving it to another group or
  /// editing its login script cannot change what a connection does (the
  /// script is never executed, which the disclaimer beside it says), so
  /// discarding a result the user waited minutes for over a typo in the name
  /// is a cost with nothing bought for it.
  List<TextEditingController> get _connectionFields => [
        _host,
        _port,
        _user,
        _password,
        _keyPem,
        _keyPath,
        _keyPassphrase,
      ];

  /// Forget the last test result, and abandon one still running, because the
  /// form no longer describes what is being tested.
  ///
  /// A green "authenticated" sitting beside a host that has since been retyped
  /// reads as current, and the report's whole claim is that it describes the
  /// server about to be saved. An attempt *in flight* is the same problem
  /// arriving late, so the counter moves too and its result lands as
  /// superseded — which means clearing [_testing] here as well, or the Save
  /// button would stay disabled waiting for a result that will be dropped.
  ///
  /// Guarded so typing does not rebuild the dialog on every keystroke.
  void _dropTestResult() {
    _testAttempt++;
    if (_testResult != null || _testing) {
      setState(() {
        _testResult = null;
        _testing = false;
      });
    }
  }

  @override
  void dispose() {
    for (final c in _fields) {
      // Disposing drops the listeners with it; removing them first is only so
      // a late notification cannot reach setState on the way down.
      c.removeListener(_dropTestResult);
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
              // Through _dropTestResult, not a bare clear: the auth method is
              // baked into the config a test runs against, so one already in
              // flight is describing a credential the form no longer holds —
              // and would otherwise land looking current.
              onChanged: (v) {
                setState(() => _auth = v ?? AuthMethod.agent);
                _dropTestResult();
              },
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
              children: [
                OutlinedButton.icon(
                  onPressed: _busy || _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          // Labelled like the outcome icons this PR adds: a
                          // spinner is the one state with nothing to read, so
                          // without this a screen-reader user cannot tell a
                          // running test from a button that did nothing. The
                          // indicator's own parameter rather than a wrapping
                          // `Semantics`, which would merge a second node into
                          // its announcement.
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            semanticsLabel: 'Testing connection',
                          ),
                        )
                      : const Icon(Icons.wifi_tethering, size: 18),
                  label: Text(_testing ? 'Testing…' : 'Test connection'),
                ),
                const Spacer(),
                // Cancel stays live during a test: the attempt cannot be
                // stopped, but being unable to leave the dialog for the five
                // minutes an authentication may take is worse than letting it
                // finish unwatched.
                TextButton(
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                    // Not disabled while a test runs: an attempt can take minutes,
                    // and the only other way out was typing a character into
                    // any field to drop the test. Saving mid-test is sound —
                    // any edit that could make the two disagree already
                    // supersedes the attempt, and the save pops the editor, so
                    // the late result is discarded by the mounted check.
                    onPressed: _busy ? null : _save,
                    child: const Text('Save')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Testing authenticates without opening a shell or running the '
              'login script. A host key you approve here is trusted for the '
              'test only — the first real connection asks again.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 12),
              ConnectionTestReport(result: _testResult!),
            ],
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
            // Same as the auth dropdown: this switches the test between the
            // key on disk and the pasted one, so an attempt already running
            // is about the other of the two.
            onChanged: (v) {
              setState(() => _referenceKeyFile = v);
              _dropTestResult();
            },
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
          onChanged: (v) async {
            if (v && !await _confirmExclusion()) return;
            if (mounted) setState(() => _excludeFromSync = v);
          },
        ),
      ];

  /// Ask before an exclusion that reaches other devices.
  ///
  /// Turning this on for a server that may already have synced is the one
  /// thing this editor does that deletes data somewhere else, and the switch
  /// sits a few rows from the login script and the colour picker, which lowers
  /// the stakes it looks like it carries. Subtitles get skimmed; a dialog does
  /// not.
  ///
  /// Nothing is asked when there is nothing to retract — a server being added
  /// has never been anywhere, and with no sync account configured there is no
  /// other device to lose it. Turning the switch back off is not destructive
  /// either way.
  Future<bool> _confirmExclusion() => excludingNeedsConfirmation(
        existing: widget.existing,
        syncConfigured: widget.state.services.isSyncConfigured,
      )
          ? confirmSyncExclusion(context)
          : Future<bool>.value(true);

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

  /// The server the form currently describes, with [secretRef] as its
  /// credential reference. Shared by Save and Test connection so a test can
  /// never run against a different server than the one about to be saved.
  ServerConfig _formConfig({required String? secretRef, required int now}) {
    final existing = widget.existing;
    return ServerConfig(
      id: existing?.id ?? _draftId,
      label: _label.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text) ?? 22,
      username: _user.text.trim(),
      authMethod: _auth,
      secretRef: secretRef,
      identityFilePath: (_auth == AuthMethod.privateKey && _referenceKeyFile)
          ? _keyPath.text.trim()
          : null,
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
  }

  /// The security-scope grant that goes with [identityFilePath], or null when
  /// there is none to apply.
  ///
  /// Matched trim-insensitively: the saved path is trimmed, while a
  /// Browse…-picked path is verbatim (macOS filenames may carry edge
  /// whitespace — the bookmark, which opens by file identity, still works
  /// there). A hand-edit that moves the path off the grant drops it, since a
  /// bookmark only ever opens the exact file it was created from.
  IdentityFileBookmark? _bookmarkFor(String? identityFilePath) {
    final bookmark = _keyBookmark;
    if (identityFilePath == null || bookmark == null) return null;
    if (identityFilePath != _keyBookmarkPath?.trim()) return null;
    return IdentityFileBookmark(path: identityFilePath, bookmark: bookmark);
  }

  /// Connect and authenticate with what the form holds right now — including
  /// a password or key typed but not yet saved, which is not in the vault and
  /// would otherwise be tested as whatever is stored (or as nothing at all,
  /// for a server being added).
  Future<void> _testConnection() async {
    if (!_form.currentState!.validate()) return;
    final attempt = ++_testAttempt;
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final log = SshConnectionLog();
    final config = _formConfig(
      secretRef: widget.existing?.secretRef,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    final ConnectionTestResult result;
    try {
      result = await widget.state.testServerConnection(
        config,
        draftPassword: _password.text,
        // The PEM box is hidden (and stale) while the key is referenced from
        // disk; passing it then would test text the user cannot see.
        draftPrivateKey: _referenceKeyFile ? null : _keyPem.text,
        draftKeyPassphrase: _keyPassphrase.text,
        draftIdentityBookmark: _bookmarkFor(config.identityFilePath),
        log: log,
      );
    } catch (error) {
      // runConnectionTest turns every failure it can see into a result, so
      // reaching here means something outside it went wrong. Belt and braces,
      // because the alternative is the wedged editor `_save` is careful to
      // avoid: _testing stuck on, Save disabled, and Cancel — which throws
      // away everything just typed — as the only way out.
      log.freeze();
      if (!mounted || attempt != _testAttempt) return;
      setState(() => _testing = false);
      showTopToastIn(context, message: 'Could not test the connection: $error');
      return;
    }
    log.freeze();
    // Superseded by a newer attempt, or the dialog is gone: drop it.
    if (!mounted || attempt != _testAttempt) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = widget.existing;

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

    final config = _formConfig(
      secretRef: secret != null ? secretRef : existing?.secretRef,
      now: now,
    );
    try {
      // The vault write inside throws (VaultLockedException) when the OS
      // keyring is unavailable — tell the user instead of wedging the editor
      // with _busy stuck on.
      await widget.state.saveServer(
        config,
        secret: secret,
        identityFileBookmark: _bookmarkFor(config.identityFilePath),
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
