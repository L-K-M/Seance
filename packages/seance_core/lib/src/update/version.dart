/// A minimal dotted-numeric version (`MAJOR.MINOR.PATCH…`), enough to compare
/// Séance's own releases. Deliberately not a full SemVer implementation — the
/// release tags this compares are plain `vX.Y.Z` cut by `scripts/release.sh`,
/// so a pre-release/build-metadata parser would be dead weight.
class AppVersion implements Comparable<AppVersion> {
  /// The numeric components, most-significant first. Missing trailing
  /// components compare as zero (so `1.2` == `1.2.0`).
  final List<int> parts;

  const AppVersion(this.parts);

  /// Parses `1.2.3`, tolerating a leading `v`/`V` (release tags are `v1.2.3`)
  /// and surrounding whitespace, and ignoring any `-pre`/`+build` suffix.
  /// Returns null when there is no leading numeric component to compare.
  static AppVersion? tryParse(String? input) {
    if (input == null) return null;
    var s = input.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // Drop a pre-release/build suffix: keep only up to the first '-' or '+'.
    final cut = s.indexOf(RegExp('[-+]'));
    if (cut >= 0) s = s.substring(0, cut);
    final parts = <int>[];
    for (final segment in s.split('.')) {
      final n = int.tryParse(segment.trim());
      if (n == null || n < 0) return null;
      parts.add(n);
    }
    if (parts.isEmpty) return null;
    return AppVersion(parts);
  }

  @override
  int compareTo(AppVersion other) {
    final len = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;
    for (var i = 0; i < len; i++) {
      final a = i < parts.length ? parts[i] : 0;
      final b = i < other.parts.length ? other.parts[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  /// Whether [candidate] is strictly newer than [current]. False (safe) if
  /// either can't be parsed — an unreadable version never nags the user.
  static bool isNewer({required String? current, required String? candidate}) {
    final c = tryParse(current);
    final n = tryParse(candidate);
    if (c == null || n == null) return false;
    return n.compareTo(c) > 0;
  }

  @override
  String toString() => parts.join('.');

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(_trimmed);

  List<int> get _trimmed {
    var end = parts.length;
    while (end > 1 && parts[end - 1] == 0) {
      end--;
    }
    return parts.sublist(0, end);
  }
}
