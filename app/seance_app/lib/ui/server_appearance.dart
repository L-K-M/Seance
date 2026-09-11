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

/// One built-in glyph: what it looks like, what it is called, and what else
/// someone might search for it by.
///
/// Reached through the exhaustive switch in [_glyph] rather than a map, so
/// adding a [ServerIcon] without describing it here fails to compile — and so
/// every [IconData] in the app is a *const* reference. Flutter's
/// `--tree-shake-icons` step only keeps glyphs it can see referenced as
/// constants; a codepoint read out of storage and passed to `IconData(...)`
/// compiles fine and ships blank squares (see `ServerIcon`'s own doc).
class _Glyph {
  final IconData data;
  final String label;

  /// Extra terms the picker's search matches, for glyphs whose label is not
  /// what someone would type — nobody searches "Database" for `psql`.
  final String keywords;

  const _Glyph(this.data, this.label, {this.keywords = ''});
}

_Glyph _glyph(ServerIcon icon) => switch (icon) {
  ServerIcon.server => const _Glyph(Icons.dns_outlined, 'Server'),
  ServerIcon.cloud => const _Glyph(
    Icons.cloud_outlined, 'Cloud', keywords: 'vps provider',
  ),
  ServerIcon.cluster => const _Glyph(
    Icons.hub_outlined, 'Cluster', keywords: 'kubernetes k8s swarm nodes',
  ),
  ServerIcon.vm => const _Glyph(
    Icons.memory, 'Virtual machine', keywords: 'vps kvm hypervisor guest',
  ),
  ServerIcon.desktop => const _Glyph(
    Icons.desktop_windows_outlined, 'Desktop', keywords: 'workstation pc',
  ),
  ServerIcon.laptop => const _Glyph(
    Icons.laptop_outlined, 'Laptop', keywords: 'notebook',
  ),
  ServerIcon.device => const _Glyph(
    Icons.developer_board, 'Board',
    keywords: 'raspberry pi arduino embedded iot',
  ),
  ServerIcon.router => const _Glyph(
    Icons.router_outlined, 'Router', keywords: 'gateway firewall modem',
  ),
  ServerIcon.network => const _Glyph(
    Icons.lan_outlined, 'Network', keywords: 'lan switch subnet',
  ),
  ServerIcon.vpn => const _Glyph(
    Icons.vpn_lock_outlined, 'VPN', keywords: 'wireguard tunnel tailscale',
  ),
  ServerIcon.dataCenter => const _Glyph(
    Icons.warehouse_outlined, 'Data centre', keywords: 'rack colo dc',
  ),
  ServerIcon.satellite => const _Glyph(
    Icons.satellite_alt_outlined, 'Satellite', keywords: 'uplink relay',
  ),
  ServerIcon.sensor => const _Glyph(
    Icons.sensors_outlined, 'Sensors', keywords: 'iot telemetry probe',
  ),
  ServerIcon.printer => const _Glyph(
    Icons.print_outlined, 'Printer', keywords: 'cups printing',
  ),
  ServerIcon.power => const _Glyph(
    Icons.power_outlined, 'Power', keywords: 'ups pdu outlet',
  ),
  ServerIcon.container => const _Glyph(
    Icons.inventory_2_outlined, 'Container', keywords: 'docker podman image',
  ),
  ServerIcon.database => const _Glyph(
    Icons.storage_outlined, 'Database', keywords: 'db sql psql postgres mysql redis',
  ),
  ServerIcon.files => const _Glyph(
    Icons.folder_outlined, 'File store', keywords: 'nas smb share folder',
  ),
  ServerIcon.backup => const _Glyph(
    Icons.backup_outlined, 'Backup', keywords: 'restic borg snapshot',
  ),
  ServerIcon.archive => const _Glyph(
    Icons.archive_outlined, 'Archive', keywords: 'cold tape retention',
  ),
  ServerIcon.layers => const _Glyph(
    Icons.layers_outlined, 'Stack', keywords: 'tier layer environment',
  ),
  ServerIcon.web => const _Glyph(
    Icons.language, 'Web', keywords: 'http www site nginx apache',
  ),
  ServerIcon.api => const _Glyph(
    Icons.api_outlined, 'API', keywords: 'rest graphql endpoint',
  ),
  ServerIcon.mail => const _Glyph(
    Icons.mail_outline, 'Mail', keywords: 'smtp imap postfix',
  ),
  ServerIcon.chat => const _Glyph(
    Icons.chat_bubble_outline, 'Chat', keywords: 'xmpp matrix irc messaging',
  ),
  ServerIcon.forum => const _Glyph(
    Icons.forum_outlined, 'Forum', keywords: 'discourse board community',
  ),
  ServerIcon.feed => const _Glyph(
    Icons.rss_feed, 'Feed', keywords: 'rss atom reader',
  ),
  ServerIcon.dashboard => const _Glyph(
    Icons.dashboard_outlined, 'Dashboard', keywords: 'grafana panel admin',
  ),
  ServerIcon.monitoring => const _Glyph(
    Icons.monitor_heart_outlined, 'Monitoring',
    keywords: 'prometheus uptime alert health',
  ),
  ServerIcon.analytics => const _Glyph(
    Icons.query_stats, 'Analytics', keywords: 'metrics statistics reports',
  ),
  ServerIcon.media => const _Glyph(
    Icons.ondemand_video_outlined, 'Media',
    keywords: 'plex jellyfin video streaming',
  ),
  ServerIcon.music => const _Glyph(
    Icons.music_note_outlined, 'Music', keywords: 'audio navidrome stream',
  ),
  ServerIcon.photos => const _Glyph(
    Icons.photo_library_outlined, 'Photos', keywords: 'immich gallery images',
  ),
  ServerIcon.game => const _Glyph(
    Icons.sports_esports_outlined, 'Game server',
    keywords: 'minecraft steam gaming',
  ),
  ServerIcon.voice => const _Glyph(
    Icons.phone_in_talk_outlined, 'Voice', keywords: 'sip voip pbx asterisk',
  ),
  ServerIcon.camera => const _Glyph(
    Icons.videocam_outlined, 'Cameras', keywords: 'cctv nvr surveillance',
  ),
  ServerIcon.shop => const _Glyph(
    Icons.shopping_cart_outlined, 'Shop', keywords: 'store commerce checkout',
  ),
  ServerIcon.billing => const _Glyph(
    Icons.receipt_long_outlined, 'Billing', keywords: 'invoices accounting',
  ),
  ServerIcon.calendar => const _Glyph(
    Icons.calendar_month_outlined, 'Calendar', keywords: 'caldav scheduling',
  ),
  ServerIcon.docs => const _Glyph(
    Icons.description_outlined, 'Documents', keywords: 'office notes paperwork',
  ),
  ServerIcon.wiki => const _Glyph(
    Icons.menu_book_outlined, 'Wiki', keywords: 'knowledge handbook docs',
  ),
  ServerIcon.ai => const _Glyph(
    Icons.psychology_outlined, 'AI', keywords: 'llm model inference gpu',
  ),
  ServerIcon.bot => const _Glyph(
    Icons.smart_toy_outlined, 'Bot', keywords: 'automation agent worker',
  ),
  ServerIcon.terminal => const _Glyph(
    Icons.terminal, 'Shell', keywords: 'console command',
  ),
  ServerIcon.code => const _Glyph(
    Icons.code, 'Code', keywords: 'dev ide source',
  ),
  ServerIcon.git => const _Glyph(
    Icons.account_tree_outlined, 'Git',
    keywords: 'repository forge version control',
  ),
  ServerIcon.build => const _Glyph(
    Icons.build_outlined, 'Build', keywords: 'ci runner pipeline jenkins',
  ),
  ServerIcon.plugin => const _Glyph(
    Icons.extension_outlined, 'Plugin', keywords: 'addon module',
  ),
  ServerIcon.lab => const _Glyph(
    Icons.science_outlined, 'Lab', keywords: 'staging experiment sandbox',
  ),
  ServerIcon.bug => const _Glyph(
    Icons.bug_report_outlined, 'Testing', keywords: 'qa test debug',
  ),
  ServerIcon.construction => const _Glyph(
    Icons.construction_outlined, 'Work in progress', keywords: 'wip unfinished',
  ),
  ServerIcon.rocket => const _Glyph(
    Icons.rocket_launch_outlined, 'Production',
    keywords: 'prod live deploy release',
  ),
  ServerIcon.speed => const _Glyph(
    Icons.speed, 'Performance', keywords: 'benchmark load fast',
  ),
  ServerIcon.widgets => const _Glyph(
    Icons.widgets_outlined, 'Components', keywords: 'services parts',
  ),
  ServerIcon.shield => const _Glyph(
    Icons.shield_outlined, 'Secure', keywords: 'hardened protected',
  ),
  ServerIcon.lock => const _Glyph(
    Icons.lock_outline, 'Locked', keywords: 'private restricted',
  ),
  ServerIcon.key => const _Glyph(
    Icons.key_outlined, 'Keys', keywords: 'vault secrets credentials',
  ),
  ServerIcon.admin => const _Glyph(
    Icons.admin_panel_settings_outlined, 'Admin',
    keywords: 'root privileged control',
  ),
  ServerIcon.verified => const _Glyph(
    Icons.verified_user_outlined, 'Trusted', keywords: 'audited verified',
  ),
  ServerIcon.home => const _Glyph(
    Icons.home_outlined, 'Home', keywords: 'house homelab',
  ),
  ServerIcon.work => const _Glyph(
    Icons.work_outline, 'Work', keywords: 'job employer',
  ),
  ServerIcon.office => const _Glyph(
    Icons.business_outlined, 'Office', keywords: 'company headquarters',
  ),
  ServerIcon.plant => const _Glyph(
    Icons.factory_outlined, 'Factory', keywords: 'industrial works',
  ),
  ServerIcon.cottage => const _Glyph(
    Icons.cottage_outlined, 'Cabin', keywords: 'cottage retreat',
  ),
  ServerIcon.public => const _Glyph(
    Icons.public_outlined, 'Public', keywords: 'internet global world',
  ),
  ServerIcon.star => const _Glyph(
    Icons.star_outline, 'Favourite', keywords: 'starred important',
  ),
  ServerIcon.favourite => const _Glyph(
    Icons.favorite_outline, 'Loved', keywords: 'heart',
  ),
  ServerIcon.bolt => const _Glyph(
    Icons.bolt, 'Fast', keywords: 'quick lightning',
  ),
  ServerIcon.hot => const _Glyph(
    Icons.local_fire_department_outlined, 'Hot',
    keywords: 'busy urgent burning',
  ),
  ServerIcon.frozen => const _Glyph(
    Icons.ac_unit, 'Frozen', keywords: 'cold paused dormant',
  ),
  ServerIcon.watch => const _Glyph(
    Icons.visibility_outlined, 'Watched', keywords: 'observe eye',
  ),
  ServerIcon.caution => const _Glyph(
    Icons.warning_amber_outlined, 'Careful', keywords: 'warning danger fragile',
  ),
  ServerIcon.magic => const _Glyph(
    Icons.auto_awesome_outlined, 'Special', keywords: 'magic sparkle',
  ),
  ServerIcon.pets => const _Glyph(
    Icons.pets, 'Pet project', keywords: 'animal',
  ),
  ServerIcon.coffee => const _Glyph(
    Icons.coffee_outlined, 'Coffee', keywords: 'cafe break',
  ),
  ServerIcon.anchor => const _Glyph(
    Icons.anchor, 'Anchor', keywords: 'stable fixed harbour',
  ),
  ServerIcon.eco => const _Glyph(
    Icons.eco_outlined, 'Green', keywords: 'leaf efficient',
  ),
};

