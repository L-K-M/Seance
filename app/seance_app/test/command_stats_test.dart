import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/command_stats.dart';

void main() {
  test('suggests commands past the threshold, most-used first', () {
    final s = CommandStats();
    for (var i = 0; i < 3; i++) {
      s.record('docker compose up -d');
    }
    for (var i = 0; i < 2; i++) {
      s.record('git status'); // below the default threshold
    }
    for (var i = 0; i < 4; i++) {
      s.record('tail -f app.log');
    }
    expect(s.record('x'), isFalse); // single-key noise is ignored

    final sugg = s.suggestions(isExisting: (c) => false);
    expect(sugg, ['tail -f app.log', 'docker compose up -d']);
    expect(sugg.contains('git status'), isFalse);
    expect(s.counts.containsKey('x'), isFalse);
  });

  test('excludes existing snippets and dismissed commands', () {
    final s = CommandStats();
    for (var i = 0; i < 3; i++) {
      s.record('tail -f app.log');
    }
    for (var i = 0; i < 3; i++) {
      s.record('docker compose up -d');
    }

    // A command that already exists as a snippet drops off.
    expect(
      s.suggestions(isExisting: (c) => c == 'tail -f app.log'),
      ['docker compose up -d'],
    );

    // A dismissed command never comes back.
    s.dismiss('docker compose up -d');
    expect(s.suggestions(isExisting: (c) => false), ['tail -f app.log']);
  });

  test('json round-trips counts and dismissals', () {
    final s = CommandStats();
    for (var i = 0; i < 3; i++) {
      s.record('htop');
    }
    s.dismiss('htop');

    final restored = CommandStats.fromJson(s.toJson());
    expect(restored.countFor('htop'), 3);
    expect(restored.suggestions(isExisting: (c) => false), isEmpty);
  });
}
