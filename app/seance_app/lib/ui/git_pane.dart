import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import '../services/remote_git_controller.dart';
import '../services/xterm_engine.dart';
import 'middle_ellipsis_text.dart';
import 'top_toast.dart';

/// The Git tab: the repository state of the directory the remote shell is
/// sitting in, plus the common actions on it. Everything runs on a separate
/// SSH exec channel — the terminal is never typed into — and the pane follows
/// the shell's reported directory (OSC 7, or the conventional Bash title).
class GitPane extends StatelessWidget {
  const GitPane({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final session = state.activeSession;
        if (session == null) {
          return const _GitUnavailable(
            icon: Icons.account_tree_outlined,
            message: 'Open a terminal session to inspect its repository.',
          );
        }
        final git = session.git;
        if (!session.isConnected || git == null) {
          return const _GitUnavailable(
            icon: Icons.link_off,
            message: 'Reconnect this session to use git here.',
          );
        }
        return _GitView(
          key: ValueKey(session.id),
          session: session,
          controller: git,
        );
      },
    );
  }
}

class _GitView extends StatefulWidget {
  final TerminalSession session;
  final RemoteGitController controller;

  const _GitView({super.key, required this.session, required this.controller});

  @override
  State<_GitView> createState() => _GitViewState();
}

class _GitViewState extends State<_GitView> {
  final TextEditingController _commitMessage = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(covariant _GitView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reconnect swaps in a fresh controller under the same session key —
    // this State survives, so the new one needs its first probe here.
    if (oldWidget.controller != widget.controller) {
      unawaited(widget.controller.initialize());
    }
  }

  @override
  void dispose() {
    _commitMessage.dispose();
    super.dispose();
  }

  /// Run one controller action. Success surfaces a toast when the command
  /// said anything worth repeating ("Already up to date.", the commit line);
  /// failure is carried by the pane's own error banner.
  Future<void> _run(
    Future<RemoteCommandResult?> Function() action, {
    String? successMessage,
  }) async {
    final result = await action();
    if (!mounted || result == null) return;
    final said = result.stdout.trim().isNotEmpty
        ? result.stdout.trim()
        : result.stderr.trim();
    final message = successMessage ?? (said.isNotEmpty ? said : null);
    if (message != null) {
      showTopToastIn(context, message: message.split('\n').first);
    }
  }

