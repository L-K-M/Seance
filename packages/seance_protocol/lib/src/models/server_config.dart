/// How a server authenticates. `agent` means "don't store anything — sign via
/// an ssh-agent", which is the lowest-risk mode and the encouraged default.
enum AuthMethod { password, privateKey, agent }

AuthMethod _authFromName(String name) =>
    AuthMethod.values.firstWhere((m) => m.name == name,
        orElse: () => AuthMethod.password);

/// A server's accent color, as a *name* rather than an ARGB value.
///
/// Two reasons it is a closed set. A raw color would have to be picked once and
/// then read on every theme: a hand-chosen `0xFF2E2E2E` that looks sober in
/// light mode disappears in dark mode, and this list is rendered against both.
/// A name lets the app derive a matching container/foreground pair per
/// brightness instead (see the app's `ServerAppearance`). And because the value
/// syncs, a closed set is also what keeps a future device from being handed a
/// color it has no sensible way to render.
///
/// The hues are the app's own, not the terminal palette's: this tags *which
/// box you are on*, which must stay legible whatever colors the remote shell
/// is painting with.
enum ServerColor {
  violet,
  blue,
  cyan,
  teal,
  green,
  amber,
  orange,
  red,
  pink,
  slate,
}

/// A server's icon, again as a name from a closed set.
///
/// Beyond the sync argument above, Flutter's `--tree-shake-icons` build step
/// only keeps glyphs it can see referenced by a *const* `IconData`. Storing an
/// arbitrary codepoint and rendering `Icon(IconData(stored))` compiles fine and
/// then ships a release build with blank squares where the icons were. A name
/// mapped to a const `IconData` in the app keeps the whole feature tree-shakable.
enum ServerIcon {
  server,
  cloud,
  database,
  web,
  terminal,
  shield,
  home,
  work,
  lab,
  device,
  router,
  mail,
  container,
  rocket,
  star,
  bug,
}

/// Decode a [ServerColor] name, or null when absent *or unrecognized*.
///
/// Unlike [_authFromName] this deliberately has no fallback value: a newer
/// device may have tagged a server with a color this build has never heard of,
/// and showing the wrong color is worse than showing none. Round-tripping is
/// still lossy for that record (see [ServerConfig.color]) — this only decides
/// what gets drawn meanwhile.
ServerColor? _colorFromName(String? name) {
  if (name == null) return null;
  for (final c in ServerColor.values) {
    if (c.name == name) return c;
  }
  return null;
}

/// Decode a [ServerIcon] name, or null when absent or unrecognized. See
/// [_colorFromName] for why there is no fallback.
ServerIcon? _iconFromName(String? name) {
  if (name == null) return null;
  for (final i in ServerIcon.values) {
    if (i.name == name) return i;
  }
  return null;
}

/// A configured SSH server. This is non-secret metadata: the actual password or
/// private key lives in the encrypted vault and is referenced here by [secretRef].
class ServerConfig {
  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;

  /// Vault entry id holding the password or private key, when [authMethod]
  /// stores a secret. Null for `agent` or for [identityFilePath] references.
  final String? secretRef;

  /// "Reference, don't store": path to an on-disk OpenSSH private key. The
  /// passphrase (if any) is prompted at connect time or cached in the vault.
  final String? identityFilePath;

  /// Optional ProxyJump: the id of another [ServerConfig] to tunnel through.
  final String? jumpHostId;

  /// Whether the referenced secret is allowed to sync (opt-in per item).
  final bool syncSecret;

  /// The group this server is filed under in the list, or null for none.
  ///
  /// A plain name carried by the member, not a reference to a group *record*.
  /// Records sync last-writer-wins and independently, so a first-class group
  /// entity would let one device delete a group while another files a server
  /// into it — leaving a config pointing at nothing, with no round to repair it.
  /// A name cannot dangle: the group exists exactly as long as a server says it
  /// does. The cost is that renaming a group rewrites its members, which for a
  /// few dozen rarely-edited servers is not a cost worth designing around.
  ///
  /// Grouping is case-insensitive but the spelling is preserved, so a server
  /// typed into `prod` joins `Prod` rather than starting a near-identical
  /// second group.
  final String? group;

