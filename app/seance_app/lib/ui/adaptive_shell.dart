import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../main.dart';
import 'chat_sidebar.dart';
import 'server_list_pane.dart';
import 'terminal_pane.dart';

/// The adaptive layout. Above [breakpoint] the server list, terminal, and
/// (when the assistant is configured) the assistant sit side by side as tiled,
/// horizontally-resizable panes. Below it they become screens the user moves
/// between, with the assistant behind an end-drawer.
class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({super.key});

  static const double breakpoint = 720;

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  // Narrow mode only: whether we're currently on the terminal screen.
  bool _viewingTerminal = false;

  // Tiled-pane widths (drag handles adjust these).
  double _listWidth = 300;
  double _assistantWidth = 340;

  static const double _listMin = 200, _listMax = 480;
  static const double _assistantMin = 260, _assistantMax = 680;

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
            width: _listWidth,
            child: ServerListPane(onOpen: (s) => _open(state, s)),
          ),
          _ResizeHandle(
            onDelta: (dx) => setState(
                () => _listWidth = (_listWidth + dx).clamp(_listMin, _listMax)),
          ),
          const Expanded(
            child: TerminalPane(showAppBar: false),
          ),
          if (state.llmConfigured) ...[
            _ResizeHandle(
              onDelta: (dx) => setState(() => _assistantWidth =
                  (_assistantWidth - dx).clamp(_assistantMin, _assistantMax)),
            ),
            SizedBox(width: _assistantWidth, child: const ChatSidebar()),
          ],
        ],
      ),
    );
  }

  Widget _buildNarrow(AppState state) {
    final showTerminal = _viewingTerminal && state.activeServerId != null;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: showTerminal
          ? TerminalPane(
              key: const ValueKey('terminal'),
              showAssistantAffordance: state.llmConfigured,
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

/// A thin, draggable vertical divider that reports horizontal drag deltas so a
/// neighbouring pane can be resized. Shows a resize cursor on desktop.
class _ResizeHandle extends StatelessWidget {
  final ValueChanged<double> onDelta;
  const _ResizeHandle({required this.onDelta});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        child: SizedBox(
          width: 10,
          child: Center(
            child: Container(
              width: 1,
              color: Theme.of(context).dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}
