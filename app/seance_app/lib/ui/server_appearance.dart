import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../theme.dart';

/// How a [ServerColor] and [ServerIcon] become pixels.
///
/// The protocol stores *names* (see `ServerColor`'s own doc for why), and this
/// is the only place that turns them into colors and glyphs. Keeping the
/// mapping in one file means a new accent is a seed plus an enum value, and
/// nothing else in the app has to learn about it.

/// The seed each accent is generated from. These are hues, not final colors —
/// what actually gets painted is derived per brightness below.
const Map<ServerColor, Color> _seeds = {
  // The app's own violet, so "no strong opinion, just tag it" lands on
  // something that already belongs to Séance.
  ServerColor.violet: Color(0xFF6B5BD2),
  ServerColor.blue: Color(0xFF2F6FED),
  ServerColor.cyan: Color(0xFF00A3C4),
  ServerColor.teal: Color(0xFF12897E),
  ServerColor.green: Color(0xFF2F9E44),
  ServerColor.amber: Color(0xFFD9A404),
  ServerColor.orange: Color(0xFFE8590C),
  ServerColor.red: Color(0xFFE03131),
  ServerColor.pink: Color(0xFFD6336C),
  ServerColor.slate: Color(0xFF64748B),
};

/// The three colors an accent is drawn with: a [container] to fill, an
/// [onContainer] that is legible on it, and a saturated [line] for rules and
/// borders where a fill would be too much.
class ServerAccent {
  final Color container;
  final Color onContainer;
  final Color line;

  const ServerAccent({
    required this.container,
    required this.onContainer,
    required this.line,
  });
}

/// Derived accents, memoized per (color, brightness).
///
/// The derivation is `ColorScheme.fromSeed` — the same machinery
/// [SeanceTheme] builds the app's own theme with, so an accent is tonally a
/// Séance color rather than a raw hue dropped on top of one. That machinery
/// is not free (it is real HCT math), and these are read once per server per
/// build of the list, so the twenty possible results are computed once and
/// kept. The map is bounded by the enum: it cannot grow.
final Map<(ServerColor, Brightness), ServerAccent> _accents = {};

/// The accent for [color] under the current theme brightness, or null when the
/// server has no color and should be drawn neutrally.
ServerAccent? serverAccent(BuildContext context, ServerColor? color) {
  if (color == null) return null;
  final brightness = Theme.of(context).brightness;
  return _accents.putIfAbsent((color, brightness), () {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seeds[color]!,
      brightness: brightness,
    );
    return ServerAccent(
      container: scheme.primaryContainer,
      onContainer: scheme.onPrimaryContainer,
      line: scheme.primary,
    );
  });
}

/// The glyph for [icon]. Every value is a const [IconData] reached through a
/// switch rather than a lookup on a stored codepoint — see `ServerIcon`'s doc
/// for why that distinction survives into the release build.
IconData serverIconData(ServerIcon? icon) => switch (icon) {
  ServerIcon.server || null => Icons.dns_outlined,
  ServerIcon.cloud => Icons.cloud_outlined,
  ServerIcon.database => Icons.storage_outlined,
  ServerIcon.web => Icons.language,
  ServerIcon.terminal => Icons.terminal,
  ServerIcon.shield => Icons.shield_outlined,
  ServerIcon.home => Icons.home_outlined,
  ServerIcon.work => Icons.work_outline,
  ServerIcon.lab => Icons.science_outlined,
  ServerIcon.device => Icons.developer_board,
  ServerIcon.router => Icons.router_outlined,
  ServerIcon.mail => Icons.mail_outline,
  ServerIcon.container => Icons.inventory_2_outlined,
  ServerIcon.rocket => Icons.rocket_launch_outlined,
  ServerIcon.star => Icons.star_outline,
  ServerIcon.bug => Icons.bug_report_outlined,
};

