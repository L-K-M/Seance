import 'server_config.dart';

const int _defaultSshPort = 22;
const int _minimumSshPort = 1;
const int _maximumSshPort = 65535;
const int _initialRulesVersion = 1;
const String _bookmarkRecordPrefix = 'bookmark:';

enum BookmarkKind { localFolder, remotePath, workspace, savedSync }

enum PreferredPane { left, right, either }

/// A server reference is either a Séance config id or an embedded identity.
class BookmarkServerRef {
  final String? serverConfigId;
  final EmbeddedHostIdentity? identity;

  const BookmarkServerRef({this.serverConfigId, this.identity})
    : assert((serverConfigId == null) != (identity == null));

  Map<String, dynamic> toJson() => {
    if (serverConfigId != null) 'serverConfigId': serverConfigId,
    if (identity != null) 'identity': identity!.toJson(),
  };

  factory BookmarkServerRef.fromJson(Map<String, dynamic> json) => _guardFormat(
    'BookmarkServerRef',
    () {
      final serverConfigId = _optionalStructuralString(json, 'serverConfigId');
      final identityJson = _optionalMap(json, 'identity');
      final identity = identityJson == null
          ? null
          : EmbeddedHostIdentity.fromJson(identityJson);

      if ((serverConfigId == null) == (identity == null)) {
        throw const FormatException(
          'BookmarkServerRef requires exactly one reference',
        );
      }

      return BookmarkServerRef(
        serverConfigId: serverConfigId,
        identity: identity,
      );
    },
  );
}

class EmbeddedHostIdentity {
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;
  final String? secretRef;
  final String? identityFilePath;

  const EmbeddedHostIdentity({
    required this.host,
    this.port = _defaultSshPort,
    required this.username,
    required this.authMethod,
    this.secretRef,
    this.identityFilePath,
  }) : assert(port >= _minimumSshPort && port <= _maximumSshPort);

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'username': username,
    'authMethod': authMethod.name,
    if (secretRef != null) 'secretRef': secretRef,
    if (identityFilePath != null) 'identityFilePath': identityFilePath,
  };

  factory EmbeddedHostIdentity.fromJson(Map<String, dynamic> json) =>
      _guardFormat('EmbeddedHostIdentity', () {
        final port = _optionalInt(json, 'port') ?? _defaultSshPort;
        if (port < _minimumSshPort || port > _maximumSshPort) {
          throw FormatException('Invalid SSH port: $port');
        }

        return EmbeddedHostIdentity(
          host: _requiredString(json, 'host'),
          port: port,
          username: _requiredString(json, 'username'),
          authMethod: _authMethod(json['authMethod']),
          secretRef: _optionalCosmeticString(json, 'secretRef'),
          identityFilePath: _optionalCosmeticString(json, 'identityFilePath'),
        );
      });
}

/// One local or remote endpoint of a workspace or saved sync.
class BookmarkLocation {
  final BookmarkServerRef? server;
  final String path;

  const BookmarkLocation({this.server, required this.path});

  Map<String, dynamic> toJson() => {
    if (server != null) 'server': server!.toJson(),
    'path': path,
  };

  factory BookmarkLocation.fromJson(Map<String, dynamic> json) =>
      _guardFormat('BookmarkLocation', () {
        final serverJson = _optionalMap(json, 'server');
        final server = serverJson == null
            ? null
            : BookmarkServerRef.fromJson(serverJson);
        final path = _requiredString(json, 'path');
        if (server != null) _requireAbsoluteRemotePath(path, 'path');

        return BookmarkLocation(server: server, path: path);
      });
}

/// Stored, versioned sync settings. Execution validates rule semantics.
class SavedSyncSpec {
  final BookmarkLocation source;
  final BookmarkLocation destination;
  final List<String> ignoreRules;
  final int rulesVersion;
  final Map<String, Object?> rules;

  SavedSyncSpec({
    required this.source,
    required this.destination,
    List<String> ignoreRules = const [],
    this.rulesVersion = _initialRulesVersion,
    Map<String, Object?> rules = const {},
  }) : ignoreRules = List<String>.unmodifiable(ignoreRules),
       rules = _deepFreezeJsonMap(rules);

  Map<String, dynamic> toJson() => {
    'source': source.toJson(),
    'destination': destination.toJson(),
    'ignoreRules': List<String>.from(ignoreRules),
    'rulesVersion': rulesVersion,
    'rules': _mutableJsonMap(rules),
  };

