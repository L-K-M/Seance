import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../services/terminal_search.dart';
import '../theme.dart';

/// How far down the terminal the find bar reaches, card and margin: a hit
/// under it is not in view, so revealing one scrolls it out from behind.
const double _findBarReach = 52;

/// The terminal's find bar: a compact card floated over the top-right corner
/// of the terminal, so opening it neither covers the prompt at the bottom nor
/// resizes the grid (and with it the remote PTY).
///
/// It mirrors the editor's find bar — the same field, counter and buttons —
/// so the two feel like one feature. Enter and Shift+Enter, ⌘G and ⇧⌘G, or
/// F3 and Shift+F3 step through hits; Escape closes.
class TerminalFindBar extends StatefulWidget {
  const TerminalFindBar({
    super.key,
    required this.session,
    required this.onClose,
  });

  final TerminalSearchSession session;
  final VoidCallback onClose;

  @override
  State<TerminalFindBar> createState() => TerminalFindBarState();
}

class TerminalFindBarState extends State<TerminalFindBar> {
  late final TextEditingController _query =
      TextEditingController(text: widget.session.query)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.session.query.length,
        );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Not `autofocus`: that only claims focus when nothing else in the scope
    // has it, and the terminal does.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Focuses the query with its text selected, for the find shortcut while
  /// the bar is already open: type to replace, or press Enter to go on.
  void focusQuery() {
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
    _focus.requestFocus();
  }

  String _counter(TerminalSearchSession session) {
    if (session.query.isEmpty) return '';
    final current = session.currentIndex;
    if (current == null) return 'No matches';
    return '${current + 1} of ${session.hitCount}${session.capped ? '+' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final session = widget.session;
    final radius = BorderRadius.circular(SeanceChrome.of(context).corner(8));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
            session.next,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true, shift: true):
            session.previous,
        const SingleActivator(LogicalKeyboardKey.f3): session.next,
        const SingleActivator(LogicalKeyboardKey.f3, shift: true):
            session.previous,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): focusQuery,
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          shift: true,
        ): focusQuery,
      },
      child: Material(
        color: scheme.surfaceContainerHigh,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 2),
          child: ListenableBuilder(
            listenable: session,
            builder: (context, _) {
              final counter = _counter(session);
              final noHits = session.hitCount == 0;
              return Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      focusNode: _focus,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: theme.textTheme.bodyMedium,
                      decoration: const InputDecoration(
                        hintText: 'Find in terminal',
                        isDense: true,
                        border: InputBorder.none,
                      ),
                      onChanged: session.search,
                      onSubmitted: (_) {
                        if (HardwareKeyboard.instance.isShiftPressed) {
                          session.previous();
                        } else {
                          session.next();
                        }
                        _focus.requestFocus();
                      },
                    ),
                  ),
                  // Keep focus in the query: the buttons act without taking it.
                  ExcludeFocus(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (counter.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                counter,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: 'Match case',
                          isSelected: session.caseSensitive,
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              session.caseSensitive = !session.caseSensitive,
                          icon: Text(
                            'Aa',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: session.caseSensitive
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Previous match',
                          visualDensity: VisualDensity.compact,
                          onPressed: noHits ? null : session.previous,
                          icon: const Icon(Icons.keyboard_arrow_up),
                        ),
                        IconButton(
                          tooltip: 'Next match',
                          visualDensity: VisualDensity.compact,
                          onPressed: noHits ? null : session.next,
                          icon: const Icon(Icons.keyboard_arrow_down),
                        ),
                        IconButton(
                          tooltip: 'Close search',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onClose,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Places [TerminalFindBar] over the top-right of the terminal area.
class TerminalFindBarOverlay extends StatelessWidget {
  const TerminalFindBarOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned(
    top: 8,
    left: 8,
    right: 8,
    child: Align(
      alignment: Alignment.topRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: child,
      ),
    ),
  );
}

/// [TerminalSearchViewport] over a [TerminalView]: its scroll position and
/// line height.
class TerminalViewSearchViewport implements TerminalSearchViewport {
  TerminalViewSearchViewport(this._view, this._scroll);

  final GlobalKey<TerminalViewState> _view;
  final ScrollController _scroll;

  double? get _lineHeight {
    final view = _view.currentState;
    if (view == null || !_scroll.hasClients) return null;
    return view.renderTerminal.lineHeight;
  }

  @override
  ({int first, int last})? get visibleRows {
    final lineHeight = _lineHeight;
    if (lineHeight == null || lineHeight <= 0) return null;
    final position = _scroll.position;
    return (
      first: ((position.pixels + _findBarReach) / lineHeight).ceil(),
      last:
          ((position.pixels + position.viewportDimension) / lineHeight)
              .floor() -
          1,
    );
  }

  @override
  void centerRow(int row) {
    final lineHeight = _lineHeight;
    if (lineHeight == null) return;
    final position = _scroll.position;
    final target =
        row * lineHeight - (position.viewportDimension - lineHeight) / 2;
    _scroll.jumpTo(
      math.min(
        math.max(target, position.minScrollExtent),
        position.maxScrollExtent,
      ),
    );
  }
}
