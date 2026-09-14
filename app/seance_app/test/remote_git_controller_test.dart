import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/remote_git_controller.dart';
import 'package:seance_core/seance_core.dart';

/// NUL, spelled without a Dart escape so the intent survives formatters.
final _nul = String.fromCharCode(0);

/// A runner that records its commands and answers through a handler, so a
/// test can drive refreshes and actions without a transport.
class _Runner {
  final List<String> commands = [];
  RemoteCommandResult Function(String command) onRun = (_) =>
      const RemoteCommandResult(exitCode: 0);

  Future<RemoteCommandResult> call(String command, {Duration? timeout}) async {
    commands.add(command);
    return onRun(command);
  }
}

RemoteCommandResult _repo({
  String root = '/srv/app',
  String branch = 'main',
  String changes = '',
  String log = 'abc1234\tlatest commit\n',
}) => RemoteCommandResult(
  stdout:
      '$root\n'
      '# branch.oid deadbeef\n'
      '# branch.head $branch\n'
      '$changes'
      '$_nul'
      '$log',
  exitCode: 0,
);

RemoteCommandResult _notRepo() => const RemoteCommandResult(
  stdout: '',
  stderr:
      'fatal: not a git repository (or any of the parent directories): .git',
  exitCode: 128,
);

/// The probe's refresh is async all the way down; pumpEventQueue drains
/// listener-triggered work deterministically regardless of hop count.
Future<void> _settle() => pumpEventQueue();

