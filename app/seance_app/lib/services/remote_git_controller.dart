import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

/// Session-scoped git state for the sidebar's Git tab: follows the terminal's
/// reported working directory (OSC 7, falling back to a conventional
/// `user@host: dir` title) and re-probes when a git command finishes at the
/// shell. All git execution goes through one [RemoteGit] over the session's
/// exec channel — the interactive terminal is never touched, so a refresh
/// can never disturb what the user is typing.
class RemoteGitController extends ChangeNotifier {
  final RemoteGit _git;
  final ValueListenable<String?> shellDirectory;
  final ValueListenable<String?> terminalTitle;
  final ValueListenable<String?> activeCommand;

  /// Network operations can legitimately outlive the probe's short window:
  /// a `git pull` over a slow link is still working, not hung.
  static const Duration _networkTimeout = Duration(minutes: 2);

  RemoteGitController(
    RemoteCommandRunner run, {
    required this.shellDirectory,
    required this.terminalTitle,
    required this.activeCommand,
  }) : _git = RemoteGit(run) {
    shellDirectory.addListener(_followShellDirectory);
    terminalTitle.addListener(_followShellDirectory);
    activeCommand.addListener(_followActiveCommand);
  }

  bool _disposed = false;
  int _generation = 0;
  String? _lastCommand;

  bool initialized = false;
  bool loading = false;

  /// True while a user-triggered action (stage, commit, pull…) runs. Kept
  /// apart from [loading] so a refresh and an action never pretend to be the
  /// same spinner.
  bool busy = false;

  /// The directory the last probe ran in — what the pane labels as "current".
  String? directory;

  GitProbeResult? result;

  /// A transport-level probe failure ([RemoteCommandException]), or null.
  String? error;

  /// The last action's failure text (git's stderr), or null. Probe failures
  /// live in [error]; this one is dismissible since the status behind it may
  /// be perfectly fresh.
  String? actionError;

  GitRepoStatus? get repo => result?.status;
  GitProbeKind? get probeKind => result?.kind;

  /// Where the remote shell says it is. OSC 7 is authoritative;
  /// Ubuntu/Debian's default Bash emits only an OSC 0 title such as
  /// `root@host: ~/src`, whose `~` form is kept verbatim — the probe command
  /// expands it on the remote side, so no local knowledge of $HOME is needed.
  String? get reportedDirectory {
    final oscDirectory = shellDirectory.value;
    if (_isAbsolutePath(oscDirectory)) return oscDirectory;
    final title = terminalTitle.value?.trim();
    if (title == null) return null;
    final separator = title.indexOf(': ');
    if (separator < 1 || !title.substring(0, separator).contains('@')) {
      return null;
    }
    final location = title.substring(separator + 2).trim();
    if (location.isEmpty) return null;
    if (location == '~' || location == '~/') return '~';
    if (location.startsWith('~/')) return location;
    return _isAbsolutePath(location) ? location : null;
  }

  static bool _isAbsolutePath(String? path) =>
      path != null && path.startsWith('/');

  Future<void> initialize() {
    if (initialized) return Future.value();
    initialized = true;
    return refresh();
  }