  /// An accent color for this server, or null to stay neutral. Non-functional
  /// by design: it distinguishes rows at a glance and tints the terminal's tab
  /// strip so "which box am I on" is answerable without reading.
  ///
  /// Null also covers *unrecognized*: a color added in a later version decodes
  /// here as null, and this device re-pushing the record will drop it. That is
  /// the same lossy-downgrade the record layer already has for any added field,
  /// and it costs a color rather than a credential.
  final ServerColor? color;

  /// An icon for this server, or null for the default. See [color] for the
  /// unrecognized-value behavior, which is identical.
  final ServerIcon? icon;

  /// A command to run on the remote host once the shell opens, or null for
  /// none.
  ///
  /// It is sent as keyboard input into the interactive session — not executed
  /// on a separate channel — so "set up *this* shell" scripts behave as
  /// expected: `cd`, `tmux attach`, exporting aliases all land in the session
  /// you are looking at, and anything the script prints appears in the
  /// scrollback like typed output would. The trade-offs of that choice: the
  /// keystrokes are queued before the shell exists, so on servers where login
  /// itself reads stdin (a passphrase prompt, a forced menu) the script's
  /// first lines feed that prompt instead of running; and like anything typed,
  /// both the script and its output are echoed into scrollback — this field
  /// is no place for secrets.
  final String? loginScript;

  /// Keep this server on this device only: its configuration is never pushed
  /// to the sync server, and a copy pushed before the flag went on is
  /// retracted with a tombstone — which also removes it from the other devices
  /// that had pulled it. The local copy is untouched.
  ///
  /// The flag rides on the config rather than in device-local settings because
  /// it is only ever read next to the config it governs, and it costs nothing
  /// to carry: the one record that could publish it is exactly the record it
  /// suppresses. Clearing it pushes the config again, with the flag false.
  ///
  /// Scope is this server's own record and its stored credential. A pinned
  /// host key is *not* retracted: it is keyed by `host:port` rather than by
  /// server, another device may have pinned the same host on its own, and
  /// deleting it there would drop that device back to trust-on-first-use — a
  /// weaker position than the one the user asked for. Going forward, a pin for
  /// a `host:port` that only excluded servers name is simply not pushed.
  ///
  /// Any write that *changes* this must carry a strictly later [updatedAt].
  /// The retraction tombstone is dated from it, so a stale one — or the
  /// current one, which ties — loses the tie-break to the copy already on the
  /// server, and the UI would report the server as excluded while its record
  /// sat there untouched. [copyWith] throws on that rather than leaving it to
  /// be discovered in a sync log.
  final bool excludeFromSync;

  final int createdAt;
  final int updatedAt;

  const ServerConfig({
    required this.id,
    required this.label,
    required this.host,
    this.port = 22,
    required this.username,
    this.authMethod = AuthMethod.agent,
    this.secretRef,
    this.identityFilePath,
    this.jumpHostId,
    this.syncSecret = false,
    this.group,
    this.color,
    this.icon,
    this.loginScript,
    this.excludeFromSync = false,
    required this.createdAt,
    required this.updatedAt,
  });