void main() {
  late ValueNotifier<String?> shellDirectory;
  late ValueNotifier<String?> terminalTitle;
  late ValueNotifier<String?> activeCommand;
  late _Runner runner;
  late RemoteGitController controller;

  setUp(() {
    shellDirectory = ValueNotifier<String?>(null);
    terminalTitle = ValueNotifier<String?>(null);
    activeCommand = ValueNotifier<String?>(null);
    runner = _Runner();
    controller = RemoteGitController(
      runner.call,
      shellDirectory: shellDirectory,
      terminalTitle: terminalTitle,
      activeCommand: activeCommand,
    );
  });

  tearDown(() {
    controller.dispose();
    shellDirectory.dispose();
    terminalTitle.dispose();
    activeCommand.dispose();
  });

  test('waits without probing until the shell reports a directory', () async {
    await controller.initialize();
    expect(runner.commands, isEmpty);
    expect(controller.result, isNull);
    expect(controller.reportedDirectory, isNull);
  });

  test('probes the OSC 7 directory and parses the repository', () async {
    shellDirectory.value = '/srv/app';
    runner.onRun = (_) => _repo();
    await controller.initialize();

    expect(
      runner.commands.single,
      startsWith("export LC_ALL=C; cd -- '/srv/app' && "),
    );
    final repo = controller.repo!;
    expect(repo.branch, 'main');
    expect(repo.recentCommits.single.subject, 'latest commit');
    expect(controller.directory, '/srv/app');
    expect(controller.error, isNull);
  });

  test('falls back to a ~/ title directory when OSC 7 is absent', () async {
    terminalTitle.value = 'root@server: ~/proj';
    runner.onRun = (_) => _repo(root: '/root/proj');
    await controller.initialize();

    expect(controller.reportedDirectory, '~/proj');
    expect(
      runner.commands.single,
      startsWith("export LC_ALL=C; cd -- ~/'proj' && "),
    );
  });

  test('re-probes when the reported directory changes', () async {
    shellDirectory.value = '/srv/app';
    runner.onRun = (_) => _repo();
    await controller.initialize();
    expect(runner.commands, hasLength(1));

    shellDirectory.value = '/srv/other';
    await _settle();
    expect(runner.commands, hasLength(2));
    expect(
      runner.commands.last,
      startsWith("export LC_ALL=C; cd -- '/srv/other' && "),
    );
    expect(controller.directory, '/srv/other');
  });

  test('reports a non-repo directory', () async {
    shellDirectory.value = '/srv/app';
    runner.onRun = (_) => _notRepo();
    await controller.initialize();
    expect(controller.probeKind, GitProbeKind.notARepository);
    expect(controller.repo, isNull);
  });

  test('refreshes when a git command finishes at the prompt', () async {
    shellDirectory.value = '/srv/app';
    runner.onRun = (_) => _repo();
    await controller.initialize();
    expect(runner.commands, hasLength(1));

    activeCommand.value = 'git commit -m wip';
    activeCommand.value = null;
    await _settle();
    expect(runner.commands, hasLength(2));
  });

  test('ignores finished commands that do not run git', () async {
    shellDirectory.value = '/srv/app';
    runner.onRun = (_) => _repo();
    await controller.initialize();
    expect(runner.commands, hasLength(1));

    for (final command in [
      'vim digital-ocean-notes.md',
      'echo digit',
      'git-upload-pack /srv/repo',
    ]) {
      activeCommand.value = command;
      activeCommand.value = null;
      await _settle();
      expect(runner.commands, hasLength(1), reason: command);
    }
  });

  test('refreshes for git inside compounds and substitutions', () async {
    shellDirectory.value = '/srv/app';
    runner.onRun = (_) => _repo();
    await controller.initialize();
    var probes = 1; // initialize() itself
    expect(runner.commands, hasLength(probes));

    for (final command in [
      'echo "\$(git log --oneline)"',
      'export V=\$(git rev-parse HEAD)',
      'xargs git checkout --',
      'GIT_DIR=.git git status',
      'make foo | tee log && sudo git status',
    ]) {
      activeCommand.value = command;
      activeCommand.value = null;
      await _settle();
      expect(runner.commands, hasLength(++probes), reason: command);
    }
  });

  test('stages a file and refreshes afterwards', () async {
    shellDirectory.value = '/srv/app';
    runner.onRun = (_) => _repo();
    await controller.initialize();

    runner.onRun = (command) =>
        command.contains('git') && !command.contains('rev-parse')
        ? const RemoteCommandResult(exitCode: 0)
        : _repo(changes: '1 A. N... 100644 100644 100644 h h file.txt$_nul');
    final result = await controller.stageFile('file.txt');

    expect(result, isNotNull);
    expect(runner.commands[1], contains("git 'add' '--' 'file.txt'"));
    // The post-action probe re-read the index.
    expect(controller.repo!.staged.single.path, 'file.txt');
  });

  test('surfaces a failed action without touching the repo state', () async {
    shellDirectory.value = '/srv/app';
    runner.onRun = (_) => _repo();
    await controller.initialize();

    runner.onRun = (command) => command.contains('rev-parse')
        ? _repo()
        : const RemoteCommandResult(
            stderr: 'error: pathspec did not match',
            exitCode: 1,
          );
    final result = await controller.stageFile('missing.txt');
    expect(result, isNull);
    // A failed action must not clear or corrupt the displayed repo state.
    expect(controller.repo, isNotNull);
    expect(controller.repo!.branch, 'main');
    expect(controller.actionError, contains('pathspec'));
    controller.dismissActionError();
    expect(controller.actionError, isNull);
  });

  test('rejects a second action while one is in flight', () async {
    shellDirectory.value = '/srv/app';
    runner.onRun = (_) => _repo();
    await controller.initialize();

    var gitCalls = 0;
    runner.onRun = (command) {
      if (command.contains('rev-parse')) return _repo();
      gitCalls++;
      return const RemoteCommandResult(exitCode: 0);
    };

    // busy flips synchronously, so the overlapping call never runs.
    final first = controller.stageFile('a.txt');
    expect(await controller.stageAll(), isNull);
    await first;
    await _settle();
    expect(gitCalls, 1);
    expect(controller.busy, isFalse);
  });

  test('surfaces a transport failure as an error', () async {
    shellDirectory.value = '/srv/app';
    runner.onRun = (_) => throw const RemoteCommandException('session dropped');
    await controller.initialize();
    expect(controller.error, 'session dropped');
    expect(controller.result, isNull);
  });
}