  factory SavedSyncSpec.fromJson(Map<String, dynamic> json) =>
      _guardFormat('SavedSyncSpec', () {
        final ignoreRulesValue = json['ignoreRules'];
        final ignoreRules = <String>[];
        if (ignoreRulesValue != null) {
          if (ignoreRulesValue is! List) {
            throw const FormatException('ignoreRules must be a list');
          }
          for (final rule in ignoreRulesValue) {
            if (rule is! String) {
              throw const FormatException('ignoreRules must contain strings');
            }
            ignoreRules.add(rule);
          }
        }

        final rulesJson = _optionalMap(json, 'rules') ?? const {};
        final rulesVersion =
            _optionalInt(json, 'rulesVersion') ?? _initialRulesVersion;
        if (rulesVersion < _initialRulesVersion) {
          throw FormatException(
            'rulesVersion must be at least $_initialRulesVersion',
          );
        }

        return SavedSyncSpec(
          source: BookmarkLocation.fromJson(_requiredMap(json, 'source')),
          destination: BookmarkLocation.fromJson(
            _requiredMap(json, 'destination'),
          ),
          ignoreRules: ignoreRules,
          rulesVersion: rulesVersion,
          rules: rulesJson,
        );
      });
}

class Bookmark {
  final String id;
  final BookmarkKind kind;
  final String label;
  final String? group;
  final ServerColor? color;
  final ServerIcon? icon;
  final BookmarkServerRef? server;
  final String? localPath;
  final String? remotePath;
  final BookmarkLocation? left;
  final BookmarkLocation? right;
  final SavedSyncSpec? sync;
  final PreferredPane preferredPane;
  final String sortKey;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Bookmark({
    required this.id,
    required this.kind,
    required this.label,
    this.group,
    this.color,
    this.icon,
    this.server,
    this.localPath,
    this.remotePath,
    this.left,
    this.right,
    this.sync,
    this.preferredPane = PreferredPane.either,
    required this.sortKey,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'label': label,
    if (group != null) 'group': group,
    if (color != null) 'color': color!.name,
    if (icon != null) 'icon': icon!.name,
    if (server != null) 'server': server!.toJson(),
    if (localPath != null) 'localPath': localPath,
    if (remotePath != null) 'remotePath': remotePath,
    if (left != null) 'left': left!.toJson(),
    if (right != null) 'right': right!.toJson(),
    if (sync != null) 'sync': sync!.toJson(),
    'preferredPane': preferredPane.name,
    'sortKey': sortKey,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  /// [recordId] binds a decoded payload to its plaintext envelope id.
  factory Bookmark.fromJson(
    Map<String, dynamic> json, {
    required String recordId,
  }) => _guardFormat('Bookmark', () {
    final id = _requiredString(json, 'id');
    if (recordId != '$_bookmarkRecordPrefix$id') {
      throw FormatException(
        'Bookmark id $id does not match envelope id $recordId',
      );
    }

    final kind = _bookmarkKind(json['kind']);
    final serverJson = _optionalMap(json, 'server');
    final leftJson = _optionalMap(json, 'left');
    final rightJson = _optionalMap(json, 'right');
    final syncJson = _optionalMap(json, 'sync');
    final server = serverJson == null
        ? null
        : BookmarkServerRef.fromJson(serverJson);
    final localPath = _optionalStructuralString(json, 'localPath');
    final remotePath = _optionalStructuralString(json, 'remotePath');
    final left = leftJson == null ? null : BookmarkLocation.fromJson(leftJson);
    final right = rightJson == null
        ? null
        : BookmarkLocation.fromJson(rightJson);
    final sync = syncJson == null ? null : SavedSyncSpec.fromJson(syncJson);

    _validateKindFields(
      kind: kind,
      server: server,
      localPath: localPath,
      remotePath: remotePath,
      left: left,
      right: right,
      sync: sync,
    );

    return Bookmark(
      id: id,
      kind: kind,
      label: _requiredString(json, 'label'),
      group: _optionalCosmeticString(json, 'group'),
      color: _serverColor(json['color']),
      icon: _serverIcon(json['icon']),
      server: server,
      localPath: localPath,
      remotePath: remotePath,
      left: left,
      right: right,
      sync: sync,
      preferredPane: _preferredPane(json['preferredPane']),
      sortKey: _requiredString(json, 'sortKey'),
      createdAt: _requiredDateTime(json, 'createdAt'),
      updatedAt: _requiredDateTime(json, 'updatedAt'),
    );
  });
}

void _validateKindFields({
  required BookmarkKind kind,
  required BookmarkServerRef? server,
  required String? localPath,
  required String? remotePath,
  required BookmarkLocation? left,
  required BookmarkLocation? right,
  required SavedSyncSpec? sync,
}) {
  final hasRemote = server != null || remotePath != null;
  final hasWorkspace = left != null || right != null;

  switch (kind) {
    case BookmarkKind.localFolder:
      if (localPath == null || hasRemote || hasWorkspace || sync != null) {
        throw const FormatException('Invalid localFolder fields');
      }
    case BookmarkKind.remotePath:
      if (server == null || remotePath == null) {
        throw const FormatException('remotePath requires server and path');
      }
      _requireAbsoluteRemotePath(remotePath, 'remotePath');
      if (localPath != null || hasWorkspace || sync != null) {
        throw const FormatException('Invalid remotePath fields');
      }
    case BookmarkKind.workspace:
      if (left == null || right == null) {
        throw const FormatException('workspace requires left and right');
      }
      if (localPath != null || hasRemote || sync != null) {
        throw const FormatException('Invalid workspace fields');
      }
    case BookmarkKind.savedSync:
      if (sync == null || localPath != null || hasRemote || hasWorkspace) {
        throw const FormatException('Invalid savedSync fields');
      }
  }
}

T _guardFormat<T>(String type, T Function() decode) {
  try {
    return decode();
  } on FormatException {
    rethrow;
  } catch (error) {
    throw FormatException('Invalid $type: $error');
  }
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-blank string');
  }
  return value;
}

String? _optionalStructuralString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-blank string');
  }
  return value;
}