/// The default glyph: what a server with no icon of its own is drawn with.
const IconData _defaultGlyph = Icons.dns_outlined;

/// The glyph for [icon], or the default when there is none.
IconData serverIconData(ServerIcon? icon) =>
    icon == null ? _defaultGlyph : _glyph(icon).data;

/// A human name for [icon], for the picker's labels and tooltips.
String serverIconLabel(ServerIcon? icon) =>
    icon == null ? 'Default' : _glyph(icon).label;

/// Whether [icon] matches the picker's search [query]. Matches the label and
/// the glyph's extra terms, so "k8s" finds the cluster glyph and "psql" the
/// database one.
bool serverIconMatches(ServerIcon? icon, String query) {
  // Every whitespace-separated term has to match somewhere, rather than the
  // query matching as one contiguous run: "docker container" is how people
  // search an icon grid, and as a single substring it matches nothing, since
  // no label or keyword list contains that phrase in that order.
  final terms = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((term) => term.isEmpty);
  if (terms.isEmpty) return true;
  if (icon == null) return terms.every('default'.contains);
  final glyph = _glyph(icon);
  // Lower-cased here rather than relying on the table being written that way,
  // so one capitalised keyword cannot silently drop out of search.
  final haystack = '${glyph.label} ${glyph.keywords}'.toLowerCase();
  return terms.every(haystack.contains);
}

