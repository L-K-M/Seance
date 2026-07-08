import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import 'chat_sidebar.dart';
import 'server_list_pane.dart';
import 'terminal_pane.dart';

/// The adaptive layout. Above [breakpoint] the server list and terminal sit
/// side by side; below it they become two screens the user moves between.
///
/// When the assistant is configured and there is room ([assistantBreakpoint]),
/// it is shown as a third, tiled pane on the right — never overlapping the
/// terminal. On narrower windows it stays reachable behind an end-drawer.
class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({super.key});

  static const double breakpoint = 720;
  static const double assistantBreakpoint = 1080;

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  // Narrow mode only: whether we're currently on the terminal screen.
  bool _viewingTerminal = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final wide = width >= AdaptiveShell.breakpoint;
            final tileAssistant = state.llmConfigured &&
                width >= AdaptiveShell.assistantBreakpoint;
            // When the assistant isn't tiled but is configured, reach it via
            // the terminal's end-drawer.
            final assistantDrawer = state.llmConfigured && !tileAssistant;
            return wide
                ? _buildWide(state, tileAssistant, assistantDrawer)
                : _buildNarrow(state, assistantDrawer);
          },
        );
      },
    );
  }

  Widget _buildWide(
      AppState state, bool tileAssistant, bool assistantDrawer) {
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 320,
            child: ServerListPane(onOpen: (s) => _open(state, s)),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: TerminalPane(showAssistantAffordance: assistantDrawer),
          ),
          if (tileAssistant) ...[
            const VerticalDivider(width: 1),
            const SizedBox(width: 360, child: ChatSidebar()),
          ],
        ],
      ),
    );
  }

  Widget _buildNarrow(AppState state, bool assistantDrawer) {
    final showTerminal = _viewingTerminal && state.activeServerId != null;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: showTerminal
          ? TerminalPane(
              key: const ValueKey('terminal'),
              showAssistantAffordance: assistantDrawer,
              onBack: () => setState(() => _viewingTerminal = false),
            )
          : ServerListPane(
              key: const ValueKey('list'),
              onOpen: (s) => _open(state, s),
            ),
    );
  }

  Future<void> _open(AppState state, ServerConfig server) async {
    if (mounted) setState(() => _viewingTerminal = true);
    await state.openTerminal(server);
  }
}
