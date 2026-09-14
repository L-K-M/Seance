import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// NUL, spelled without a Dart escape so the intent survives formatters.
final _nul = String.fromCharCode(0);

/// A runner that answers canned results by command order, and records every
/// command it was handed so construction can be asserted too.
class _FakeRunner {
  final List<String> commands = [];
  final List<RemoteCommandResult> results;

  _FakeRunner(this.results);

  RemoteCommandRunner get call => (command, {timeout}) async {
    commands.add(command);
    return results.removeAt(0);
  };
}

RemoteCommandResult _result(
  String stdout, {
  String stderr = '',
  int? exitCode = 0,
}) => RemoteCommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode);

void main() {
  group('RemoteGit.probe', () {
    test('parses a porcelain v2 status with every change kind', () async {
      const h = 'a1b2c3d4e5f6';
      final stdout =
          '/srv/app\n'
          '# branch.oid $h\n'
          '# branch.head main\n'
          '# branch.upstream origin/main\n'
          '# branch.ab +2 -1\n'
          '# stash 2\n'
          '1 .M N... 100644 100644 100644 $h $h modified.txt$_nul'
          '1 M. N... 100644 100644 100644 $h $h staged.txt$_nul'
          '1 AM N... 100644 100644 100644 $h $h added-then-edited.txt$_nul'
          '2 R. N... 100644 100644 100644 $h $h R100 new-name.txt$_nul'
          'old-name.txt$_nul'
          'u UU N... 100644 100644 100644 100644 $h $h $h conflicted.txt$_nul'
          '? untracked file.txt$_nul'
          '$_nul'
          'abc1234\tfix the thing\ndef5678\tanother one\n';
      final runner = _FakeRunner([_result(stdout)]);
      final result = await RemoteGit(runner.call).probe('/srv/app');

      expect(result.kind, GitProbeKind.ok);
      final repo = result.status!;
      expect(repo.rootPath, '/srv/app');
      expect(repo.branch, 'main');
      expect(repo.commitId, h);
      expect(repo.upstream, 'origin/main');
      expect(repo.ahead, 2);
      expect(repo.behind, 1);
      expect(repo.stashCount, 2);
      expect(repo.detached, isFalse);

      expect(repo.staged.map((c) => c.path), [
        'staged.txt',
        'added-then-edited.txt',
        'new-name.txt',
      ]);
      expect(repo.unstaged.map((c) => c.path), [
        'modified.txt',
        'added-then-edited.txt',
      ]);
      expect(repo.untracked.single.path, 'untracked file.txt');
      expect(repo.conflicted.single.path, 'conflicted.txt');

      final rename = repo.staged.firstWhere((c) => c.path == 'new-name.txt');
      expect(rename.kind, GitChangeKind.renamed);
      expect(rename.originalPath, 'old-name.txt');

      expect(repo.recentCommits, [
        isA<GitCommitRef>()
            .having((c) => c.id, 'id', 'abc1234')
            .having((c) => c.subject, 'subject', 'fix the thing'),
        isA<GitCommitRef>().having((c) => c.id, 'id', 'def5678'),
      ]);
    });

    test('parses a detached HEAD', () async {
      final stdout =
          '/srv/app\n'
          '# branch.oid deadbeef\n'
          '# branch.head (detached)\n'
          '$_nul'
          'abc1234\twork\n';
      final result = await RemoteGit(
        _FakeRunner([_result(stdout)]).call,
      ).probe('/srv/app');
      expect(result.kind, GitProbeKind.ok);
      expect(result.status!.detached, isTrue);
      expect(result.status!.branch, isNull);
      expect(result.status!.commitId, 'deadbeef');
    });

    test('parses a repository with no commits yet', () async {
      final stdout =
          '/srv/app\n'
          '# branch.oid (initial)\n'
          '# branch.head main\n'
          '? only-file.txt$_nul'
          '$_nul';
      final result = await RemoteGit(
        _FakeRunner([_result(stdout)]).call,
      ).probe('/srv/app');
      expect(result.kind, GitProbeKind.ok);
      expect(result.status!.branch, 'main');
      expect(result.status!.commitId, isNull);
      expect(result.status!.recentCommits, isEmpty);
      expect(result.status!.untracked.single.path, 'only-file.txt');
    });

    test('maps "not a git repository" to its own kind', () async {
      final runner = _FakeRunner([
        _result(
          '',
          stderr:
              'fatal: not a git repository (or any of the parent '
              'directories): .git',
          exitCode: 128,
        ),
      ]);
      final result = await RemoteGit(runner.call).probe('/tmp');
      expect(result.kind, GitProbeKind.notARepository);
      expect(result.status, isNull);
    });

    test('maps a missing git binary to notInstalled', () async {
      final result = await RemoteGit(
        _FakeRunner([
          _result('', stderr: 'sh: git: command not found', exitCode: 127),
        ]).call,
      ).probe('/srv/app');
      expect(result.kind, GitProbeKind.notInstalled);
    });

    test('retries with porcelain v1 when v2 is rejected', () async {
      final runner = _FakeRunner([
        _result(
          '',
          stderr:
              "error: unknown option `porcelain=v2'\n"
              'usage: git status [<options>]',
          exitCode: 129,
        ),
        _result(
          '/srv/app\n'
          '## main...origin/main [ahead 1, behind 2]\n'
          ' M work-in-progress.txt$_nul'
          'A  added.txt$_nul'
          'R  new.txt${_nul}old.txt$_nul'
          '?? fresh.txt$_nul'
          '$_nul'
          'abc1234\tv1 repo\n',
        ),
      ]);
      final result = await RemoteGit(runner.call).probe('/srv/app');

      expect(runner.commands, hasLength(2));
      expect(runner.commands[0], contains('--porcelain=v2'));
      expect(runner.commands[1], contains('--porcelain --branch'));
      expect(runner.commands[1], isNot(contains('=v2')));

      expect(result.kind, GitProbeKind.ok);
      final repo = result.status!;
      expect(repo.branch, 'main');
      expect(repo.upstream, 'origin/main');
      expect(repo.ahead, 1);
      expect(repo.behind, 2);
      expect(repo.unstaged.single.path, 'work-in-progress.txt');
      expect(repo.staged.map((c) => c.path), ['added.txt', 'new.txt']);
      expect(repo.staged.last.originalPath, 'old.txt');
      expect(repo.untracked.single.path, 'fresh.txt');
      expect(repo.recentCommits.single.id, 'abc1234');
    });

    test('v1 parses detached and unborn branch headers', () async {
      // Each fixture needs a usage error first so probe takes the v1 retry.
      final usageError = _result(
        '',
        stderr: 'usage: git status [<options>]',
        exitCode: 129,
      );
      final detached = await RemoteGit(
        _FakeRunner([
          usageError,
          _result('/srv/app\n## HEAD (no branch)\n$_nul\n'),
        ]).call,
      ).probe('/srv/app');
      expect(detached.status!.detached, isTrue);

      final unborn = await RemoteGit(
        _FakeRunner([
          usageError,
          _result('/srv/app\n## No commits yet on trunk\n?? a.txt$_nul$_nul\n'),
        ]).call,
      ).probe('/srv/app');
      expect(unborn.status!.branch, 'trunk');
      expect(unborn.status!.untracked.single.path, 'a.txt');
    });

    test('other failures come back as an error with git\'s own text', () async {
      final result = await RemoteGit(
        _FakeRunner([
          _result(
            '/srv/app\n',
            stderr: 'fatal: detected dubious ownership in repository',
            exitCode: 128,
          ),
        ]).call,
      ).probe('/srv/app');
      expect(result.kind, GitProbeKind.error);
      expect(result.detail, contains('dubious ownership'));
    });
  });

  group('RemoteGit command construction', () {
    test('quotes absolute directories and tilde paths', () async {
      final runner = _FakeRunner([
        _result('/srv/my app\n$_nul\n'),
        _result('/home/u/proj\n$_nul\n'),
        _result('/home/u\n$_nul\n'),
        _result('/tmp\n$_nul\n'),
      ]);
      final git = RemoteGit(runner.call);
      await git.probe('/srv/my app');
      await git.probe('~/proj dir');
      await git.probe('~');
      await git.probe(null);
      expect(runner.commands[0], startsWith("cd -- '/srv/my app' && "));
      expect(runner.commands[1], startsWith("cd -- ~/'proj dir' && "));
      expect(runner.commands[2], startsWith('cd -- ~ && '));
      // A null directory runs in the channel's own cwd.
      expect(runner.commands[3], startsWith('git rev-parse'));
    });

    test('run quotes every argument verbatim', () async {
      final runner = _FakeRunner([_result('[main abc] done\n')]);
      await RemoteGit(
        runner.call,
      ).run("/srv/it's here", ['commit', '-m', "it's done & dusted"]);
      expect(
        runner.commands.single,
        "cd -- '/srv/it'\"'\"'s here' && git 'commit' '-m' "
        "'it'\"'\"'s done & dusted'",
      );
    });

    test('branches lists local heads', () async {
      final runner = _FakeRunner([_result('main\nfeature/x\n')]);
      final branches = await RemoteGit(runner.call).branches('/srv/app');
      expect(branches, ['main', 'feature/x']);
      expect(runner.commands.single, contains('for-each-ref'));
    });

    test('branches is empty when the listing fails', () async {
      final runner = _FakeRunner([
        _result('', stderr: 'fatal: not a git repository', exitCode: 128),
      ]);
      expect(await RemoteGit(runner.call).branches('/tmp'), isEmpty);
    });
  });
}
