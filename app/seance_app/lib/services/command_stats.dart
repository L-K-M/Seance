import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';

import 'atomic_file.dart';

/// Local, on-device frequency count of the commands the user runs, used to
/// suggest often-repeated commands as snippets. This never syncs and never
/// leaves the machine — only a snippet the user explicitly saves does. See
/// [AppState] for how suggestions are surfaced.
class CommandStats {
  /// command text → times submitted.
  final Map<String, int> counts;

  /// Commands the user dismissed from the suggestions list (never suggest
  /// again, even once they cross the threshold).
  final Set<String> dismissed;

  CommandStats({Map<String, int>? counts, Set<String>? dismissed})
      : counts = {
          for (final entry in (counts ?? <String, int>{}).entries)
            if (_safeToRetain(entry.key)) entry.key: entry.value,
        },
        dismissed = {
          for (final command in dismissed ?? <String>{})
            if (_safeToRetain(command)) command,
        };

  // Filter before persistence, independent of the assistant's redaction toggle.
  // Unmarked no-echo passwords remain undetectable: capture stays opt-in.
  static final _redactor = SecretRedactor();
  static bool _safeToRetain(String command) => !_redactor.wouldRedact(command);

  /// Cap the tracked set so the file can't grow without bound; when exceeded,
  /// the least-used entries are dropped.
  static const int _maxTracked = 400;

  /// Record one submitted command. Returns true if the counts changed.
  bool record(String command) {
    final cmd = command.trim();
    if (cmd.length < 2 || !_safeToRetain(cmd)) return false;
    counts[cmd] = (counts[cmd] ?? 0) + 1;
    if (counts.length > _maxTracked) _trim();
    return true;
  }

  void _trim() {
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    counts
      ..clear()
      ..addEntries(entries.take(_maxTracked));
  }

  /// Candidate suggestions: commands run at least [minCount] times, not already
  /// a snippet (via [isExisting]) and not [dismissed], most-used first.
  List<String> suggestions({
    required bool Function(String command) isExisting,
    int minCount = 3,
    int limit = 6,
  }) {
    final candidates = counts.entries
        .where((e) =>
            e.value >= minCount &&
            !dismissed.contains(e.key) &&
            _safeToRetain(e.key) &&
            !isExisting(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in candidates.take(limit)) e.key];
  }

  int countFor(String command) => counts[command] ?? 0;

  void dismiss(String command) {
    if (!_safeToRetain(command)) return;
    dismissed.add(command);
  }

  // Existing callers can mutate these collections; guard the disk boundary too.
  Map<String, dynamic> toJson() => {
        'counts': {
          for (final entry in counts.entries)
            if (_safeToRetain(entry.key)) entry.key: entry.value,
        },
        'dismissed': [
          for (final command in dismissed)
            if (_safeToRetain(command)) command,
        ],
      };

  factory CommandStats.fromJson(Map<String, dynamic> json) => CommandStats(
        counts: {
          for (final e in (json['counts'] as Map? ?? {}).entries)
            e.key as String: (e.value as num).toInt(),
        },
        dismissed: {
          for (final d in (json['dismissed'] as List? ?? [])) d as String,
        },
      );
}

/// JSON-file store for [CommandStats]. Kept out of the sync record set on
/// purpose: raw command history can contain material typed at no-echo prompts,
/// so it stays local.
class CommandStatsStore {
  final File file;
  CommandStatsStore(this.file);

  Future<CommandStats> load() async {
    if (!await file.exists()) return CommandStats();
    try {
      return CommandStats.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return CommandStats();
    }
  }

  Future<void> save(CommandStats stats) async {
    await writeStringAtomically(file, jsonEncode(stats.toJson()));
  }
}