  ServerConfig copyWith({
    String? label,
    String? host,
    int? port,
    String? username,
    AuthMethod? authMethod,
    String? secretRef,
    bool clearSecretRef = false,
    String? identityFilePath,
    bool clearIdentityFilePath = false,
    String? jumpHostId,
    bool clearJumpHostId = false,
    bool? syncSecret,
    String? group,
    bool clearGroup = false,
    ServerColor? color,
    bool clearColor = false,
    ServerIcon? icon,
    bool clearIcon = false,
    String? loginScript,
    bool clearLoginScript = false,
    bool? excludeFromSync,
    int? updatedAt,
  }) {
    // A throw rather than an assert, which profile and release builds strip:
    // the mistake this catches is a record that keeps syncing while the UI
    // says it does not, and a privacy setting failing silently in the only
    // build users run is not a trade worth making. `RecordCodec.encrypt`
    // rejects an impossible kind the same way.
    if (excludeFromSync != null &&
        excludeFromSync != this.excludeFromSync &&
        (updatedAt == null || updatedAt <= this.updatedAt)) {
      throw ArgumentError.value(
        updatedAt,
        'updatedAt',
        'Changing excludeFromSync needs an updatedAt later than the current '
            'one: the retraction tombstone is dated from it, and a date that '
            'ties with the copy already on the sync server loses to it',
      );
    }
    return ServerConfig(
      id: id,
      label: label ?? this.label,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      secretRef: clearSecretRef ? null : (secretRef ?? this.secretRef),
      identityFilePath: clearIdentityFilePath
          ? null
          : (identityFilePath ?? this.identityFilePath),
      jumpHostId: clearJumpHostId ? null : (jumpHostId ?? this.jumpHostId),
      syncSecret: syncSecret ?? this.syncSecret,
      // Normalized here as well as in fromJson, so the two ways a group name
      // can be replaced agree. The const constructor cannot do the same, which
      // is why every caller-facing path — the editor, this — normalizes.
      group: clearGroup ? null : normalizeServerGroup(group ?? this.group),
      color: clearColor ? null : (color ?? this.color),
      icon: clearIcon ? null : (icon ?? this.icon),
      loginScript: clearLoginScript
          ? null
          : normalizeLoginScript(loginScript ?? this.loginScript),
      excludeFromSync: excludeFromSync ?? this.excludeFromSync,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        if (secretRef != null) 'secretRef': secretRef,
        if (identityFilePath != null) 'identityFilePath': identityFilePath,
        if (jumpHostId != null) 'jumpHostId': jumpHostId,
        'syncSecret': syncSecret,
        if (group != null) 'group': group,
        if (color != null) 'color': color!.name,
        if (icon != null) 'icon': icon!.name,
        if (loginScript != null) 'loginScript': loginScript,
        // Written unconditionally, like `syncSecret` and unlike the optional
        // presentation fields above: the two sync-policy booleans are a pair
        // and should read the same way round, and "no, I want this synced" is
        // an answer the user gave rather than an attribute left unset.
        'excludeFromSync': excludeFromSync,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        id: json['id'] as String,
        label: json['label'] as String,
        host: json['host'] as String,
        port: (json['port'] as num?)?.toInt() ?? 22,
        username: json['username'] as String,
        authMethod: _authFromName(json['authMethod'] as String? ?? 'agent'),
        secretRef: json['secretRef'] as String?,
        identityFilePath: json['identityFilePath'] as String?,
        jumpHostId: json['jumpHostId'] as String?,
        syncSecret: json['syncSecret'] as bool? ?? false,
        // Normalized on the way in as well as on the way out: a group that is
        // blank or all whitespace is "no group", and letting one through would
        // put a nameless section in the list on the device that read it.
        group: normalizeServerGroup(json['group'] as String?),
        color: _colorFromName(json['color'] as String?),
        icon: _iconFromName(json['icon'] as String?),
        loginScript: normalizeLoginScript(json['loginScript'] as String?),
        excludeFromSync: json['excludeFromSync'] as bool? ?? false,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// The stored form of a group name: trimmed, with blank meaning "no group".
///
/// Interior whitespace is left alone — `web servers` is a name someone meant to
/// type — but the edges are not, so `prod ` and `prod` are never two groups.
String? normalizeServerGroup(String? group) {
  if (group == null) return null;
  final trimmed = group.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The stored form of a login script: CR family line endings canonicalized to
/// LF and outer edges trimmed (so an editor's trailing newline doesn't survive
/// as a stray Enter keystroke), with blank meaning "none". Interior newlines
/// are the point of a multi-line script and are kept verbatim — after
/// canonicalization, because a `\r` inside a line reaches a PTY's line
/// discipline as an Enter of its own, turning one stored line into two.
String? normalizeLoginScript(String? script) {
  if (script == null) return null;
  final trimmed = script
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The key two group names are considered the same under: case-insensitive, so
/// `Prod` and `prod` are one group rather than two adjacent near-identical
/// sections. The displayed spelling is whichever member is listed first.
String serverGroupKey(String group) => group.toLowerCase();
