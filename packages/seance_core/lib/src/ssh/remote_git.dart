import 'remote_command.dart';

/// Which half of the working-tree/index pair a [GitFileStatus] entry
/// describes, derived from porcelain's `XY` columns.
enum GitChangeKind {
  /// A tracked file with staged and/or unstaged modifications.
  ordinary,

  /// A staged rename or copy (`R`/`C` in the index column).
  renamed,

  /// An unmerged path left by a conflicted merge or rebase.
  unmerged,

  /// `?` — present in the working tree, unknown to git.
  untracked,

  /// `!` — ignored; only reported when status is asked for ignored files.
  ignored,
}

/// One path's status as porcelain reports it: [stagedLetter] is the index→HEAD
/// column (`X`) and [unstagedLetter] the worktree→index column (`Y`), with
/// `.` meaning unchanged on that side.
class GitFileStatus {
  final String path;

  /// The path a rename was moved *from*, when [kind] is [GitChangeKind.renamed].
  final String? originalPath;

  final String stagedLetter;
  final String unstagedLetter;
  final GitChangeKind kind;

  const GitFileStatus({
    required this.path,
    this.originalPath,
    this.stagedLetter = '.',
    this.unstagedLetter = '.',
    this.kind = GitChangeKind.ordinary,
  });

  /// The index holds a change for this path that HEAD doesn't have. Unmerged
  /// paths carry conflict letters (`U`/`A`/`D`), not staged state, so they
  /// are excluded here and surface through [GitRepoStatus.conflicted] only.
  bool get isStaged =>
      (kind == GitChangeKind.ordinary || kind == GitChangeKind.renamed) &&
      stagedLetter != '.';

  /// The working tree differs from the index for this path.
  bool get isUnstaged =>
      kind == GitChangeKind.ordinary || kind == GitChangeKind.renamed
      ? unstagedLetter != '.'
      : false;
}

/// A one-line commit from `git log --format='%h%x09%s'`.
class GitCommitRef {
  final String id;
  final String subject;

  const GitCommitRef(this.id, this.subject);
}

/// What `git status` reported for a directory that turned out to be inside a
/// repository, plus the recent history the pane shows for context.
class GitRepoStatus {
  /// The repository's top-level directory — which may be a parent of the
  /// directory that was probed.
  final String? rootPath;

  /// The checked-out branch, or null on a detached HEAD.
  final String? branch;
  final bool detached;
  final String? commitId;
  final String? upstream;
  final int ahead;
  final int behind;

  /// Stashes in the repository, or null when the status format couldn't
  /// report them (porcelain v1 on git < 2.11, or v2 without `--show-stash`
  /// on 2.11–2.16). 0 means "no stashes", not "unknown".
  final int? stashCount;
  final List<GitFileStatus> changes;
  final List<GitCommitRef> recentCommits;

  const GitRepoStatus({
    this.rootPath,
    this.branch,
    this.detached = false,
    this.commitId,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.stashCount,
    this.changes = const [],
    this.recentCommits = const [],
  });

  List<GitFileStatus> get conflicted => [
    for (final c in changes)
      if (c.kind == GitChangeKind.unmerged) c,
  ];

  List<GitFileStatus> get staged => [
    for (final c in changes)
      if (c.isStaged) c,
  ];

  /// Tracked worktree-vs-index changes only. Untracked, unmerged, and
  /// ignored entries are excluded — render those via [untracked] and
  /// [conflicted].
  List<GitFileStatus> get unstaged => [
    for (final c in changes)
      if (c.isUnstaged) c,
  ];

  List<GitFileStatus> get untracked => [
    for (final c in changes)
      if (c.kind == GitChangeKind.untracked) c,
  ];
}

enum GitProbeKind { ok, notInstalled, notARepository, error }

/// The outcome of probing one directory for a git repository. [status] is set
/// only when [kind] is [GitProbeKind.ok]; [detail] carries the remote error
/// text for [GitProbeKind.error].
class GitProbeResult {
  final GitProbeKind kind;
  final GitRepoStatus? status;
  final String? detail;

