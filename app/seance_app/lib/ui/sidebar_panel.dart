import 'package:flutter/material.dart';

import '../main.dart';
import 'app_menus.dart';
import 'chat_sidebar.dart';
import 'files_pane.dart';
import 'snippets_pane.dart';

/// The right-hand utility panel: an Assistant tab (the LLM chat, when a provider
/// is configured) and a Snippets tab (always available). Used both as a tiled
/// pane on wide layouts and inside the end-drawer on narrow ones.
class SidebarPanel extends StatefulWidget {
  final bool includeFiles;

  const SidebarPanel({super.key, this.includeFiles = true});

  @override
  State<SidebarPanel> createState() => _SidebarPanelState();
}

class _SidebarPanelState extends State<SidebarPanel>
    with SingleTickerProviderStateMixin {
  TabController? _tabs;
  bool _filesVisited = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_tabs != null) return;
    final state = AppScope.of(context);
    _tabs = TabController(
      length: widget.includeFiles ? 3 : 2,
      initialIndex: state.llmConfigured ? 0 : 1,
      vsync: this,
    )..addListener(_tabChanged);
  }

  void _tabChanged() {
    if (widget.includeFiles && _tabs?.index == 2 && !_filesVisited) {
      setState(() => _filesVisited = true);
    }
  }

  @override
  void dispose() {
    _tabs?.removeListener(_tabChanged);
    _tabs?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return SafeArea(
          child: Column(
            children: [
              TabBar(
                controller: _tabs,
                tabs: [
                  const Tab(text: 'Assistant'),
                  const Tab(text: 'Snippets'),
                  if (widget.includeFiles) const Tab(text: 'Files'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    state.llmConfigured
                        ? const ChatSidebar()
                        : const _AssistantSetupPrompt(),
                    const SnippetsPane(),
                    if (widget.includeFiles)
                      _filesVisited
                          ? const FilesPane()
                          : const SizedBox.shrink(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AssistantSetupPrompt extends StatelessWidget {
  const _AssistantSetupPrompt();

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
            Text('Assistant not set up',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Add an LLM provider (Anthropic, or a local OpenAI-compatible '
              'endpoint) to chat about your session and turn plain language '
              'into commands.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: openSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}