  Future<void> _discard(GitFileStatus change) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Discard changes to ${remoteBasename(change.path)}?'),
        content: Text(
          'The working-tree changes to ${change.path} are lost. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(() => widget.controller.discardFile(change.path));
    }
  }

  Future<void> _commit() async {
    final message = _commitMessage.text.trim();
    if (message.isEmpty) return;
    final result = await widget.controller.commit(message);
    if (result != null && mounted) {
      _commitMessage.clear();
      setState(() {});
    }
  }

  Future<void> _switchBranch() async {
    final controller = widget.controller;
    final branches = await controller.branches();
    if (!mounted) return;
    if (branches == null) {
      showTopToastIn(context, message: 'Could not list branches.');
      return;
    }
    final current = controller.repo?.branch;
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Switch branch'),
        children: [
          for (final branch in branches)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, branch),
              child: Row(
                children: [
                  Icon(
                    branch == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(branch, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          if (branches.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No local branches found.'),
            ),
        ],
      ),
    );
    if (selected == null || selected == current) return;
    await _run(() => controller.checkoutBranch(selected));
  }

  Future<void> _newBranch() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _BranchNameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;
    await _run(() => widget.controller.createBranch(name.trim()));
  }

  void _terminalToRepoRoot() {
    final controller = widget.controller;
    final root = controller.repo?.rootPath ?? controller.directory;
    if (root == null) return;
    final result = widget.session.engine.stageChangeDirectory(root);
    final message = switch (result) {
      TerminalStageResult.staged =>
        'cd staged at the prompt — press Enter to run it',
      TerminalStageResult.pendingInput =>
        'The prompt has input; clear it first',
      TerminalStageResult.promptNotReady =>
        'The terminal is busy — wait for the prompt',
      TerminalStageResult.shellIntegrationRequired =>
        'Needs OSC 133 shell integration on the remote shell',
      TerminalStageResult.invalidPath => 'The reported path is not usable',
    };
    showTopToastIn(context, message: message);
  }

  void _onMenu(String value) {
    final controller = widget.controller;
    switch (value) {
      case 'fetch':
        _run(controller.fetch);
      case 'pull':
        _run(controller.pull);
      case 'push':
        _run(controller.push);
      case 'stage_all':
        _run(controller.stageAll);
      case 'unstage_all':
        _run(controller.unstageAll);
      case 'switch':
        _switchBranch();
      case 'new_branch':
        _newBranch();
      case 'stash':
        _run(controller.stashPush);
      case 'stash_pop':
        _run(controller.stashPop);
      case 'terminal_root':
        _terminalToRepoRoot();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final repo = controller.repo;
        final inRepo = repo != null;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.account_tree_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Git',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (controller.busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Refresh',
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh),
                    onPressed: controller.busy ? null : controller.refresh,
                  ),
                  PopupMenuButton<String>(
                    iconSize: 20,
                    tooltip: 'Git actions',
                    onSelected: _onMenu,
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'fetch', child: Text('Fetch')),
                      const PopupMenuItem(value: 'pull', child: Text('Pull')),
                      const PopupMenuItem(value: 'push', child: Text('Push')),
                      if (inRepo) ...[
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'stage_all',
                          child: Text('Stage all changes'),
                        ),
                        const PopupMenuItem(
                          value: 'unstage_all',
                          child: Text('Unstage all'),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'switch',
                          child: Text('Switch branch…'),
                        ),
                        const PopupMenuItem(
                          value: 'new_branch',
                          child: Text('New branch…'),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'stash',
                          child: Text('Stash changes'),
                        ),
                        const PopupMenuItem(
                          value: 'stash_pop',
                          child: Text('Pop stash'),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'terminal_root',
                          child: Text('Take terminal to repo root'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (controller.loading) const LinearProgressIndicator(minHeight: 2),
            if (controller.actionError != null)
              MaterialBanner(
                leading: const Icon(Icons.error_outline),
                content: Text(
                  controller.actionError!,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [
                  TextButton(
                    onPressed: controller.dismissActionError,
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(child: _body(controller)),
            if (inRepo)
              _CommitComposer(
                controller: controller,
                message: _commitMessage,
                onChanged: () => setState(() {}),
                onCommit: _commit,
              ),
          ],
        );
      },
    );
  }

  Widget _body(RemoteGitController controller) {
    if (controller.reportedDirectory == null && controller.directory == null) {
      return const _GitUnavailable(
        icon: Icons.terminal,
        message:
            'Waiting for the remote shell to report its directory. '
            'OSC 7 shell integration makes this automatic — see '
            'docs/SHELL_INTEGRATION.md.',
      );
    }
    if (controller.error != null) {
      return _GitRetryable(
        icon: Icons.error_outline,
        message: controller.error!,
        onRetry: controller.refresh,
      );
    }
    final result = controller.result;
    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }
    switch (result.kind) {
      case GitProbeKind.notInstalled:
        return const _GitUnavailable(
          icon: Icons.cloud_off_outlined,
          message: 'git is not installed on this host.',
        );
      case GitProbeKind.notARepository:
        return _NotARepository(
          directory: controller.directory ?? controller.reportedDirectory!,
          busy: controller.busy,
          onInit: () => _run(
            controller.initRepository,
            successMessage: 'Repository initialized',
          ),
        );
      case GitProbeKind.error:
        return _GitRetryable(
          icon: Icons.error_outline,
          message: result.detail ?? 'git failed.',
          onRetry: controller.refresh,
        );
      case GitProbeKind.ok:
        return _RepoView(
          repo: result.status!,
          directory: controller.directory!,
          busy: controller.busy,
          onStage: (change) => _run(() => controller.stageFile(change.path)),
          onUnstage: (change) =>
              _run(() => controller.unstageFile(change.path)),
          onDiscard: _discard,
          onOpenTerminal: _terminalToRepoRoot,
        );
    }
  }
}