  /// Re-probe the reported directory. A directory change while probing is
  /// serialized by [_generation]: the stale response is dropped.
  Future<void> refresh() async {
    final generation = ++_generation;
    final target = reportedDirectory;
    loading = true;
    error = null;
    _notify();
    try {
      if (target == null) {
        // The shell stopped reporting (or never did): a stale repo panel is
        // worse than an honest empty one.
        result = null;
        directory = null;
        return;
      }
      final probe = await _git.probe(target);
      if (_disposed || generation != _generation) return;
      result = probe;
      directory = target;
    } on RemoteCommandException catch (e) {
      if (_disposed || generation != _generation) return;
      error = e.message;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  void _followShellDirectory() {
    if (!initialized || _disposed) return;
    // Probe only on a real move — a null→null or same-dir change is not one.
    if (reportedDirectory == directory) return;
    refresh();
  }

  /// When a command the user typed finishes (OSC 133 reports its end, which
  /// clears [activeCommand]), refresh — but only if it plausibly touched the
  /// repository. Without shell integration this never fires and the manual
  /// refresh remains; that's the best a passive listener can offer.
  void _followActiveCommand() {
    final running = activeCommand.value;
    if (running != null) {
      _lastCommand = running;
      return;
    }
    final finished = _lastCommand;
    _lastCommand = null;
    if (!initialized || _disposed || finished == null) return;
    if (_touchesGit(finished)) refresh();
  }

  /// Whether [command] runs git — at the start or after `&&`/`;`/`|`, under
  /// `sudo`. "git" inside a path or argument doesn't count.
  static bool _touchesGit(String command) {
    for (final segment in command.split(RegExp(r'&&|\|\||[;|]'))) {
      final words = segment.trim().split(RegExp(r'\s+'));
      if (words.isEmpty || words.first.isEmpty) continue;
      if (words.first == 'git') return true;
      if (words.first == 'sudo' && words.length > 1 && words[1] == 'git') {
        return true;
      }
    }
    return false;
  }

  void dismissActionError() {
    if (actionError == null) return;
    actionError = null;
    _notify();
  }

  /// The directory an action runs in: the probed one, or — before the first
  /// probe lands — the shell's current report.
  String? get _actionDirectory => directory ?? reportedDirectory;

  Future<RemoteCommandResult?> _action(
    List<String> args, {
    Duration? timeout,
  }) async {
    final dir = _actionDirectory;
    if (dir == null) {
      actionError = 'The shell has not reported its directory yet.';
      _notify();
      return null;
    }
    busy = true;
    actionError = null;
    _notify();
    RemoteCommandResult? outcome;
    try {
      final result = await _git.run(dir, args, timeout: timeout);
      if (_disposed) return null;
      if (!result.succeeded) {
        final detail = result.stderr.trim().isNotEmpty
            ? result.stderr.trim()
            : result.stdout.trim();
        actionError = detail.isNotEmpty
            ? detail
            : 'git exited with code ${result.exitCode ?? 'unknown'}.';
      } else {
        outcome = result;
      }
    } on RemoteCommandException catch (e) {
      if (!_disposed) actionError = e.message;
    } finally {
      if (!_disposed) {
        busy = false;
        _notify();
      }
    }
    // Whatever the action changed shows up in a fresh probe; a failed one
    // may still have moved the index (a partial pull merge, say).
    if (!_disposed) await refresh();
    return outcome;
  }

  Future<RemoteCommandResult?> stageFile(String path) =>
      _action(['add', '--', path]);
  Future<RemoteCommandResult?> unstageFile(String path) =>
      _action(['reset', '-q', '--', path]);
  Future<RemoteCommandResult?> stageAll() => _action(['add', '-A']);
  Future<RemoteCommandResult?> unstageAll() => _action(['reset', '-q']);

  /// Restore a tracked path's worktree to the index. `checkout --` rather
  /// than `restore`: identical here and understood by every git vintage.
  Future<RemoteCommandResult?> discardFile(String path) =>
      _action(['checkout', '--', path]);

  Future<RemoteCommandResult?> commit(String message) =>
      _action(['commit', '-m', message]);

  Future<RemoteCommandResult?> fetch() =>
      _action(['fetch', '--all', '--prune'], timeout: _networkTimeout);
  Future<RemoteCommandResult?> pull() =>
      _action(['pull'], timeout: _networkTimeout);
  Future<RemoteCommandResult?> push() =>
      _action(['push'], timeout: _networkTimeout);

  Future<RemoteCommandResult?> checkoutBranch(String name) =>
      _action(['checkout', name]);
  Future<RemoteCommandResult?> createBranch(String name) =>
      _action(['checkout', '-b', name]);
  Future<RemoteCommandResult?> stashPush() => _action(['stash', 'push']);
  Future<RemoteCommandResult?> stashPop() => _action(['stash', 'pop']);
  Future<RemoteCommandResult?> initRepository() => _action(['init']);

  /// Local branches for the switch-branch picker, or empty on failure.
  Future<List<String>> branches() => _git.branches(_actionDirectory);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    shellDirectory.removeListener(_followShellDirectory);
    terminalTitle.removeListener(_followShellDirectory);
    activeCommand.removeListener(_followActiveCommand);
    super.dispose();
  }
}