  const GitProbeResult._(this.kind, this.status, this.detail);

  const GitProbeResult.ok(GitRepoStatus status)
    : this._(GitProbeKind.ok, status, null);
  const GitProbeResult.notInstalled()
    : this._(GitProbeKind.notInstalled, null, null);
  const GitProbeResult.notARepository()
    : this._(GitProbeKind.notARepository, null, null);
  const GitProbeResult.error(String detail)
    : this._(GitProbeKind.error, null, detail);
}

/// Runs git against a remote directory over an SSH exec channel.
///
/// Everything goes through one [RemoteCommandRunner] so the whole class —
/// command construction, porcelain parsing, and failure classification — is
/// testable without a transport. The runner's channel never touches the
/// interactive shell: the user's prompt and scrollback stay theirs.
///
/// Old gits matter: `--porcelain=v2` needs git 2.11 (2016) and hosts like
/// CentOS 7 still ship 1.8, so a usage-level failure retries down a ladder —
/// v2 with stash, v2, then the v1 format, which has existed forever.
class RemoteGit {
  final RemoteCommandRunner _run;

  const RemoteGit(this._run);

  /// Probe [directory] for a repository and read its status. A null or
  /// relative [directory] runs in the exec channel's own working directory
  /// (the remote home); absolute and `~/`-relative paths are `cd`'d into.
  ///
  /// [RemoteCommandException] (transport failure) propagates — the caller
  /// owns the distinction between "the command ran and git complained" and
  /// "no command ran at all".
  Future<GitProbeResult> probe(String? directory) async {
    var result = await _run(_statusCommand(directory, porcelainV2: true));
    var parser = _parseV2;
    if (_isUsageError(result)) {
      // git 2.11–2.16 knows --porcelain=v2 but not --show-stash: drop just
      // the flag before assuming the whole v2 format is missing.
      result = await _run(
        _statusCommand(directory, porcelainV2: true, showStash: false),
      );
      if (_isUsageError(result)) {
        // git < 2.11 has no --porcelain=v2 at all; v1 reports the same
        // changes minus the stash count.
        result = await _run(_statusCommand(directory, porcelainV2: false));
        parser = _parseV1;
      }
    }
    final failure = _classify(result);
    if (failure != null) return failure;

    final GitRepoStatus repo;
    try {
      final payload = _splitStatusOutput(result.stdout);
      repo = parser(payload).copyWith(
        rootPath: payload.root,
        recentCommits: _parseLog(payload.logLines),
      );
    } on FormatException catch (e) {
      return GitProbeResult.error('Could not parse git status: ${e.message}');
    }
    return GitProbeResult.ok(repo);
  }

  /// `git <args>` in [directory]. Each argument is quoted verbatim, so a path
  /// or commit message can carry spaces and shell metacharacters safely.
  /// `--` belongs in [args] wherever the caller means end-of-options.
  Future<RemoteCommandResult> run(
    String? directory,
    List<String> args, {
    Duration? timeout,
  }) => _run(
    '${_cdPrefix(directory)}git ${args.map(_quotePosix).join(' ')}',
    timeout: timeout,
  );

