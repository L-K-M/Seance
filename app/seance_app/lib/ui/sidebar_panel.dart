import 'package:flutter/material.dart';

import '../main.dart';
import 'app_menus.dart';
import 'chat_sidebar.dart';
import 'snippets_pane.dart';

/// The right-hand utility panel: an Assistant tab (the LLM chat, when a provider
/// is configured) and a Snippets tab (always available). Used both as a tiled
/// pane on wide layouts and inside the end-drawer on narrow ones.
class SidebarPanel extends StatelessWidget {
  const SidebarPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return DefaultTabController(
          length: 2,
          // Land on Snippets if the assistant isn't set up yet.
          initialIndex: state.llmConfigured ? 0 : 1,
          child: SafeArea(
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Assistant'),
                    Tab(text: 'Snippets'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      state.llmConfigured
                          ? const ChatSidebar()
                          : const _AssistantSetupPrompt(),
                      const SnippetsPane(),
                    ],
                  ),
                ),
              ],
            ),
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
