import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';

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
  final _password = TextEditingController();
  final _keyPem = TextEditingController();
  final _keyPath = TextEditingController();
  final _keyPassphrase = TextEditingController();

  late AuthMethod _auth;
  bool _referenceKeyFile = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _label = TextEditingController(text: e?.label ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? 22}');
    _user = TextEditingController(text: e?.username ?? '');
    _auth = e?.authMethod ?? AuthMethod.agent;
    _keyPath.text = e?.identityFilePath ?? '';
    _referenceKeyFile = e?.identityFilePath != null;
  }

  @override
  void dispose() {
    for (final c in [
      _label,
      _host,
      _port,
      _user,
      _password,
      _keyPem,
      _keyPath,
      _keyPassphrase
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
                    validator: (v) =>
                        int.tryParse(v ?? '') == null ? 'invalid' : null,
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
        return const [
          Text('Keys are provided by your ssh-agent; nothing is stored.'),
        ];
      case AuthMethod.password:
        return [
          TextFormField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
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
            TextFormField(
              controller: _keyPath,
              decoration: const InputDecoration(
                  labelText: 'Identity file path',
                  hintText: '~/.ssh/id_ed25519'),
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
        ];
    }
  }

  static String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

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
    } else if (_auth == AuthMethod.privateKey && !_referenceKeyFile) {
      secretRef ??= uuidV4();
      secret = Secret(
        id: secretRef,
        kind: SecretKind.privateKey,
        value: _keyPem.text,
        keyPassphrase:
            _keyPassphrase.text.isEmpty ? null : _keyPassphrase.text,
      );
    }

    final config = ServerConfig(
      id: id,
      label: _label.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text) ?? 22,
      username: _user.text.trim(),
      authMethod: _auth,
      secretRef: secret != null ? secretRef : (existing?.secretRef),
      identityFilePath: (_auth == AuthMethod.privateKey && _referenceKeyFile)
          ? _keyPath.text.trim()
          : null,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );

    await widget.state.saveServer(config, secret: secret);
    if (mounted) Navigator.of(context).pop();
  }
}
