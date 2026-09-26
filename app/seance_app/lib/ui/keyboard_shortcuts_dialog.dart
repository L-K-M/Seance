import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_menus.dart';

/// One line of the shortcut list: what it does, and the keys on this
/// platform ("⌘W", "Ctrl+Tab or Ctrl+Page Down").
typedef ShortcutRow = ({String action, String keys});

typedef ShortcutSection = ({String title, List<ShortcutRow> rows});

/// The shortcut list as [platform] has it. The tab rows are read from
/// [tabShortcuts], the table the key handlers use, so they cannot disagree.
/// The terminal's own chords are implemented inline in its key handler
/// (`_SessionViewState._handleKeyEvent` in terminal_pane.dart): ⌘ on Apple
/// platforms, Ctrl+Shift elsewhere, where plain Ctrl belongs to the shell.
@visibleForTesting
List<ShortcutSection> keyboardShortcutSections(TargetPlatform platform) {
  final apple =
      platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  String keys(SingleActivator chord) => _describe(chord, apple: apple);
  String terminal(LogicalKeyboardKey key) => keys(
    apple
        ? SingleActivator(key, meta: true)
        : SingleActivator(key, control: true, shift: true),
  );
  final tabs = tabShortcuts(platform);
  String tabKeys(bool Function(TabCommand command) test) => [
    for (final shortcut in tabs)
      if (test(shortcut.command)) keys(shortcut.chord),
  ].join(' or ');
  String goTo(int number) =>
      tabKeys((c) => c is GoToTabCommand && c.number == number);

  return [
    (
      title: 'Tabs',
      rows: [
        (action: 'New tab', keys: terminal(LogicalKeyboardKey.keyT)),
        (action: 'Close tab', keys: tabKeys((c) => c is CloseTabCommand)),
        (
          action: 'Next tab',
          keys: tabKeys((c) => c is StepTabCommand && c.step > 0),
        ),
        (
          action: 'Previous tab',
          keys: tabKeys((c) => c is StepTabCommand && c.step < 0),
        ),
        (action: 'Tab 1 to 8', keys: '${goTo(1)} to ${goTo(8)}'),
        (action: 'Last tab', keys: goTo(GoToTabCommand.last)),
      ],
    ),
    (
      title: 'Terminal',
      rows: [
        (action: 'Copy', keys: terminal(LogicalKeyboardKey.keyC)),
        (action: 'Paste', keys: terminal(LogicalKeyboardKey.keyV)),
        (action: 'Select all', keys: terminal(LogicalKeyboardKey.keyA)),
        // Apple writes ⌘+; elsewhere Shift is already in the chord, so the
        // row names the key it is pressed on.
        (
          action: 'Zoom in',
          keys: terminal(
            apple ? LogicalKeyboardKey.add : LogicalKeyboardKey.equal,
          ),
        ),
        (action: 'Zoom out', keys: terminal(LogicalKeyboardKey.minus)),
        (action: 'Actual size', keys: terminal(LogicalKeyboardKey.digit0)),
        (action: 'Generate command', keys: terminal(LogicalKeyboardKey.keyK)),
      ],
    ),
    (
      title: 'App',
      rows: [
        (action: 'Filter servers', keys: keys(serverFilterActivator(platform))),
        (
          action: 'Settings',
          keys: keys(
            SingleActivator(
              LogicalKeyboardKey.comma,
              meta: apple,
              control: !apple,
            ),
          ),
        ),
      ],
    ),
  ];
}

/// [chord] as the platform writes it: modifier glyphs in Apple's order
/// (⌃⌥⇧⌘) run together, or "Ctrl+Shift+W".
String _describe(SingleActivator chord, {required bool apple}) {
  final key = chord.trigger;
  if (apple) {
    return [
      if (chord.control) '⌃',
      if (chord.alt) '⌥',
      if (chord.shift) '⇧',
      if (chord.meta) '⌘',
      key == LogicalKeyboardKey.tab ? '⇥' : key.keyLabel,
    ].join();
  }
  return [
    if (chord.control) 'Ctrl',
    if (chord.alt) 'Alt',
    if (chord.shift) 'Shift',
    key.keyLabel,
  ].join('+');
}

/// The shortcut list in a dialog, for this platform.
Future<void> showKeyboardShortcuts(BuildContext context) {
  final theme = Theme.of(context);
  final sections = keyboardShortcutSections(theme.platform);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, section) in sections.indexed) ...[
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 16, bottom: 4),
                  child: Text(section.title, style: theme.textTheme.titleSmall),
                ),
                for (final row in section.rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(row.action)),
                        const SizedBox(width: 16),
                        Flexible(
                          child: Text(row.keys, textAlign: TextAlign.end),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
