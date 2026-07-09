import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';

/// The always-available assistant. It sees the active session's recent output
/// (redacted) by default, can search the web, and can place a command in the
/// prompt for review — it never runs anything itself.
class ChatSidebar extends StatefulWidget {
  const ChatSidebar({super.key});

  @override
  State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatMessage {
  final bool fromUser;
  final String text;
  final List<String> staged; // commands placed in the prompt
  final List<String> searches;
  _ChatMessage(
    this.fromUser,
    this.text, {
    this.staged = const [],
    this.searches = const [],
  });
}

class _ChatSidebarState extends State<ChatSidebar> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatMessage> _messages = [];
  ChatController? _chat;
  int? _chatVersion; // the llmConfigVersion _chat was built with
  TerminalSession? _pasteTarget;
  bool _includeContext = true;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<ChatController> _ensureController(AppState state) async {
    final existing = _chat;
    // Rebuild if the provider settings changed since we last built (new key,
    // model, or base URL) — otherwise edits in Settings wouldn't take effect.
    if (existing != null && _chatVersion == state.llmConfigVersion) {
      return existing;
    }
    final provider = await state.services.buildLlmProvider();
    final search = await state.services.buildSearchProvider();
    final controller = ChatController(
      provider: provider,
      searchProvider: search,
      // Honor the "Redact secrets before sending" toggle (default on).
      redactor:
          SecretRedactor(enabled: state.services.settings.redactionEnabled),
      onPaste: (command) {
        // Place the (newline-free) command into the session that originated the
        // current chat turn, not whichever tab happens to be active later.
        final session = _pasteTarget;
        if (session == null ||
            state.sessions[session.serverId] != session ||
            !session.isConnected) {
          return;
        }
        session.engine.injectInput(command);
      },
    );
    _chat = controller;
    _chatVersion = state.llmConfigVersion;
    return controller;
  }

  Future<void> _send(AppState state) async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _messages.add(_ChatMessage(true, text));
      _sending = true;
      _error = null;
      _input.clear();
    });
    _scrollToEnd();

    try {
      final targetSession = state.activeSession;
      _pasteTarget = targetSession;
      final controller = await _ensureController(state);
      final context = _includeContext
          ? targetSession?.engine.recentText(maxLines: 200)
          : null;
      final result = await controller.send(text, terminalContext: context);
      setState(() {
        _messages.add(
          _ChatMessage(
            false,
            result.reply,
            staged: result.stagedCommands,
            searches: result.searchQueries,
          ),
        );
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      _pasteTarget = null;
      setState(() => _sending = false);
      _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return SafeArea(
      child: Column(
        children: [
          _header(context),
          const Divider(height: 1),
          Expanded(
            child: _messages.isEmpty
                ? const _ChatEmpty()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) => _bubble(context, _messages[i]),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          _composer(context, state),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome_outlined, size: 20),
          const SizedBox(width: 8),
          Text('Assistant', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {
              _messages.clear();
              _chat?.reset();
            }),
          ),
        ],
      ),
    );
  }

  Widget _composer(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilterChip(
            selected: _includeContext,
            label: const Text('Include terminal output'),
            avatar: const Icon(Icons.article_outlined, size: 16),
            onSelected: (v) => setState(() => _includeContext = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                // Enter inserts a newline (multiline); Cmd/Ctrl+Return sends.
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      meta: true,
                    ): () =>
                        _send(state),
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): () =>
                        _send(state),
                  },
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Describe a task, or ask a question…',
                      helperText: '⌘/Ctrl + ↵ to send',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(state),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _sending ? null : () => _send(state),
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, _ChatMessage m) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: m.fromUser
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(m.text),
            for (final q in m.searches)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.search, size: 14),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'searched: $q',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
            for (final cmd in m.staged) _StagedCommand(command: cmd),
          ],
        ),
      ),
    );
  }
}

/// A command the assistant placed in the prompt, with an independent danger-
/// linter check surfaced inline — the chat path used to stage commands without
/// any warning, unlike the command generator.
class _StagedCommand extends StatelessWidget {
  final String command;
  const _StagedCommand({required this.command});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final danger = DangerLinter.worst(command);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: danger == DangerSeverity.critical
            ? Border.all(color: scheme.error)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.keyboard_return, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'placed in prompt: $command',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
          if (danger != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 14, color: scheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      danger == DangerSeverity.critical
                          ? 'Critical — review carefully before running'
                          : 'Review before running',
                      style: TextStyle(fontSize: 11, color: scheme.error),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ChatEmpty extends StatelessWidget {
  const _ChatEmpty();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome_outlined, size: 36),
            const SizedBox(height: 12),
            Text(
              'Describe what you want to do',
              style: Theme.of(context).textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Type a task in plain language — e.g. "find the 10 largest files '
              'under /var" — and I\'ll draft the command and place it in your '
              'terminal for you to review and run. I can also search the web. '
              'I never run anything myself.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
