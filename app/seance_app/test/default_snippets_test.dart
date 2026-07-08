import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/default_snippets.dart';

void main() {
  final defaults = defaultSnippets();

  test('there are ~a dozen defaults, all well-formed', () {
    expect(defaults.length, greaterThanOrEqualTo(12));
    for (final s in defaults) {
      expect(s.id, startsWith('seed-'));
      expect(s.title.trim(), isNotEmpty);
      expect(s.body.trim(), isNotEmpty);
    }
  });

  test('ids are unique and timestamps are fixed (stable across devices)', () {
    final ids = defaults.map((s) => s.id).toSet();
    expect(ids.length, defaults.length);
    // Fixed timestamps so re-seeding on another device merges by id.
    expect(defaults.every((s) => s.updatedAt == defaults.first.updatedAt),
        isTrue);
  });

  test('placeholders parse as expected', () {
    final byId = {for (final s in defaults) s.id: s};
    expect(byId['seed-tail-grep']!.placeholders, ['logfile', 'pattern']);
    expect(byId['seed-tmux']!.placeholders, ['name']);
    // Braces in the web-perms find/chmod command are not placeholders.
    expect(byId['seed-web-perms']!.placeholders, ['path']);
  });
}
