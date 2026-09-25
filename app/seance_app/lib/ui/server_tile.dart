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
  });

  /// Shown whether or not sync is set up: the flag is the user's standing
  /// answer for this server, and hiding it until an account exists would
  /// make it look like it had been forgotten.
  static const String excludedDescription =
      'Excluded from sync — this device only';

  /// An IPv6 host bracketed, so the port after it still reads as one.
  String get _host =>
      server.host.contains(':') ? '[${server.host}]' : server.host;

  String get _address => '${server.username}@$_host:${server.port}';

  /// The row's second line: `user@host`, with the port only when it is
  /// not SSH's default, the form Poltergeist's rows show. Always handed to
  /// the kit, which draws it only on a comfortable row; the tooltip and
  /// the announced label keep the full [_address] either way.
  String get _subtitleAddress {
    final base = '${server.username}@$_host';
    return server.port == 22 ? base : '$base:${server.port}';
  }

  /// The second line as the kit draws it: a state the user has to act on
  /// or wait for comes first, so the ellipsis takes the address rather
  /// than the news (the order Poltergeist's rows use); a healthy or
  /// unknown state leaves the line to the address, the dot saying the rest.
  String get _subtitle => switch (dot) {
    ServerDot.connecting ||
    ServerDot.failed ||
    ServerDot.unreachable => '${dot.description} · $_subtitleAddress',
    ServerDot.none ||
    ServerDot.connected ||
    ServerDot.reachable => _subtitleAddress,
  };

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
      subtitle: _subtitle,
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
      selected: selected,
      depth: depth,
      // The address, the state and the exclusion are pictures or absent on
      // a compact row: the tooltip carries them for a pointer, the label
      // for a screen reader. The "⋮" is the kit's call (comfortable rows
      // and touch draw it).
      tooltip: [_address, ?state, if (excluded) excludedDescription].join('\n'),
      semanticLabel: [
        server.label,
        _address,
        ?state,
        if (tabCount > 1) '$tabCount tabs',
        if (excluded) excludedDescription,
      ].join(', '),
      onActivate: (how) => _activate(how, Theme.of(context).platform),
      menuEntries: _verbs,
    );
  }

  /// A plain click opens (or returns to) the server's session; ⌘-click, or
  /// Ctrl-click off Apple platforms, opens another tab, as ⌘T does.
  ///
  /// On a Mac, Control-click is the secondary click, but the embedder
  /// delivers it as a primary click with Control held. The sidebar kit
  /// turns it into the row's context menu before it gets here; this guard
  /// keeps it from opening a tab or connecting anything should one reach
  /// the row another way.
  void _activate(SidebarActivation how, TargetPlatform platform) {
    final keys = HardwareKeyboard.instance;
    final apple =
        platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
    if (how == SidebarActivation.pointer) {
      if (apple ? keys.isMetaPressed : keys.isControlPressed) {
        onNewTab();
        return;
      }
      if (apple && keys.isControlPressed) return;
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

  /// The Android list's glyph size inside its 40 dp disc — the same
  /// proportions Poltergeist's Home uses.
  static const double _discGlyphSize = 24;

  /// The disc's fill behind an untinted glyph.
  static const double _discTintAlpha = 0.16;

  @override
  Widget build(BuildContext context) {
    final extent = sidebarMarkExtent(context);
    final tint = ServerTint.of(server);
    final accent = serverAccent(context, tint);
    final mark = server.mark;
    if (SidebarKitScope.layoutOf(context) == SidebarKitLayout.list) {
      return ExcludeSemantics(child: _disc(context, extent, tint, accent));
    }
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

  /// The Android list's mark (sibling contract §10.6): an untinted glyph
  /// on a tertiary disc, so a plain server still reads as a server, and
  /// a server with its own colour, emoji or image as its badge clipped
  /// to a circle.
  Widget _disc(
    BuildContext context,
    double extent,
    ServerTint tint,
    ServerAccent? accent,
  ) {
    final mark = server.mark;
    if (mark is ServerGlyphMark && accent == null) {
      final color = Theme.of(context).colorScheme.tertiary;
      return SizedBox.square(
        dimension: extent,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: _discTintAlpha),
            shape: BoxShape.circle,
          ),
          child: Icon(
            serverIconData(mark.icon),
            size: _discGlyphSize,
            color: color,
          ),
        ),
      );
    }
    return ClipOval(
      child: ServerBadge(tint: tint, mark: mark, size: extent),
    );
  }
}
