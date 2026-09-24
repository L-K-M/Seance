import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../theme.dart';
import 'server_appearance.dart';
import 'server_status_dot.dart';
import 'sidebar/sidebar_kit.dart';

/// One server's row in the list, drawn by the sibling kit's [SidebarRow]
/// (Poltergeist's plan, 10 §5): the server's badge with its one status dot,
/// the name, and `×N` while it has several tabs open.
///
/// Public so a widget test can assert what the row says without standing up
/// an `AppState`: the dot and the sync-exclusion mark are pictures, and what
/// a screen reader makes of a picture is not something to assume.
class ServerTile extends StatelessWidget {
  final ServerConfig server;
  final ServerDot dot;

  /// Open tabs (terminals and editors) for this server; `×N` shows past one.
  final int tabCount;

  /// The server of the focused session: the row wears the selection pill.
  final bool selected;

  /// Whether this server sits in PINNED. Only the menu reads it: the section
  /// header is what says *which* rows are pinned, so a badge on every row
  /// would say it twice.
  final bool pinned;

  /// 1 under a group's disclosure row.
  final int depth;

  /// Spell `user@host:port` out on a second line. Only a touch home list
  /// asks for it: a desktop rail keeps to one line and leaves the address to
  /// the tooltip, which touch has no hover to show.
  final bool showAddress;

  /// Draw a visible "⋮" for the row's verbs (the home list's; the rail has
  /// right-click and the Menu key).
  final bool showMenuButton;

  final VoidCallback onOpen;
  final VoidCallback onNewTab;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final VoidCallback onTogglePin;

  /// Disconnects every live terminal; null while none is connected, which
  /// greys the verb out and hides the row's hover glyph.
  final VoidCallback? onDisconnect;

  /// Only offered when the server has exactly one (dead) tab; per-tab
  /// reconnect otherwise lives in the pane.
  final VoidCallback? onReconnect;

  const ServerTile({
    super.key,
    required this.server,
    required this.dot,
    required this.tabCount,
    required this.selected,
    required this.pinned,
    required this.onOpen,
    required this.onNewTab,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
    required this.onTogglePin,
    this.onDisconnect,
    this.onReconnect,
    this.depth = 0,
    this.showAddress = false,
    this.showMenuButton = false,
  });

  /// Shown whether or not sync is set up: the flag is the user's standing
  /// answer for this server, and hiding it until an account exists would
  /// make it look like it had been forgotten.
  static const String excludedDescription =
      'Excluded from sync — this device only';

  String get _address => '${server.username}@${server.host}:${server.port}';

  String get _disconnectLabel => tabCount > 1 ? 'Disconnect all' : 'Disconnect';

  @override
  Widget build(BuildContext context) {
    final state = dot.description;
    final excluded = server.excludeFromSync;
    return SidebarRow(
      mark: ServerRailMark(server: server),
      title: server.label,
      status: switch (dot.color(context)) {
        final color? => SidebarStatusDot(color, style: dot.style),
        null => null,
      },
      subtitle: showAddress ? _address : null,
      trailingIcon: excluded ? Icons.cloud_off_outlined : null,
      trailingText: tabCount > 1 ? '×$tabCount' : null,
      hoverAction: onDisconnect == null
          ? null
          : SidebarRowAction(
              key: ValueKey('server.disconnect.${server.id}'),
              icon: Icons.eject,
              tooltip: _disconnectLabel,
              onPressed: onDisconnect!,
            ),
      showMenuButton: showMenuButton,
      selected: selected,
      depth: depth,
      // The address, the state and the exclusion are pictures or absent on
      // a one-line row: the tooltip carries them for a pointer, the label
      // for a screen reader.
      tooltip: [_address, ?state, if (excluded) excludedDescription].join('\n'),
      semanticLabel: [
        server.label,
        _address,
        ?state,
        if (tabCount > 1) '$tabCount tabs',
        if (excluded) excludedDescription,
      ].join(', '),
      onActivate: (how) => _activate(how),
      menuEntries: _verbs,
    );
  }

  /// A plain click opens (or returns to) the server's session; ⌘-click, or
  /// Ctrl-click off Apple platforms, opens another tab, as ⌘T does.
  void _activate(SidebarActivation how) {
    final keys = HardwareKeyboard.instance;
    if (how == SidebarActivation.pointer &&
        (keys.isMetaPressed || keys.isControlPressed)) {
      onNewTab();
      return;
    }
    onOpen();
  }

  List<SidebarMenuEntry> _verbs() => [
    SidebarMenuAction(
      key: const ValueKey('server.menu.connect'),
      label: 'Connect',
      onSelected: onOpen,
    ),
    SidebarMenuAction(
      key: const ValueKey('server.menu.newTab'),
      label: 'Connect in new tab',
      onSelected: onNewTab,
    ),
    const SidebarMenuDivider(),
    // Kept in the menu while nothing is connected, greyed out, so the
    // menu's shape does not shift under the pointer with the state.
    SidebarMenuAction(
      key: const ValueKey('server.menu.disconnect'),
      label: _disconnectLabel,
      onSelected: onDisconnect,
    ),
    if (onReconnect != null)
      SidebarMenuAction(
        key: const ValueKey('server.menu.reconnect'),
        label: 'Reconnect',
        onSelected: onReconnect,
      ),
    const SidebarMenuDivider(),
    SidebarMenuAction(
      key: const ValueKey('server.menu.pin'),
      label: pinned ? 'Unpin' : 'Pin to top',
      onSelected: onTogglePin,
    ),
    const SidebarMenuDivider(),
    SidebarMenuAction(
      key: const ValueKey('server.menu.edit'),
      label: 'Edit…',
      onSelected: onEdit,
    ),
    SidebarMenuAction(
      key: const ValueKey('server.menu.duplicate'),
      label: 'Duplicate',
      onSelected: onDuplicate,
    ),
    SidebarMenuAction(
      key: const ValueKey('server.menu.delete'),
      label: 'Delete…',
      onSelected: onDelete,
    ),
  ];
}

/// A server's mark at the rail's size (see [sidebarMarkExtent]).
///
/// A server with no colour and a built-in glyph draws the glyph alone, like
/// every other rail row in the sibling apps (Poltergeist draws the same
/// server the same way), rather than a grey tile around it. A coloured
/// server gets its badge, whose fill is the colour. An imported image
/// covers that fill, so a coloured image mark is framed in the colour's
/// line tone instead: at 18 px there is no room for the accent bar the
/// larger rows carried beside the badge.
class ServerRailMark extends StatelessWidget {
  final ServerConfig server;
  const ServerRailMark({super.key, required this.server});

  /// The frame around a coloured image mark.
  static const double _frameWidth = 1.5;

  @override
  Widget build(BuildContext context) {
    final extent = sidebarMarkExtent(context);
    final tint = ServerTint.of(server);
    final accent = serverAccent(context, tint);
    final mark = server.mark;
    // Decorative: the row announces the server's name itself.
    if (mark is ServerGlyphMark && accent == null) {
      return ExcludeSemantics(
        child: Icon(
          serverIconData(mark.icon),
          size: extent - 2,
          color: SeanceChrome.of(context).secondaryText,
        ),
      );
    }
    final badge = ExcludeSemantics(
      child: ServerBadge(tint: tint, mark: mark, size: extent),
    );
    if (mark is! ServerImageMark || accent == null) return badge;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(color: accent.line, width: _frameWidth),
        borderRadius: BorderRadius.circular(extent * ServerBadge.cornerRatio),
      ),
      child: badge,
    );
  }
}
