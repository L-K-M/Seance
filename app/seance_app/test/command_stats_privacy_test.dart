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

void main() {
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

  test('saving a legacy file removes recognized secrets from disk', () async {
    final dir = await Directory.systemTemp.createTemp('seance-history-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/command_stats.json');
    await file.writeAsString(jsonEncode({
      'counts': {_secretCommands.first: 8, 'git status': 4},
      'dismissed': [_secretCommands.last],
    }));
    final store = CommandStatsStore(file);
    await store.save(await store.load());
    expect(jsonDecode(await file.readAsString()), {
      'counts': {'git status': 4},
      'dismissed': <String>[],
    });
  });
}
