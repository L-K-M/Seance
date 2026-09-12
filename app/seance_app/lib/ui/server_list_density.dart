/// How tightly the server list packs its rows.
///
/// Device-local like the terminal's font size, and for the same reason: how
/// many rows fit before scrolling is a property of the screen in front of you,
/// not of the account. It never syncs.
library;

/// The two row shapes the server list offers.
enum ServerListDensity {
  /// The two-line row: badge, label, and the `user@host:port` it resolves to
  /// on a second line.
  comfortable,

  /// One line per server. The address moves into the row's tooltip and the
  /// badge shrinks, which roughly halves a row's height — the point of the
  /// mode is seeing more of a long list at once.
  compact;

  /// What the view menu calls this.
  String get label => switch (this) {
    ServerListDensity.comfortable => 'Comfortable',
    ServerListDensity.compact => 'Compact',
  };
}
