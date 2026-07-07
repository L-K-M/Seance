import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import 'server_list_pane.dart';
import 'terminal_pane.dart';

/// The requested two-pane / two-screen behaviour. Above the breakpoint, the
/// server list and terminal sit side by side. Below it, they become two screens
/// the user moves back and forward between (the Linux/narrow reading of R3).
class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({super.key});

  static const double breakpoint = 720;

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
            final wide = constraints.maxWidth >= AdaptiveShell.breakpoint;
            return wide ? _buildWide(state) : _buildNarrow(state);
          },
        );
      },
    );
  }

  Widget _buildWide(AppState state) {
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 320,
            child: ServerListPane(onOpen: (s) => _open(state, s)),
          ),
          const VerticalDivider(width: 1),
          const Expanded(child: TerminalPane()),
        ],
      ),
    );
  }

  Widget _buildNarrow(AppState state) {
    final showTerminal = _viewingTerminal && state.activeTab != null;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: showTerminal
          ? TerminalPane(
              key: const ValueKey('terminal'),
              onBack: () => setState(() => _viewingTerminal = false),
            )
          : ServerListPane(
              key: const ValueKey('list'),
              onOpen: (s) => _open(state, s),
            ),
    );
  }

  Future<void> _open(AppState state, ServerConfig server) async {
    await state.openTerminal(server);
    if (mounted) setState(() => _viewingTerminal = true);
  }
}
