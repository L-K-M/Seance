import 'dart:convert';

import 'package:http/http.dart' as http;

import 'version.dart';

/// The result of an update check.
class UpdateInfo {
  /// The latest published version tag (e.g. `0.3.0`), normalized (no leading
  /// `v`).
  final String latestVersion;

  /// The human-facing page to send the user to. Deliberately the releases
  /// page, not a binary — Séance never downloads or installs an update; the
  /// user decides.
  final Uri releasesUrl;

  const UpdateInfo({required this.latestVersion, required this.releasesUrl});
}

/// Checks GitHub for a newer Séance release than the one running.
///
/// This is read-only and best-effort: it only ever *reports* that a newer
/// version exists and points the user at the releases page. It never fetches
/// or installs anything. On any error (offline, rate-limited, malformed
/// response) it returns null so the caller can silently carry on.
class UpdateChecker {
  final http.Client _client;
  final Duration timeout;

  /// `owner/repo` whose releases are checked.
  final String repo;

  UpdateChecker({
    this.repo = 'L-K-M/Seance',
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  Uri get _latestReleaseApi =>
      Uri.parse('https://api.github.com/repos/$repo/releases/latest');

  /// The public releases page (where the check sends the user).
  Uri get releasesPage =>
      Uri.parse('https://github.com/$repo/releases/latest');

  /// Returns [UpdateInfo] when GitHub's latest release is strictly newer than
  /// [currentVersion]; null when up to date, when the check can't be completed,
  /// or when either version is unparseable.
  Future<UpdateInfo?> check(String currentVersion) async {
    try {
      final res = await _client.get(
        _latestReleaseApi,
        headers: const {
          'Accept': 'application/vnd.github+json',
          // GitHub requires a User-Agent or it returns 403.
          'User-Agent': 'Seance-update-check',
        },
      ).timeout(timeout);

      // GitHub answers 404 when a repo has no published (non-draft) release,
      // and 403 when rate-limited; both mean "nothing to report".
      if (res.statusCode != 200) return null;

      final body = jsonDecode(res.body);
      if (body is! Map<String, dynamic>) return null;
      final tag = body['tag_name'];
      // Skip drafts/prereleases — only stable releases should nag.
      if (body['draft'] == true || body['prerelease'] == true) return null;
      if (tag is! String) return null;

      if (!AppVersion.isNewer(current: currentVersion, candidate: tag)) {
        return null;
      }
      final parsed = AppVersion.tryParse(tag);
      return UpdateInfo(
        latestVersion: parsed?.toString() ?? tag,
        releasesUrl: releasesPage,
      );
    } catch (_) {
      // Offline / timeout / malformed JSON — never surface as an error.
      return null;
    }
  }
}
