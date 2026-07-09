import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../services/xterm_engine.dart';

/// A compact, horizontally-scrollable row of keys the soft keyboard lacks —
/// Esc, Tab, Ctrl, arrows, Home/End/PgUp/PgDn and a few shell punctuation
/// characters — shown above the keyboard on touch platforms.
///
/// Every button sends bytes straight to the session, so nothing here can be
/// mistaken for typed text. `Ctrl` is a one-shot modifier: tap it (it lights
/// up), then a letter on the soft keyboard, to send e.g. Ctrl-C. A dedicated
/// `^C` button is provided too because interrupting is the common case.
class TerminalKeyboardBar extends StatelessWidget {
  final XtermTerminalEngine engine;
  const TerminalKeyboardBar({super.key, required this.engine});

  static const List<int> _esc = [0x1b];
  static const List<int> _tab = [0x09];
  static const List<int> _ctrlC = [0x03];
  static const List<int> _pgUp = [0x1b, 0x5b, 0x35, 0x7e];
  static const List<int> _pgDn = [0x1b, 0x5b, 0x36, 0x7e];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        // Keep the soft keyboard open: without this, tapping a key would move
        // focus off the terminal's hidden input and dismiss the keyboard.
        child: ExcludeFocus(
          child: SizedBox(
            height: 46,
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    children: [
                      _label(context, 'esc', _esc, 'Escape'),
                      _label(context, 'tab', _tab, 'Tab'),
                      _ctrlKey(context),
                      _label(context, '^C', _ctrlC, 'Control C'),
                      _icon(
                        context,
                        Icons.keyboard_arrow_left,
                        TerminalKey.arrowLeft,
                        'Left arrow',
                      ),
                      _icon(
                        context,
                        Icons.keyboard_arrow_up,
                        TerminalKey.arrowUp,
                        'Up arrow',
                      ),
                      _icon(
                        context,
                        Icons.keyboard_arrow_down,
                        TerminalKey.arrowDown,
                        'Down arrow',
                      ),
                      _icon(
                        context,
                        Icons.keyboard_arrow_right,
                        TerminalKey.arrowRight,
                        'Right arrow',
                      ),
                      _terminalKey(context, 'home', TerminalKey.home, 'Home'),
                      _terminalKey(context, 'end', TerminalKey.end, 'End'),
                      _label(context, 'pgup', _pgUp, 'Page up'),
                      _label(context, 'pgdn', _pgDn, 'Page down'),
                      _char(context, '|', 'Pipe'),
                      _char(context, '/', 'Slash'),
                      _char(context, '-', 'Hyphen'),
                      _char(context, '~', 'Tilde'),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                _KeyButton(
                  onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                  semanticLabel: 'Hide keyboard',
                  tooltip: 'Hide keyboard',
                  child: const Icon(Icons.keyboard_hide_outlined, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(
    BuildContext context,
    String text,
    List<int> bytes,
    String semanticLabel,
  ) => _KeyButton(
    onTap: () => engine.sendKey(bytes),
    semanticLabel: semanticLabel,
    child: Text(
      text,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    ),
  );

  Widget _icon(
    BuildContext context,
    IconData icon,
    TerminalKey key,
    String semanticLabel,
  ) => _KeyButton(
    onTap: () => engine.sendTerminalKey(key),
    semanticLabel: semanticLabel,
    tooltip: semanticLabel,
    child: Icon(icon, size: 20),
  );

  Widget _terminalKey(
    BuildContext context,
    String text,
    TerminalKey key,
    String semanticLabel,
  ) => _KeyButton(
    onTap: () => engine.sendTerminalKey(key),
    semanticLabel: semanticLabel,
    child: Text(
      text,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    ),
  );

  Widget _char(BuildContext context, String ch, String semanticLabel) =>
      _KeyButton(
        onTap: () => engine.sendKey(utf8.encode(ch)),
        semanticLabel: semanticLabel,
        child: Text(
          ch,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
        ),
      );

  /// The sticky Ctrl modifier, highlighted while armed.
  Widget _ctrlKey(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: engine.ctrlArmed,
      builder: (context, armed, _) => _KeyButton(
        onTap: engine.toggleCtrl,
        semanticLabel: 'Control modifier',
        toggled: armed,
        background: armed ? scheme.primary : null,
        child: Text(
          'ctrl',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            fontWeight: armed ? FontWeight.bold : FontWeight.normal,
            color: armed ? scheme.onPrimary : null,
          ),
        ),
      ),
    );
  }
}

/// One key cap: a small, tappable rounded rectangle.
class _KeyButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final String semanticLabel;
  final String? tooltip;
  final bool? toggled;
  final Color? background;
  const _KeyButton({
    required this.child,
    required this.onTap,
    required this.semanticLabel,
    this.tooltip,
    this.toggled,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget keyCap = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: background ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: child,
          ),
        ),
      ),
    );
    if (tooltip != null) {
      keyCap = Tooltip(
        message: tooltip!,
        excludeFromSemantics: true,
        child: keyCap,
      );
    }
    return Semantics(
      button: true,
      label: semanticLabel,
      toggled: toggled,
      onTap: onTap,
      excludeSemantics: true,
      child: keyCap,
    );
  }
}
