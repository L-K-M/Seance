import 'package:flutter/material.dart';
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';

import '../app_state.dart';
import '../family_hues.dart';
import '../main.dart';
import '../theme.dart';
import 'app_menus.dart';
import 'macos_toolbar_band.dart';
import 'server_appearance.dart';

/// The wide layout's header on macOS, drawn under the unified toolbar band
/// the way Poltergeist's is (`MacosTitlebar.install`): the window's title
/// and its toolbar in one row, with the traffic lights over the rail to its
/// left instead of a standard titlebar above everything.
///
/// The title is the active server's badge and label with `user@host` under
/// it, what a titlebar would otherwise say. It stays out of the click
/// passthrough, so dragging it moves the window and double-clicking it
/// zooms, as a titlebar does; the buttons are wrapped in
/// [MacosToolbarPassthrough] so their clicks reach Flutter rather than
/// AppKit's titlebar. Generate command lives here as the primary, labelled
/// button (Poltergeist's Connect), and leaves the tab strip below.
class HeaderToolbar extends StatelessWidget {
  const HeaderToolbar({super.key});

  static const titleKey = ValueKey('header.title');
  static const subtitleKey = ValueKey('header.subtitle');
  static const generateCommandKey = ValueKey('header.generateCommand');

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final chrome = SeanceChrome.of(context);
    final platform = Theme.of(context).platform;
    // Only a window with the unified toolbar has passthrough views to
    // register; anywhere else the header is plain Flutter.
    final native = MacosToolbarBandScope.unifiedToolbarOf(context);
    Widget pass(Widget child) =>
        native ? MacosToolbarPassthrough(child: child) : child;

    final header = Material(
      color: chrome.headerBackground,
      child: SizedBox(
        height: chrome.headerHeight,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
          child: Row(
            children: [
              Expanded(
                child: ListenableBuilder(
                  listenable: state,
                  builder: (context, _) => _HeaderTitle(state: state),
                ),
              ),
              const SizedBox(width: 8),
              pass(
                _Capsule(
                  children: [
                    _ToolbarButton(
                      key: generateCommandKey,
                      icon: Icons.auto_fix_high,
                      // The assistant's purple (Poltergeist's D34), as in
                      // the tab strip it replaces.
                      hue: FamilyHue.purple,
                      label: 'Generate command',
                      shortcut: platform == TargetPlatform.macOS
                          ? '⌘K'
                          : 'Ctrl+Shift+K',
                      onPressed: () => openCommandGenerator(state),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return native ? MacosToolbarPassthroughScope(child: header) : header;
  }
}

/// The active server's badge and label, `user@host` under it. Empty while
/// nothing is open: the band is then all window drag, like a titlebar
/// with no title.
class _HeaderTitle extends StatelessWidget {
  const _HeaderTitle({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final active = state.activeTab;
    if (active == null) return const SizedBox.shrink();
    // The stored config, not the session's connect-time snapshot, as the
    // tab strip reads it: a rename or recolour shows at once.
    final server = state.configFor(active.serverId) ?? active.config;
    final theme = Theme.of(context);
    final chrome = SeanceChrome.of(context);
    final port = server.port == 22 ? '' : ':${server.port}';
    final address = server.username.isEmpty
        ? '${server.host}$port'
        : '${server.username}@${server.host}$port';
    return Semantics(
      header: true,
      child: Row(
        children: [
          // Decorative: the label beside it names the server, so a label
          // here would have a screen reader say the name twice.
          ExcludeSemantics(
            child: ServerBadge(
              tint: ServerTint.of(server),
              mark: server.mark,
              size: 24,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  server.label,
                  key: HeaderToolbar.titleKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  address,
                  key: HeaderToolbar.subtitleKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: chrome.secondaryText,
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

/// ForkLift's rounded group behind related toolbar buttons, as in
/// Poltergeist's header. A [Material] rather than a filled box, so the
/// buttons' hover and splash ink paints above the fill.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final chrome = SeanceChrome.of(context);
    return Material(
      color: chrome.capsuleFill,
      borderRadius: BorderRadius.circular(chrome.corner(8)),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A labelled header button in Poltergeist's geometry: 26 px tall, a
/// 17 px glyph in its family hue, the label in the ink.
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    super.key,
    required this.icon,
    required this.hue,
    required this.label,
    required this.shortcut,
    required this.onPressed,
  });

  final IconData icon;
  final FamilyHue hue;
  final String label;
  final String shortcut;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = SeanceChrome.of(context);
    final radius = BorderRadius.circular(chrome.corner(6));
    return Tooltip(
      message: '$label $shortcut',
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        // excludeSemantics drops the InkWell's own tap action with its
        // subtree, so the node carries it for a screen reader's activate.
        onTap: onPressed,
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          hoverColor: chrome.hoverFill,
          child: Container(
            height: 26,
            constraints: const BoxConstraints(minWidth: 30),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: FamilyPalette.of(context).glyph(hue),
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  maxLines: 1,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