/// The glyphs, under the headings the picker files them beneath.
///
/// The headings are presentation, not protocol: a later version may move a
/// glyph between them, and nothing that syncs changes. Every [ServerIcon] must
/// appear exactly once, which `server_appearance_test.dart` asserts — a glyph
/// missing from here would be unreachable in the picker while remaining
/// perfectly valid in a record.
const List<(String, List<ServerIcon>)> serverIconGroups = [
  (
    'Infrastructure',
    <ServerIcon>[
      ServerIcon.server,
      ServerIcon.cloud,
      ServerIcon.cluster,
      ServerIcon.vm,
      ServerIcon.desktop,
      ServerIcon.laptop,
      ServerIcon.device,
      ServerIcon.router,
      ServerIcon.network,
      ServerIcon.vpn,
      ServerIcon.dataCenter,
      ServerIcon.satellite,
      ServerIcon.sensor,
      ServerIcon.printer,
      ServerIcon.power,
      ServerIcon.container,
    ],
  ),
  (
    'Storage',
    <ServerIcon>[
      ServerIcon.database,
      ServerIcon.files,
      ServerIcon.backup,
      ServerIcon.archive,
      ServerIcon.layers,
    ],
  ),
  (
    'Services',
    <ServerIcon>[
      ServerIcon.web,
      ServerIcon.api,
      ServerIcon.mail,
      ServerIcon.chat,
      ServerIcon.forum,
      ServerIcon.feed,
      ServerIcon.dashboard,
      ServerIcon.monitoring,
      ServerIcon.analytics,
      ServerIcon.media,
      ServerIcon.music,
      ServerIcon.photos,
      ServerIcon.game,
      ServerIcon.voice,
      ServerIcon.camera,
      ServerIcon.shop,
      ServerIcon.billing,
      ServerIcon.calendar,
      ServerIcon.docs,
      ServerIcon.wiki,
      ServerIcon.ai,
      ServerIcon.bot,
    ],
  ),
  (
    'Building',
    <ServerIcon>[
      ServerIcon.terminal,
      ServerIcon.code,
      ServerIcon.git,
      ServerIcon.build,
      ServerIcon.plugin,
      ServerIcon.lab,
      ServerIcon.bug,
      ServerIcon.construction,
      ServerIcon.rocket,
      ServerIcon.speed,
      ServerIcon.widgets,
    ],
  ),
  (
    'Access',
    <ServerIcon>[
      ServerIcon.shield,
      ServerIcon.lock,
      ServerIcon.key,
      ServerIcon.admin,
      ServerIcon.verified,
    ],
  ),
  (
    'Places',
    <ServerIcon>[
      ServerIcon.home,
      ServerIcon.work,
      ServerIcon.office,
      ServerIcon.plant,
      ServerIcon.cottage,
      ServerIcon.public,
    ],
  ),
  (
    'Marks',
    <ServerIcon>[
      ServerIcon.star,
      ServerIcon.favourite,
      ServerIcon.bolt,
      ServerIcon.hot,
      ServerIcon.frozen,
      ServerIcon.watch,
      ServerIcon.caution,
      ServerIcon.magic,
      ServerIcon.pets,
      ServerIcon.coffee,
      ServerIcon.anchor,
      ServerIcon.eco,
    ],
  ),
];

