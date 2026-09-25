/// How tightly the server list packs its rows.
///
/// Device-local like the terminal's font size, and for the same reason: how
/// many rows fit before scrolling is a property of the screen in front of you,
/// not of the account. It never syncs.
library;

import 'sidebar/sidebar_kit.dart';

/// The two row shapes the server list offers, on the rail and at home alike.
enum ServerListDensity {
  /// The two-line row: a 32 px badge, the label, and the `user@host` it
  /// resolves to (or its state) on a second line.
  comfortable,

  /// One line per server. The address moves into the row's tooltip and the
  /// badge shrinks, which halves a row's height: the point of the mode is
  /// seeing more of a long list at once.
  compact;

  /// The sibling kit's density for this choice, which the list draws with.
  SidebarKitDensity get kit => switch (this) {
    ServerListDensity.comfortable => SidebarKitDensity.comfortable,
    ServerListDensity.compact => SidebarKitDensity.compact,
  };

  /// The stored choice for a density the kit's switch reports.
  static ServerListDensity fromKit(SidebarKitDensity density) =>
      switch (density) {
        SidebarKitDensity.comfortable => ServerListDensity.comfortable,
        SidebarKitDensity.compact => ServerListDensity.compact,
      };
}