/// A human name for [icon], for the editor's picker tooltips.
String serverIconLabel(ServerIcon? icon) => switch (icon) {
  null => 'Default',
  ServerIcon.server => 'Server',
  ServerIcon.cloud => 'Cloud',
  ServerIcon.database => 'Database',
  ServerIcon.web => 'Web',
  ServerIcon.terminal => 'Terminal',
  ServerIcon.shield => 'Secure',
  ServerIcon.home => 'Home',
  ServerIcon.work => 'Work',
  ServerIcon.lab => 'Lab',
  ServerIcon.device => 'Device',
  ServerIcon.router => 'Router',
  ServerIcon.mail => 'Mail',
  ServerIcon.container => 'Container',
  ServerIcon.rocket => 'Production',
  ServerIcon.star => 'Favourite',
  ServerIcon.bug => 'Testing',
};

/// A human name for [color], for the editor's swatch tooltips.
String serverColorLabel(ServerColor? color) => color == null
    ? 'None'
    : '${color.name[0].toUpperCase()}${color.name.substring(1)}';

/// A server's icon on its accent: the mark that says *which* box a row is.
///
/// Takes the two values rather than a whole [ServerConfig] so the editor can
/// preview a colour and icon the user is still choosing, before there is a
/// config to preview them on.
class ServerBadge extends StatelessWidget {
  final ServerColor? color;
  final ServerIcon? icon;
  final double size;

  const ServerBadge({
    super.key,
    required this.color,
    required this.icon,
    this.size = 32,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = serverAccent(context, color);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // No accent: the neutral surface tone, so an untagged server still
        // lines up with a tagged one instead of leaving a hole where the badge
        // would be.
        color: accent?.container ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(
        serverIconData(icon),
        size: size * 0.56,
        color: accent?.onContainer ?? scheme.onSurfaceVariant,
      ),
    );
  }
}

/// A [ServerBadge] with the connection status dot tucked into its corner.
///
/// The two are drawn together rather than side by side because the row is as
/// narrow as 200 logical pixels in the resizable list pane, and because they
/// answer one question between them — *which* box, and is it up. The status
/// dot keeps its own tooltip, so nothing is lost by the arrangement.
class ServerAvatar extends StatelessWidget {
  /// Taken as the accent and glyph rather than as a whole [ServerConfig], so
  /// the pinned local-shell row can wear the same mark as the servers below
  /// it. It has no config — and a row that looked structurally different
  /// would read as a different kind of thing rather than as another place to
  /// open a terminal.
  final ServerColor? color;
  final ServerIcon? icon;
  final TerminalStatus connection;

  static const double _badgeSize = 32;
  static const double _dotSize = 14;

  /// The badge plus the overhang of the dot on its bottom-right corner.
  static const double _extent = 36;

  const ServerAvatar({
    super.key,
    this.color,
    this.icon,
    required this.connection,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _extent,
      height: _extent,
      child: Stack(
        children: [
          ServerBadge(color: color, icon: icon, size: _badgeSize),
          // Directional so the dot tucks into the badge's trailing corner
          // rather than its leading one under a right-to-left locale.
          PositionedDirectional(
            end: 0,
            bottom: 0,
            child: _StatusDot(status: connection, ring: scheme.surface),
          ),
        ],
      ),
    );
  }
}

/// The connection dot, ringed in the surface color so it stays a separate mark
/// when it overlaps the badge behind it.
class _StatusDot extends StatelessWidget {
  final TerminalStatus status;
  final Color ring;
  const _StatusDot({required this.status, required this.ring});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      TerminalStatus.connected => (StatusColors.online(context), 'connected'),
      TerminalStatus.error => (
        StatusColors.offline(context),
        'connection error',
      ),
      TerminalStatus.disconnected => (
        StatusColors.unknown(context),
        'disconnected',
      ),
      TerminalStatus.connecting => (
        StatusColors.unknown(context),
        'connecting',
      ),
    };
    return Tooltip(
      message: label,
      child: Container(
        width: ServerAvatar._dotSize,
        height: ServerAvatar._dotSize,
        decoration: BoxDecoration(
          color: ring,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: status == TerminalStatus.connecting
              // Sized to the dot it replaces, so the badge doesn't shift while
              // a connection is being made.
              ? const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              : Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
        ),
      ),
    );
  }
}