/// A human name for [color], for the editor's swatch tooltips.
String serverColorLabel(ServerColor? color) => color == null
    ? 'None'
    : '${color.name[0].toUpperCase()}${color.name.substring(1)}';

/// A server's mark on its accent: what says *which* box a row is.
///
/// Takes a colour and a [ServerMark] rather than a whole [ServerConfig] so the
/// editor can preview a pair the user is still choosing, before there is a
/// config to preview them on.
class ServerBadge extends StatelessWidget {
  final ServerColor? color;
  final ServerMark mark;
  final double size;

  const ServerBadge({
    super.key,
    required this.color,
    required this.mark,
    this.size = 32,
  });

  /// Convenience for the common case: a built-in glyph, or none.
  ServerBadge.glyph({
    super.key,
    required this.color,
    required ServerIcon? icon,
    this.size = 32,
  }) : mark = ServerGlyphMark(icon);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = serverAccent(context, color);
    final radius = BorderRadius.circular(size * 0.28);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // No accent: the neutral surface tone, so an untagged server still
        // lines up with a tagged one instead of leaving a hole where the badge
        // would be.
        color: accent?.container ?? scheme.surfaceContainerHighest,
        borderRadius: radius,
      ),
      // Clipped so an imported image takes the badge's own shape rather than
      // squaring off the corner the accent rounds.
      child: ClipRRect(
        borderRadius: radius,
        child: Center(child: _content(accent, scheme)),
      ),
    );
  }

  Widget _content(ServerAccent? accent, ColorScheme scheme) {
    switch (mark) {
      case ServerImageMark(:final png, :final fallback):
        return Image.memory(
          png,
          width: size,
          height: size,
          // Fills the badge and crops rather than letterboxing: a badge with
          // bars down its sides reads as a broken image.
          fit: BoxFit.cover,
          // Decoded at badge size rather than at the stored size: for a list
          // of thirty servers that is the difference between thirty
          // thumbnails and thirty full bitmaps in the image cache. Three times
          // the logical size covers the densest display anyone runs this on,
          // and stays at or below the side the image is stored at.
          cacheWidth: (size * 3).round(),
          filterQuality: FilterQuality.medium,
          // Bytes that will not decode fall back to the glyph stored beside
          // them, which is what an older build would have drawn anyway.
          errorBuilder: (_, _, _) => _glyphIcon(fallback, accent, scheme),
        );
      case ServerEmojiMark(:final emoji):
        // Scaled down rather than clipped: a wide cluster (a family emoji, a
        // flag) is wider than the badge, and the ClipRRect above would slice
        // it through the middle. Shrinking keeps the whole glyph. A single
        // emoji is narrower than the box and is left at its natural size.
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            emoji,
            // Sized against the glyph it replaces rather than the badge, so an
            // emoji and an icon sit at the same visual weight. No colour: an
            // emoji carries its own, and tinting it would either do nothing or
            // ruin it.
            style: TextStyle(fontSize: size * 0.56, height: 1.1),
            textAlign: TextAlign.center,
          ),
        );
      case ServerGlyphMark(:final icon):
        return _glyphIcon(icon, accent, scheme);
    }
  }

  Widget _glyphIcon(
    ServerIcon? icon,
    ServerAccent? accent,
    ColorScheme scheme,
  ) => Icon(
    serverIconData(icon),
    size: size * 0.56,
    color: accent?.onContainer ?? scheme.onSurfaceVariant,
    // The badge identifies the server at a glance; without this it is an
    // unlabelled image to a screen reader, in the one widget whose entire job
    // is telling servers apart.
    semanticLabel: serverIconLabel(icon),
  );
}

/// A [ServerBadge] with the connection status dot tucked into its corner.
///
/// The two are drawn together rather than side by side because the row is as
/// narrow as 200 logical pixels in the resizable list pane, and because they
/// answer one question between them — *which* box, and is it up. The status
/// dot keeps its own tooltip, so nothing is lost by the arrangement.
class ServerAvatar extends StatelessWidget {
  final ServerConfig server;
  final TerminalStatus connection;

  static const double _badgeSize = 32;
  static const double _dotSize = 14;

  /// The badge plus the overhang of the dot on its bottom-right corner.
  static const double _extent = 36;

  const ServerAvatar({
    super.key,
    required this.server,
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
          ServerBadge(
            color: server.color,
            mark: server.mark,
            size: _badgeSize,
          ),
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
