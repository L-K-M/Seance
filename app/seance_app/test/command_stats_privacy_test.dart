import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/command_stats.dart';

const _secretCommands = [
  'export API_TOKEN=private-value',
  'DB_PASSWORD=supersecret psql',
  'gh auth login --with-token ghp_abcdefghijklmnopqrstuvwxyz',
  'echo sk-proj-abcdefghijklmnopqrstuvwxyz',
  '-----BEGIN OPENSSH PRIVATE KEY-----\nprivate\n-----END OPENSSH PRIVATE KEY-----',
];

class _ReadOnlyStore extends CommandStatsStore {
  _ReadOnlyStore(super.file);

  @override
  Future<void> save(CommandStats stats) async =>
      throw const FileSystemException('Read-only test store');
}

void main() {
  test('ordinary commands remain recordable', () {
    final stats = CommandStats();
    for (final command in ['git status', 'kubectl get pods', 'npm install']) {
      expect(stats.record(command), isTrue);
      expect(stats.countFor(command), 1);
    }
  });

  test('failed disk cleanup preserves safe in-memory history', () async {
    final dir = await Directory.systemTemp.createTemp('seance-history-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/command_stats.json');
    await file.writeAsString(jsonEncode({
      'counts': {_secretCommands.first: 8, 'git status': 4},
    }));
    final stats = await _ReadOnlyStore(file).load();
    expect(stats.counts, {'git status': 4});
    expect(await file.exists(), isTrue);
  });

  test('recognizable secrets never enter counts or dismissals', () {
    final stats = CommandStats();
    for (final command in _secretCommands) {
      expect(stats.record(command), isFalse);
      stats.dismiss(command);
      expect(stats.countFor(command), 0);
    }
    expect(stats.toJson(), {'counts': <String, int>{}, 'dismissed': <String>[]});
  });

  test('loaded secrets are removed without losing safe rankings', () {
    final stats = CommandStats.fromJson({
      'counts': {
        for (final command in _secretCommands) command: 100,
        'git status': 4,
        'ls -la': 3,
      },
      'dismissed': [..._secretCommands, 'ls -la'],
    });
    expect(stats.counts, {'git status': 4, 'ls -la': 3});
    expect(stats.dismissed, {'ls -la'});
    expect(stats.suggestions(isExisting: (_) => false), ['git status']);
  });

  test('serialization filters direct mutations of legacy public collections', () {
    final stats = CommandStats();
    stats.counts[_secretCommands.first] = 9;
    stats.dismissed.add(_secretCommands.last);
    expect(stats.toJson(), {'counts': <String, int>{}, 'dismissed': <String>[]});
  });

  test('loading a legacy file removes recognized secrets from disk', () async {
    final dir = await Directory.systemTemp.createTemp('seance-history-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/command_stats.json');
    await file.writeAsString(jsonEncode({
      'counts': {_secretCommands.first: 8, 'git status': 4},
      'dismissed': [_secretCommands.last],
    }));
    final store = CommandStatsStore(file);
    final stats = await store.load();
    expect(stats.countFor('git status'), 4);
    expect(jsonDecode(await file.readAsString()), {
      'counts': {'git status': 4},
      'dismissed': <String>[],
    });
  });
}