String? _optionalCosmeticString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string');

  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _optionalInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int) throw FormatException('$key must be an integer');
  return value;
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = _optionalMap(json, key);
  if (value == null) throw FormatException('$key is required');
  return value;
}

Map<String, dynamic>? _optionalMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map) throw FormatException('$key must be an object');

  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    final entryKey = entry.key;
    if (entryKey is! String) {
      throw FormatException('$key must have string keys');
    }
    result[entryKey] = entry.value;
  }
  return result;
}

DateTime _requiredDateTime(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) {
    throw FormatException('$key must be an ISO-8601 date with a UTC offset');
  }
  return parsed.toUtc();
}

void _requireAbsoluteRemotePath(String value, String key) {
  if (!value.startsWith('/')) {
    throw FormatException('$key must be an absolute remote path');
  }
}

BookmarkKind _bookmarkKind(Object? value) {
  if (value is! String) {
    throw const FormatException('kind must be a string');
  }
  for (final kind in BookmarkKind.values) {
    if (kind.name == value) return kind;
  }
  throw FormatException('Unknown bookmark kind: $value');
}

PreferredPane _preferredPane(Object? value) {
  if (value == null) return PreferredPane.either;
  if (value is! String) {
    throw const FormatException('preferredPane must be a string');
  }
  for (final pane in PreferredPane.values) {
    if (pane.name == value) return pane;
  }
  return PreferredPane.either;
}

AuthMethod _authMethod(Object? value) {
  if (value is! String) {
    throw const FormatException('authMethod must be a string');
  }
  for (final method in AuthMethod.values) {
    if (method.name == value) return method;
  }
  throw FormatException('Unknown authMethod: $value');
}

ServerColor? _serverColor(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('color must be a string');
  for (final color in ServerColor.values) {
    if (color.name == value) return color;
  }
  return null;
}

ServerIcon? _serverIcon(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('icon must be a string');
  for (final icon in ServerIcon.values) {
    if (icon.name == value) return icon;
  }
  return null;
}

Map<String, Object?> _deepFreezeJsonMap(Map<String, Object?> value) {
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    result[entry.key] = _deepFreezeJson(entry.value);
  }
  return Map<String, Object?>.unmodifiable(result);
}

Object? _deepFreezeJson(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_deepFreezeJson));
  }
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const FormatException('rules must have string keys');
      }
      result[key] = _deepFreezeJson(entry.value);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  throw FormatException('rules contain a non-JSON value: ${value.runtimeType}');
}

Map<String, Object?> _mutableJsonMap(Map<String, Object?> value) => {
  for (final entry in value.entries) entry.key: _mutableJson(entry.value),
};

Object? _mutableJson(Object? value) {
  if (value is Map<String, Object?>) return _mutableJsonMap(value);
  if (value is List) return value.map(_mutableJson).toList();
  return value;
}