  /// Local branch names for a switch-branch picker, or null when the listing
  /// itself fails — callers can then tell "couldn't ask" apart from a repo
  /// with zero branches. `for-each-ref` rather than `git branch --format`:
  /// the former exists on every git vintage the v1 status fallback still
  /// supports.
  Future<List<String>?> branches(String? directory) async {
    final result = await run(directory, const [
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/heads',
    ]);
    if (!result.succeeded) return null;
    return [
      for (final line in result.stdout.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  /// One round trip: repo root, porcelain status, and recent history, joined
  /// by `&&` so a non-repo stops before status runs (its `fatal:` lands in
  /// stderr for [_classify]). The `printf` NUL before the log is a delimiter:
  /// status entries are already NUL-separated, so the log lands in its own
  /// final NUL-field whatever the entry count. `|| true` keeps a repo with no
  /// commits (whose `git log` exits 128) from failing the whole probe.
  static String _statusCommand(
    String? directory, {
    required bool porcelainV2,
    bool showStash = true,
  }) {
    final format = porcelainV2
        ? '--porcelain=v2 --branch${showStash ? ' --show-stash' : ''}'
        // `--porcelain=v1` only parses on gits that already know v2; the
        // fallback targets older ones, where the flag is a bare boolean.
        : '--porcelain --branch';
    // LC_ALL=C keeps the diagnostics [_isUsageError] and [_classify] match
    // stable regardless of the remote locale; porcelain output is unaffected.
    return 'export LC_ALL=C; ${_cdPrefix(directory)}'
        'git rev-parse --show-toplevel && '
        "git status $format -z && printf '\\0' && "
        "{ git log --format='%h%x09%s' -n 12 2>/dev/null || true; }";
  }

  /// The `cd` half of a probe/action command. `~` stays unquoted — it must
  /// reach the remote shell to expand; the remainder of a `~/x` path is
  /// quoted against metacharacters.
  static String _cdPrefix(String? directory) {
    if (directory == null || directory.isEmpty) return '';
    if (directory == '~' || directory == '~/') return 'cd -- ~ && ';
    if (directory.startsWith('~/')) {
      return 'cd -- ~/${_quotePosix(directory.substring(2))} && ';
    }
    return 'cd -- ${_quotePosix(directory)} && ';
  }

  /// An exit that means "git never parsed this command": usage errors come
  /// back 129, and some very old builds answer unknown options with git's
  /// usage text on stderr at other codes.
  static bool _isUsageError(RemoteCommandResult result) =>
      result.exitCode == 129 ||
      (result.exitCode != 0 && result.stderr.trimLeft().startsWith('usage:'));

  /// The non-ok [GitProbeResult] a failed probe maps to, or null when the
  /// command succeeded and its output should be parsed.
  static GitProbeResult? _classify(RemoteCommandResult result) {
    if (result.succeeded) return null;
    final err = result.stderr.trim();
    // 127 is the shell's "no such command"; git not being installed is a
    // fact about the host, not about the directory. Match the shell's own
    // phrasing precisely — a `cd` failure into a path containing "git"
    // ("cd: /home/u/git: No such file…") must not read as a missing binary.
    final shellCannotFindGit =
        RegExp(r'git: (command )?not found').hasMatch(err) ||
        RegExp(r'command not found: git').hasMatch(err);
    if (result.exitCode == 127 || shellCannotFindGit) {
      return const GitProbeResult.notInstalled();
    }
    if (err.contains('not a git repository')) {
      return const GitProbeResult.notARepository();
    }
    return GitProbeResult.error(
      err.isEmpty
          ? 'git exited with code ${result.exitCode ?? 'unknown'}.'
          : err,
    );
  }
}

/// A probe output split into its four regions: the `rev-parse` root line,
/// the `#`/`##` header lines, the file entries (a rename's *original* path is
/// its own entry slot — consumed by the entry before it), and the log lines.
class _StatusPayload {
  String? root;
  final List<String> headers = [];
  final List<String> entries = [];
  final List<String> logLines = [];
}

_StatusPayload _splitStatusOutput(String stdout) {
  final payload = _StatusPayload();
  final parts = stdout.split(String.fromCharCode(0));
  // The printf delimiter guarantees a trailing field for the log even when
  // there are no file entries.
  if (parts.length > 1) {
    payload.logLines.addAll(
      parts.last.split('\n').where((line) => line.trim().isNotEmpty),
    );
  }

  // The first field holds the LF-terminated root line and headers, then —
  // still inside the same NUL field — the first file entry. Headers always
  // lead, so a leading '#' marks them; whatever remains is the entry.
  var rest = parts.first;
  final firstBreak = rest.indexOf('\n');
  if (firstBreak < 0) {
    throw FormatException(
      'Malformed git status payload (missing root line): $stdout',
    );
  }
  payload.root = rest.substring(0, firstBreak);
  rest = rest.substring(firstBreak + 1);
  while (rest.startsWith('#')) {
    final nextBreak = rest.indexOf('\n');
    if (nextBreak < 0) {
      payload.headers.add(rest);
      rest = '';
      break;
    }
    payload.headers.add(rest.substring(0, nextBreak));
    rest = rest.substring(nextBreak + 1);
  }
  if (rest.isNotEmpty) payload.entries.add(rest);
  for (var i = 1; i < parts.length - 1; i++) {
    // Adjacent NULs (an entry's terminator abutting the log delimiter) leave
    // empty fields.
    if (parts[i].isNotEmpty) payload.entries.add(parts[i]);
  }
  return payload;
}

/// The path half of a porcelain record: after exactly [fields]
/// space-separated leading fields, the rest is the path verbatim (`-z` output
/// never quotes, so spaces inside it are safe).
String? _afterFields(String entry, int fields) {
  var position = 0;
  for (var i = 0; i < fields; i++) {
    final space = entry.indexOf(' ', position);
    if (space < 0) return null;
    position = space + 1;
  }
  return entry.substring(position);
}

List<GitCommitRef> _parseLog(List<String> logLines) => [
  for (final line in logLines)
    if (line.contains('\t'))
      GitCommitRef(
        line.substring(0, line.indexOf('\t')),
        line.substring(line.indexOf('\t') + 1),
      ),
];

extension on GitRepoStatus {
  GitRepoStatus copyWith({
    String? rootPath,
    List<GitCommitRef>? recentCommits,
  }) => GitRepoStatus(
    rootPath: rootPath ?? this.rootPath,
    branch: branch,
    detached: detached,
    commitId: commitId,
    upstream: upstream,
    ahead: ahead,
    behind: behind,
    stashCount: stashCount,
    changes: changes,
    recentCommits: recentCommits ?? this.recentCommits,
  );
}

/// `--porcelain=v2 --branch --show-stash` headers plus `1`/`2`/`u`/`?`/`!`
/// entries. A `2` entry is followed in [payload.entries] by its rename
/// source.
GitRepoStatus _parseV2(_StatusPayload payload) {
  String? branch, upstream, commitId;
  var detached = false, ahead = 0, behind = 0;
  // Absent on the no-stash middle rung (git 2.11–2.16) — stays null, which
  // reads as "unknown" rather than a confident zero.
  int? stashCount;
  for (final header in payload.headers) {
    final line = header.startsWith('#') ? header.substring(1).trim() : header;
    if (line.startsWith('branch.oid ')) {
      final value = line.substring(11).trim();
      commitId = value == '(initial)' ? null : value;
    } else if (line.startsWith('branch.head ')) {
      final value = line.substring(12).trim();
      if (value == '(detached)') {
        detached = true;
      } else {
        branch = value;
      }
    } else if (line.startsWith('branch.upstream ')) {
      upstream = line.substring(16).trim();
    } else if (line.startsWith('branch.ab ')) {
      for (final part in line.substring(10).split(' ')) {
        if (part.startsWith('+')) {
          ahead = int.tryParse(part.substring(1)) ?? 0;
        } else if (part.startsWith('-')) {
          behind = int.tryParse(part.substring(1)) ?? 0;
        }
      }
    } else if (line.startsWith('stash ')) {
      stashCount = int.tryParse(line.substring(6).trim()) ?? 0;
    }
  }

  final changes = <GitFileStatus>[];
  for (var i = 0; i < payload.entries.length; i++) {
    final entry = payload.entries[i];
    if (entry.startsWith('? ')) {
      changes.add(
        GitFileStatus(path: entry.substring(2), kind: GitChangeKind.untracked),
      );
      continue;
    }
    if (entry.startsWith('! ')) {
      changes.add(
        GitFileStatus(path: entry.substring(2), kind: GitChangeKind.ignored),
      );
      continue;
    }
    if (entry.length < 4) continue;
    // `1`: 8 fields then path; `2`: 9 then path; `u`: 10 then path. The XY
    // pair sits at fixed offset in all three.
    final kind = entry[0];
    final path = switch (kind) {
      '1' => _afterFields(entry, 8),
      '2' => _afterFields(entry, 9),
      'u' => _afterFields(entry, 10),
      _ => null,
    };
    if (path == null) continue;
    String? original;
    if (kind == '2' && i + 1 < payload.entries.length) {
      original = payload.entries[++i];
    }
    changes.add(
      GitFileStatus(
        path: path,
        originalPath: original,
        stagedLetter: entry[2],
        unstagedLetter: entry[3],
        kind: switch (kind) {
          '2' => GitChangeKind.renamed,
          'u' => GitChangeKind.unmerged,
          _ => GitChangeKind.ordinary,
        },
      ),
    );
  }

  return GitRepoStatus(
    branch: branch,
    detached: detached,
    commitId: commitId,
    upstream: upstream,
    ahead: ahead,
    behind: behind,
    stashCount: stashCount,
    changes: changes,
  );
}

/// `--porcelain=v1 --branch`: `##` header plus `XY path` entries (`??`/`!!`
/// for untracked/ignored). Renames carry `X` or `Y` == `R` and are followed
/// in [payload.entries] by the rename source.
GitRepoStatus _parseV1(_StatusPayload payload) {
  String? branch, upstream;
  var detached = false, ahead = 0, behind = 0;
  for (final header in payload.headers) {
    if (!header.startsWith('## ')) continue;
    var line = header.substring(3).trim();
    if (line.startsWith('No commits yet on ')) {
      branch = line.substring(18).trim();
      continue;
    }
    if (line == 'HEAD (no branch)') {
      detached = true;
      continue;
    }
    // Trailing "[ahead N, behind M]"/"[gone]" block, if present.
    final bracket = line.lastIndexOf(' [');
    if (bracket >= 0 && line.endsWith(']')) {
      final ab = line.substring(bracket + 2, line.length - 1);
      for (final part in ab.split(',')) {
        final words = part.trim().split(' ');
        if (words.length != 2) continue;
        final count = int.tryParse(words[1]) ?? 0;
        if (words[0] == 'ahead') ahead = count;
        if (words[0] == 'behind') behind = count;
      }
      line = line.substring(0, bracket);
    }
    final dots = line.indexOf('...');
    if (dots > 0) {
      branch = line.substring(0, dots);
      upstream = line.substring(dots + 3);
    } else if (line.isNotEmpty) {
      branch = line;
    }
  }

  final changes = <GitFileStatus>[];
  for (var i = 0; i < payload.entries.length; i++) {
    final entry = payload.entries[i];
    if (entry.length < 4) continue;
    if (entry.startsWith('?? ')) {
      changes.add(
        GitFileStatus(path: entry.substring(3), kind: GitChangeKind.untracked),
      );
      continue;
    }
    if (entry.startsWith('!! ')) {
      changes.add(
        GitFileStatus(path: entry.substring(3), kind: GitChangeKind.ignored),
      );
      continue;
    }
    // v1 marks an unchanged column with a space; normalize to the `.`
    // convention the model documents so isStaged/isUnstaged hold.
    final staged = entry[0] == ' ' ? '.' : entry[0];
    final unstaged = entry[1] == ' ' ? '.' : entry[1];
    String? original;
    if ((staged == 'R' || unstaged == 'R') && i + 1 < payload.entries.length) {
      original = payload.entries[++i];
    }
    changes.add(
      GitFileStatus(
        path: entry.substring(3),
        originalPath: original,
        stagedLetter: staged,
        unstagedLetter: unstaged,
        kind: original != null
            ? GitChangeKind.renamed
            : staged == 'U' ||
                  unstaged == 'U' ||
                  entry.startsWith('AA') ||
                  entry.startsWith('DD')
            ? GitChangeKind.unmerged
            : GitChangeKind.ordinary,
      ),
    );
  }

  return GitRepoStatus(
    branch: branch,
    detached: detached,
    upstream: upstream,
    ahead: ahead,
    behind: behind,
    changes: changes,
  );
}

/// POSIX single-quote for one argument — the same spelling
/// `buildChangeDirectoryCommand` emits, kept private so each file owns its
/// quoting dialect.
String _quotePosix(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