class _RepoView extends StatelessWidget {
  final GitRepoStatus repo;
  final String directory;
  final bool busy;
  final void Function(GitFileStatus) onStage;
  final void Function(GitFileStatus) onUnstage;
  final void Function(GitFileStatus) onDiscard;
  final VoidCallback onOpenTerminal;

  const _RepoView({
    required this.repo,
    required this.directory,
    required this.busy,
    required this.onStage,
    required this.onUnstage,
    required this.onDiscard,
    required this.onOpenTerminal,
  });

  @override
  Widget build(BuildContext context) {
    final clean = repo.changes.isEmpty;
    return ListView(
      children: [
        _RepoHeader(
          repo: repo,
          directory: directory,
          onOpenTerminal: onOpenTerminal,
        ),
        const Divider(height: 1),
        if (clean)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Column(
              children: [
                Icon(Icons.check_circle_outline, size: 32),
                SizedBox(height: 8),
                Text('Working tree clean'),
              ],
            ),
          ),
        if (repo.conflicted.isNotEmpty) ...[
          _SectionHeader(
            'Conflicts',
            repo.conflicted.length,
            color: Theme.of(context).colorScheme.error,
          ),
          for (final change in repo.conflicted)
            _ChangeRow(change: change, letter: 'U'),
        ],
        if (repo.staged.isNotEmpty) ...[
          _SectionHeader('Staged changes', repo.staged.length),
          for (final change in repo.staged)
            _ChangeRow(
              change: change,
              letter: change.stagedLetter,
              action: _RowAction(
                tooltip: 'Unstage',
                icon: Icons.remove_circle_outline,
                onPressed: busy ? null : () => onUnstage(change),
              ),
            ),
        ],
        if (repo.unstaged.isNotEmpty) ...[
          _SectionHeader('Changes', repo.unstaged.length),
          for (final change in repo.unstaged)
            _ChangeRow(
              change: change,
              letter: change.unstagedLetter,
              action: _RowAction(
                tooltip: 'Stage',
                icon: Icons.add_circle_outline,
                onPressed: busy ? null : () => onStage(change),
              ),
              menuAction: _RowAction(
                tooltip: 'Discard changes',
                icon: Icons.undo,
                onPressed: busy ? null : () => onDiscard(change),
              ),
            ),
        ],
        if (repo.untracked.isNotEmpty) ...[
          _SectionHeader('Untracked', repo.untracked.length),
          for (final change in repo.untracked)
            _ChangeRow(
              change: change,
              letter: '?',
              action: _RowAction(
                tooltip: 'Stage',
                icon: Icons.add_circle_outline,
                onPressed: busy ? null : () => onStage(change),
              ),
            ),
        ],
        if (repo.recentCommits.isNotEmpty) ...[
          const Divider(height: 24),
          const _SectionHeader('Recent commits', 0),
          for (final commit in repo.recentCommits) _CommitRow(commit: commit),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

/// A commit id shortened for display, clamped so an already-short id can't
/// throw a RangeError.
String _shortId(String? id) =>
    id == null ? '?' : id.substring(0, id.length < 7 ? id.length : 7);

class _RepoHeader extends StatelessWidget {
  final GitRepoStatus repo;
  final String directory;
  final VoidCallback onOpenTerminal;

  const _RepoHeader({
    required this.repo,
    required this.directory,
    required this.onOpenTerminal,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final root = repo.rootPath;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.folder_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: MiddleEllipsisText(
                  root ?? directory,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Take terminal to repo root',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.terminal),
                onPressed: root == null ? null : onOpenTerminal,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 16,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  repo.branch ?? 'detached @ ${_shortId(repo.commitId)}',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (repo.upstream != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    repo.upstream!,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              if (repo.ahead > 0)
                _CountChip('↑${repo.ahead}', 'ahead of upstream'),
              if (repo.behind > 0)
                _CountChip('↓${repo.behind}', 'behind upstream'),
              if ((repo.stashCount ?? 0) > 0)
                _CountChip('stash ×${repo.stashCount}', 'stashed changes'),
            ],
          ),
        ],
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  final String label;
  final String tooltip;
  const _CountChip(this.label, this.tooltip);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: Tooltip(
      message: tooltip,
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color? color;
  const _SectionHeader(this.title, this.count, {this.color});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
    child: Text(
      count > 0 ? '$title ($count)' : title,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
    ),
  );
}

class _RowAction {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  const _RowAction({required this.tooltip, required this.icon, this.onPressed});
}

class _ChangeRow extends StatelessWidget {
  final GitFileStatus change;
  final String letter;
  final _RowAction? action;
  final _RowAction? menuAction;

  const _ChangeRow({
    required this.change,
    required this.letter,
    this.action,
    this.menuAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (letter) {
      'A' || 'C' => scheme.primary,
      'M' => scheme.tertiary,
      'D' || 'U' => scheme.error,
      'R' => scheme.secondary,
      _ => scheme.outline,
    };
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: SizedBox(
        width: 20,
        child: Text(
          letter,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
      title: MiddleEllipsisText(
        change.path,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
      subtitle: change.originalPath == null
          ? null
          : Text(
              'from ${change.originalPath}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: action == null && menuAction == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (action != null)
                  IconButton(
                    tooltip: action!.tooltip,
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(action!.icon),
                    onPressed: action!.onPressed,
                  ),
                if (menuAction != null)
                  IconButton(
                    tooltip: menuAction!.tooltip,
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(menuAction!.icon),
                    onPressed: menuAction!.onPressed,
                  ),
              ],
            ),
    );
  }
}

class _CommitRow extends StatelessWidget {
  final GitCommitRef commit;
  const _CommitRow({required this.commit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.only(left: 16, right: 12),
      leading: SizedBox(
        width: 64,
        child: Text(
          commit.id,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      title: Text(
        commit.subject,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      onTap: () {
        Clipboard.setData(ClipboardData(text: commit.id));
        showTopToastIn(context, message: 'Copied ${commit.id}');
      },
    );
  }
}

class _CommitComposer extends StatelessWidget {
  final RemoteGitController controller;
  final TextEditingController message;
  final VoidCallback onChanged;
  final VoidCallback onCommit;

  const _CommitComposer({
    required this.controller,
    required this.message,
    required this.onChanged,
    required this.onCommit,
  });

  @override
  Widget build(BuildContext context) {
    final staged = controller.repo?.staged.length ?? 0;
    final canCommit =
        staged > 0 && message.text.trim().isNotEmpty && !controller.busy;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: message,
                onChanged: (_) => onChanged(),
                onSubmitted: (_) {
                  if (canCommit) onCommit();
                },
                enabled: !controller.busy,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: staged > 0
                      ? 'Commit $staged staged ${staged == 1 ? 'change' : 'changes'}'
                      : 'Stage changes to commit',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: canCommit ? onCommit : null,
              child: const Text('Commit'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchNameDialog extends StatefulWidget {
  const _BranchNameDialog();

  @override
  State<_BranchNameDialog> createState() => _BranchNameDialogState();
}

class _BranchNameDialogState extends State<_BranchNameDialog> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  // Stray spaces are never legal in a ref, and an autofocused field's
  // accidental Enter must not submit an empty name.
  void _submit(String value) {
    final name = value.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New branch'),
    content: SizedBox(
      width: 380,
      child: TextField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Branch name',
          hintText: 'e.g. fix/login-redirect',
          border: OutlineInputBorder(),
        ),
        onSubmitted: _submit,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => _submit(_name.text),
        child: const Text('Create and switch'),
      ),
    ],
  );
}

class _NotARepository extends StatelessWidget {
  final String directory;
  final bool busy;
  final VoidCallback onInit;

  const _NotARepository({
    required this.directory,
    required this.busy,
    required this.onInit,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.account_tree_outlined, size: 38),
          const SizedBox(height: 10),
          const Text('Not a git repository'),
          const SizedBox(height: 4),
          Text(
            directory,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: busy ? null : onInit,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Initialize repository'),
          ),
        ],
      ),
    ),
  );
}

class _GitUnavailable extends StatelessWidget {
  final IconData icon;
  final String message;

  const _GitUnavailable({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 38),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _GitRetryable extends StatelessWidget {
  final IconData icon;
  final String message;
  final VoidCallback onRetry;

  const _GitRetryable({
    required this.icon,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 38),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}
