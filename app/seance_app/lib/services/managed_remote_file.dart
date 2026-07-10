import 'package:seance_core/seance_core.dart';

/// A durable, device-local checkout of a remote file.
///
/// [localPath] is a checkout-root-relative identity, not an arbitrary or
/// absolute filesystem path. [dirty] and [missing] are runtime observations;
/// they are deliberately recomputed rather than persisted.
class ManagedRemoteFile {
  final String id;
  final String serverId;
  final String editSessionId;
  final String remotePath;
  final String localPath;
  final RemoteFileEntry remoteSnapshot;
  final String baselineSha256;
  final bool dirty;
  final bool missing;

  const ManagedRemoteFile({
    required this.id,
    required this.serverId,
    required this.editSessionId,
    required this.remotePath,
    required this.localPath,
    required this.remoteSnapshot,
    required this.baselineSha256,
    this.dirty = false,
    this.missing = false,
  });

  factory ManagedRemoteFile.fromJson(Map<String, dynamic> json) {
    final snapshotJson = _requiredMap(json, 'remoteSnapshot');
    final result = ManagedRemoteFile(
      id: _requiredString(json, 'id'),
      serverId: _requiredString(json, 'serverId'),
      editSessionId: _requiredString(json, 'editSessionId'),
      remotePath: _requiredString(json, 'remotePath'),
      localPath: _requiredString(json, 'localPath'),
      remoteSnapshot: _remoteFileEntryFromJson(snapshotJson),
      baselineSha256: _requiredString(json, 'baselineSha256').toLowerCase(),
    );
    result.validate();
    return result;
  }

  /// Validates model-level invariants. Store-specific path validation happens
  /// in `ManagedRemoteFileStore`.
  void validate() {
    for (final field in <(String, String)>[
      ('id', id),
      ('serverId', serverId),
      ('editSessionId', editSessionId),
      ('remotePath', remotePath),
      ('localPath', localPath),
      ('remoteSnapshot.path', remoteSnapshot.path),
      ('remoteSnapshot.name', remoteSnapshot.name),
    ]) {
      if (field.$2.isEmpty) {
        throw FormatException('${field.$1} must not be empty');
      }
    }
    if (remotePath != remoteSnapshot.path) {
      throw const FormatException('remotePath must match remoteSnapshot.path');
    }
    if (!remotePath.startsWith('/') || remotePath.contains('\u0000')) {
      throw const FormatException('remotePath must be an absolute POSIX path');
    }
    if (remoteSnapshot.type != RemoteFileType.file) {
      throw const FormatException('Only regular files can be managed edits');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(baselineSha256)) {
      throw const FormatException(
        'baselineSha256 must be a lowercase SHA-256 digest',
      );
    }
    if (remoteSnapshot.size case final size? when size < 0) {
      throw const FormatException('remoteSnapshot.size must not be negative');
    }
    if (remoteSnapshot.mode case final mode? when mode < 0) {
      throw const FormatException('remoteSnapshot.mode must not be negative');
    }
    if (dirty && missing) {
      throw const FormatException('A missing checkout cannot also be dirty');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'serverId': serverId,
    'editSessionId': editSessionId,
    'remotePath': remotePath,
    'localPath': localPath,
    'remoteSnapshot': _remoteFileEntryToJson(remoteSnapshot),
    'baselineSha256': baselineSha256,
  };

  ManagedRemoteFile copyWith({
    String? id,
    String? serverId,
    String? editSessionId,
    String? remotePath,
    String? localPath,
    RemoteFileEntry? remoteSnapshot,
    String? baselineSha256,
    bool? dirty,
    bool? missing,
  }) => ManagedRemoteFile(
    id: id ?? this.id,
    serverId: serverId ?? this.serverId,
    editSessionId: editSessionId ?? this.editSessionId,
    remotePath: remotePath ?? this.remotePath,
    localPath: localPath ?? this.localPath,
    remoteSnapshot: remoteSnapshot ?? this.remoteSnapshot,
    baselineSha256: baselineSha256 ?? this.baselineSha256,
    dirty: dirty ?? this.dirty,
    missing: missing ?? this.missing,
  );
}

Map<String, dynamic> _remoteFileEntryToJson(RemoteFileEntry entry) => {
  'path': entry.path,
  'name': entry.name,
  'type': entry.type.name,
  'size': entry.size,
  'uid': entry.uid,
  'gid': entry.gid,
  'accessedAt': entry.accessedAt?.toUtc().toIso8601String(),
  'modifiedAt': entry.modifiedAt?.toUtc().toIso8601String(),
  'mode': entry.mode,
  'contentSha256': entry.contentSha256,
};

RemoteFileEntry _remoteFileEntryFromJson(Map<String, dynamic> json) {
  final typeName = _requiredString(json, 'type');
  final type = RemoteFileType.values.where((value) => value.name == typeName);
  if (type.isEmpty) {
    throw FormatException('Unknown remote file type: $typeName');
  }

  final size = _optionalInt(json, 'size');
  final mode = _optionalInt(json, 'mode');
  final contentSha256 = json['contentSha256'];
  if (contentSha256 != null &&
      (contentSha256 is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(contentSha256))) {
    throw const FormatException('contentSha256 must be a SHA-256 digest');
  }
  DateTime? timestamp(String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('$key must be a string or null');
    }
    final parsed = DateTime.tryParse(value)?.toUtc();
    if (parsed == null) throw FormatException('$key is not a valid timestamp');
    return parsed;
  }

  return RemoteFileEntry(
    path: _requiredString(json, 'path'),
    name: _requiredString(json, 'name'),
    type: type.first,
    size: size,
    uid: _optionalInt(json, 'uid'),
    gid: _optionalInt(json, 'gid'),
    accessedAt: timestamp('accessedAt'),
    modifiedAt: timestamp('modifiedAt'),
    mode: mode,
    contentSha256: contentSha256 as String?,
  );
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  try {
    return value.cast<String, dynamic>();
  } on TypeError {
    throw FormatException('$key must have string keys');
  }
}

int? _optionalInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int) throw FormatException('$key must be an integer or null');
  return value;
}
