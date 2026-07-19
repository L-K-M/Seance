import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';

/// One identity-file read attempt (successful or not).
class IdentityReadEvent {
  /// UTC ISO-8601, so the raw file is readable without tooling.
  final String at;
  final String serverId;
  final String serverLabel;
  final String path;

  /// True when the read went through a security-scoped bookmark grant rather
  /// than the plain (entitlement-covered) path.
  final bool viaBookmark;
  final bool ok;
  final String? error;

  const IdentityReadEvent({
    required this.at,
    required this.serverId,
    required this.serverLabel,
    required this.path,
    required this.viaBookmark,
    required this.ok,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'at': at,
        'serverId': serverId,
        'serverLabel': serverLabel,
        'path': path,
        'viaBookmark': viaBookmark,
        'ok': ok,
        if (error != null) 'error': error,
      };

  static IdentityReadEvent? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final at = json['at'];
    final serverId = json['serverId'];
    final path = json['path'];
    if (at is! String || serverId is! String || path is! String) return null;
    return IdentityReadEvent(
      at: at,
      serverId: serverId,
      serverLabel: json['serverLabel'] as String? ?? '',
      path: path,
      viaBookmark: json['viaBookmark'] as bool? ?? false,
      ok: json['ok'] as bool? ?? false,
      error: json['error'] as String?,
    );
  }
}

/// Device-local, append-only JSONL audit trail of identity-file reads, so
/// unexpected key access is traceable. One JSON object per line; the newest
/// entry is last. Never synced — paths and server labels stay on this device.
class IdentityAuditLog {
  final File file;

  /// Entries kept after a rotation; the file may grow to twice this between
  /// rotations so appends stay cheap.
  final int maxEntries;

  Future<void> _tail = Future<void>.value();

  IdentityAuditLog(this.file, {this.maxEntries = 500});

  /// Append [event], rotating the file down to the newest [maxEntries] when it
  /// has grown past twice that. Writes are serialized so concurrent connects
  /// can't interleave lines.
  Future<void> record(IdentityReadEvent event) {
    final result = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString('${jsonEncode(event.toJson())}\n',
            mode: FileMode.append, flush: true);
        await _rotateIfNeeded();
        result.complete();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  /// All decodable entries, oldest first. Malformed lines (a torn tail write,
  /// hand edits) are skipped rather than wedging the log.
  Future<List<IdentityReadEvent>> readAll() async {
    if (!await file.exists()) return const [];
    final entries = <IdentityReadEvent>[];
    for (final line in const LineSplitter().convert(await file.readAsString())) {
      if (line.trim().isEmpty) continue;
      try {
        final event = IdentityReadEvent.fromJson(jsonDecode(line));
        if (event != null) entries.add(event);
      } on FormatException {
        continue;
      }
    }
    return entries;
  }

  Future<void> _rotateIfNeeded() async {
    final lines = const LineSplitter().convert(await file.readAsString());
    if (lines.length <= maxEntries * 2) return;
    final kept = lines.sublist(lines.length - maxEntries);
    await writeStringAtomically(file, '${kept.join('\n')}\n');
  }
}
