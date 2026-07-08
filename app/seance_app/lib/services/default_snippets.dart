import 'package:seance_core/seance_core.dart';

/// Snippets seeded on first launch so the Snippets tab isn't empty. Curated for
/// "useful but easy to forget" — the flag combos and modern replacements people
/// look up every time.
///
/// Ids are STABLE and timestamps FIXED so that if the same defaults are seeded
/// on two devices, sync merges them by id instead of creating duplicates; any
/// later user edit (with a real, larger timestamp) wins under last-write-wins.
List<Snippet> defaultSnippets() {
  // 2024-01-01T00:00:00Z — arbitrary but constant across devices.
  const ts = 1704067200000;
  Snippet s(String id, String title, String body) => Snippet(
        id: 'seed-$id',
        title: title,
        body: body,
        createdAt: ts,
        updatedAt: ts,
      );

  return [
    s('disk-usage', 'Disk usage: biggest items in a folder',
        r'du -ahx {{path}} | sort -rh | head -20'),
    s('port-listener', "What's listening on a port",
        r'sudo ss -tulpn | grep :{{port}}'),
    s('tail-grep', 'Follow a log, filtered',
        r'tail -f {{logfile}} | grep --line-buffered {{pattern}}'),
    s('journal-follow', "Follow a service's logs (systemd)",
        r'journalctl -u {{service}} -f'),
    s('service-restart', 'Restart a service and check status',
        r'sudo systemctl restart {{service}} && systemctl status {{service}} --no-pager'),
    s('top-mem', 'Top memory-hungry processes',
        r'ps aux --sort=-%mem | head -12'),
    s('find-recent', 'Files changed in the last N minutes',
        r'find {{path}} -type f -mmin -{{minutes}}'),
    s('tmux', 'Reattach or start a tmux session',
        r'tmux new -A -s {{name}}'),
    s('http-server', 'Serve the current folder over HTTP',
        r'python3 -m http.server {{port}}'),
    s('web-perms', 'Reset web permissions (dirs 755, files 644)',
        r'find {{path}} -type d -exec chmod 755 {} \; && find {{path}} -type f -exec chmod 644 {} \;'),
    s('cert-dates', "Check a site's TLS certificate dates",
        r'echo | openssl s_client -connect {{host}}:443 -servername {{host}} 2>/dev/null | openssl x509 -noout -dates'),
    s('watch', 'Watch a command update live',
        r'watch -n {{seconds}} {{command}}'),
    s('rsync', 'Copy files with progress (rsync)',
        r'rsync -avh --progress {{source}} {{destination}}'),
  ];
}
