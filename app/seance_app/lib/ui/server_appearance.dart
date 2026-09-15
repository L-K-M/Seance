import 'dart:math' as math;

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

/// Derived accents for custom colours, memoized per (colour, brightness).
///
/// Not bounded by an enum, so bounded by hand: at [_customAccentLimit] the
/// oldest entry makes room for the next (a Dart map iterates in insertion
/// order, so first-in is first-out). Oldest-out rather than clearing the
/// whole map, because a working set that sits exactly at the limit would
/// otherwise clear and re-derive on every badge of every build — the one
/// scheme derivation per badge per build the memo exists to avoid, made
/// permanent. A list of servers each with a colour of its own, seen in both
/// themes, does not get near the limit in any case.
final Map<(int, Brightness), ServerAccent> _customAccents = {};
const int _customAccentLimit = 64;

/// The accent for [tint] under the current theme brightness, or null when the
/// server has no colour and should be drawn neutrally.
ServerAccent? serverAccent(BuildContext context, ServerTint tint) {
  final brightness = Theme.of(context).brightness;
  final custom = tint.custom;
  if (custom != null) {
    final key = (custom.toARGB32(), brightness);
    // Only when about to insert: a hit at the limit must not evict a live
    // entry to make room for nothing.
    if (!_customAccents.containsKey(key)) {
      while (_customAccents.length >= _customAccentLimit) {
        _customAccents.remove(_customAccents.keys.first);
      }
    }
    return _customAccents.putIfAbsent(key, () {
      // The fidelity variant, unlike the tonal-spot default the named
      // accents use: it keeps the seed's own chroma and paints the seed
      // itself as the container tone. So what was picked is what is drawn,
      // give or take the small shifts the scheme makes to keep a foreground
      // legible on it — which is the point of deriving rather than painting
      // the raw value, and what makes one stored colour work in both themes.
      // Tonal spot would instead fold every custom colour into the same
      // pastel the named ones get, and a picker whose saturation and
      // brightness did nothing would be a strange picker.
      final scheme = ColorScheme.fromSeed(
        seedColor: custom,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      );
      return ServerAccent(
        container: scheme.primaryContainer,
        onContainer: scheme.onPrimaryContainer,
        line: scheme.primary,
      );
    });
  }
  final color = tint.named;
  if (color == null) return null;
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

/// What colours a server: a named accent, a colour of the user's own, or
/// nothing.
///
/// `ServerConfig` stores the two in two fields (its `customColor` doc says
/// why), and this resolves them the way [ServerMark] resolves the three mark
/// fields: the custom colour wins, and the named accent beside it is what an
/// older build draws instead. Everything that paints a server's colour takes
/// one of these rather than the fields, so the precedence lives here — and
/// so the editor can preview a choice before there is a config to make it on.
@immutable
class ServerTint {
  /// The named accent, or null. Drawn when [custom] is null; kept as the
  /// older-build stand-in otherwise.
  final ServerColor? named;

  /// The user's own colour, opaque, or null.
  final Color? custom;

  const ServerTint({this.named, this.custom});

  /// No colour at all: the server is drawn neutrally.
  static const ServerTint none = ServerTint();

  /// The tint [server] stores.
  factory ServerTint.of(ServerConfig server) => ServerTint(
    named: server.color,
    custom: parseServerCustomColor(server.customColor),
  );

  /// A custom colour, with the named accent it is nearest to kept beside it
  /// so a build without this field still draws something chosen.
  factory ServerTint.custom(Color color) =>
      ServerTint(named: nearestServerColor(color), custom: color);

  bool get isNone => named == null && custom == null;

  /// The two field values a `ServerConfig` stores for this tint: the inverse
  /// of [ServerTint.of], so an editor holds one tint and writes both.
  ({ServerColor? color, String? customColor}) get stored => (
    color: named,
    customColor: custom == null ? null : formatServerCustomColor(custom!),
  );

  @override
  bool operator ==(Object other) =>
      other is ServerTint && other.named == named && other.custom == custom;

  @override
  int get hashCode => Object.hash(named, custom);
}

/// The stored `#RRGGBB` form of [color], which is what
/// `normalizeServerCustomColor` accepts back. Alpha is dropped: the badge fill
/// is opaque by design.
String formatServerCustomColor(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// The colour a stored `customColor` names, or null when it is absent or not
/// something this build will draw — the same rule the protocol applies on
/// read, so a value that reached the record is the only thing that parses.
Color? parseServerCustomColor(String? stored) {
  final hex = normalizeServerCustomColor(stored);
  if (hex == null) return null;
  return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
}

/// Below this saturation a colour is a grey, whatever its hue says.
const double _greyThreshold = 0.35;

/// The named accent closest to [color], for the older-build stand-in a custom
/// colour keeps beside it.
///
/// Judged by hue, which is what the named accents differ by — except slate,
/// which is the only one that is barely a hue at all and so takes every grey.
/// The threshold sits above slate's own saturation (0.28), so slate maps to
/// slate, and below every other seed's (violet's 0.57 is the next).
ServerColor nearestServerColor(Color color) {
  final hsv = HSVColor.fromColor(color);
  if (hsv.saturation < _greyThreshold) return ServerColor.slate;
  ServerColor? nearest;
  var nearestDistance = double.infinity;
  for (final MapEntry(key: candidate, value: seed) in _seeds.entries) {
    if (candidate == ServerColor.slate) continue;
    final delta = (HSVColor.fromColor(seed).hue - hsv.hue).abs() % 360;
    final distance = delta > 180 ? 360 - delta : delta;
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = candidate;
    }
  }
  return nearest!;
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
  ServerIcon.server => const _Glyph(
    Icons.dns_outlined, 'Server', keywords: 'dns host machine node',
  ),
  ServerIcon.cloud => const _Glyph(
    Icons.cloud_outlined, 'Cloud', keywords: 'vps provider',
  ),
  ServerIcon.cluster => const _Glyph(
    Icons.hub_outlined, 'Cluster', keywords: 'kubernetes k8s swarm nodes',
  ),
  ServerIcon.vm => const _Glyph(
    Icons.memory, 'Virtual machine', keywords: 'vm vps kvm hypervisor guest',
  ),
  ServerIcon.desktop => const _Glyph(
    Icons.desktop_windows_outlined, 'Desktop', keywords: 'workstation pc',
  ),
  ServerIcon.laptop => const _Glyph(
    Icons.laptop_outlined, 'Laptop', keywords: 'notebook',
  ),
  ServerIcon.device => const _Glyph(
    Icons.developer_board, 'Board',
    // 'device' was this glyph's label before the rename.
    keywords: 'device raspberry pi arduino embedded iot',
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
    Icons.warehouse_outlined,
    'Data centre',
    keywords: 'rack colo dc data center',
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
    Icons.storage_outlined,
    'Database',
    keywords: 'db sql psql postgres mysql redis',
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
    Icons.terminal,
    'Shell',
    // 'terminal' was this glyph's label before the rename; without it the
    // obvious search term matches nothing at all.
    keywords: 'terminal console command',
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
    Icons.bug_report_outlined,
    'Testing',
    keywords: 'bug qa test debug',
  ),
  ServerIcon.construction => const _Glyph(
    Icons.construction_outlined, 'Work in progress', keywords: 'wip unfinished',
  ),
  ServerIcon.rocket => const _Glyph(
    Icons.rocket_launch_outlined, 'Production',
    keywords: 'prod live deploy release',
  ),
  ServerIcon.speed => const _Glyph(
    Icons.speed,
    'Performance',
    keywords: 'speed benchmark load fast',
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
    Icons.factory_outlined, 'Factory', keywords: 'plant industrial works',
  ),
  ServerIcon.cottage => const _Glyph(
    Icons.cottage_outlined, 'Cabin', keywords: 'cottage retreat',
  ),
  ServerIcon.public => const _Glyph(
    Icons.public_outlined, 'Public', keywords: 'internet global world',
  ),
  ServerIcon.star => const _Glyph(
    Icons.star_outline,
    'Favourite',
    keywords: 'star starred favorite important',
  ),
  ServerIcon.favourite => const _Glyph(
    Icons.favorite_outline, 'Loved', keywords: 'heart favourite favorite',
  ),
  ServerIcon.bolt => const _Glyph(
    Icons.bolt, 'Fast', keywords: 'bolt quick lightning',
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
    Icons.warning_amber_outlined, 'Careful', keywords: 'caution warning danger fragile',
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
    Icons.eco_outlined, 'Green', keywords: 'eco leaf efficient',
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
  // 'server' too: the default row draws the same glyph as ServerIcon.server,
  // so hiding it from that search hides the reset option exactly when
  // someone is browsing server-shaped icons.
  if (icon == null) return terms.every('default server'.contains);
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

/// The hue [color] is generated from, for a picker that starts from it.
Color serverColorSeed(ServerColor color) => _seeds[color]!;

/// A human name for [color], for the editor's swatch tooltips.
String serverColorLabel(ServerColor? color) => color == null
    ? 'None'
    : '${color.name[0].toUpperCase()}${color.name.substring(1)}';

/// The vertical line that carries a server's colour, down the leading edge of
/// the row it marks.
///
/// The badge beside this carries the same colour as its fill, but an image
/// mark covers that edge to edge — so the line is the carrier all three kinds
/// of mark keep, and the fill is the echo that two of them add to it. It is
/// also the shape the eye can run down a list, which a tinted square among
/// the marks is not: that is why the colour is not left to the fill alone.
class ServerAccentBar extends StatelessWidget {
  final ServerTint tint;

  /// How tall the line is. The caller sizes it against the row it sits in:
  /// inside a `ListTile`'s leading slot, which sizes itself to its child, the
  /// bar cannot take the row's own height.
  final double height;

  /// Defaulted to the badge's own edge, so a bar and a badge left at their
  /// defaults — the editor's preview — are one aligned block whatever that
  /// edge becomes.
  const ServerAccentBar({
    super.key,
    required this.tint,
    this.height = ServerBadge.defaultSize,
  });

  /// The slot is this wide whether or not a line is drawn in it, so the marks
  /// of coloured and uncoloured servers still line up in one column.
  static const double width = 4;

  @override
  Widget build(BuildContext context) {
    final accent = serverAccent(context, tint);
    return SizedBox(
      width: width,
      height: height,
      child: accent == null
          ? null
          : DecoratedBox(
              decoration: BoxDecoration(
                // The saturated line tone rather than the pastel container
                // one: four pixels of a fill tone is a smudge, not a mark.
                color: accent.line,
                borderRadius: BorderRadius.circular(width / 2),
              ),
            ),
    );
  }
}

/// A server's mark on its colour: what says *which* box a row is.
///
/// Takes a tint and a [ServerMark] rather than a whole [ServerConfig] so the
/// editor can preview a pair the user is still choosing, before there is a
/// config to preview them on.
///
/// The tint is the fill under the mark. An image mark covers it, and gets no
/// treatment of its own for that: [ServerAccentBar] is the carrier that does
/// not depend on what the mark is, so the fill can simply be whatever shows
/// through — all of it under a glyph, none of it under a logo.
class ServerBadge extends StatelessWidget {
  final ServerTint tint;
  final ServerMark mark;

  /// What the badge announces, overriding the mark's own description.
  ///
  /// An imported image has nothing to describe itself with, so it otherwise
  /// falls back to the name of the glyph stored beside it — and two servers
  /// with different logos and the same fallback then read identically, in the
  /// widget whose whole job is telling them apart. A caller holding the server
  /// passes its name.
  final String? semanticsLabel;
  final double size;

  /// The badge's edge in the list, and what every other default here is
  /// measured from.
  static const double defaultSize = 32;

  const ServerBadge({
    super.key,
    required this.tint,
    required this.mark,
    this.semanticsLabel,
    this.size = defaultSize,
  });

  /// Convenience for the common case: a built-in glyph, or none.
  ServerBadge.glyph({
    super.key,
    required this.tint,
    required ServerIcon? icon,
    this.semanticsLabel,
    this.size = defaultSize,
  }) : mark = ServerGlyphMark(icon);

  /// The corner radius, as a share of the side. [ServerAvatar] draws its ring
  /// concentric with this, so the two are kept in one place.
  static const double cornerRatio = 0.28;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = serverAccent(context, tint);
    final radius = BorderRadius.circular(size * cornerRatio);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // The container tone rather than the bar's line tone: this is a fill
        // behind a glyph, and a saturated one would leave the glyph to fight
        // it. With no colour at all, the neutral surface tone — so an
        // untagged server still lines up with a tagged one instead of leaving
        // a hole where the badge would be.
        color: accent?.container ?? scheme.surfaceContainerHighest,
        borderRadius: radius,
      ),
      // Clipped so an imported image takes the badge's own shape rather than
      // squaring off the corner the fill rounds.
      child: ClipRRect(
        borderRadius: radius,
        child: Center(child: _content(context, accent, scheme)),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    ServerAccent? accent,
    ColorScheme scheme,
  ) {
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
          // An Image only gets a Semantics node when given a label, so
          // without this the badge announces nothing. The fallback glyph's
          // name is the last resort: it describes the image only by accident,
          // which is why a caller that knows the server passes its name.
          semanticLabel: semanticsLabel ?? serverIconLabel(fallback),
          // Bytes that will not decode fall back to the glyph stored beside
          // them, which is what an older build would have drawn anyway.
          errorBuilder: (_, _, _) => _glyphIcon(fallback, accent, scheme),
        );
      case ServerEmojiMark(:final emoji):
        // Labelled like the other two branches. Painted rather than left to a
        // Text, which would announce the bare emoji — and which a screen
        // reader renders its own way, saying nothing about which server this
        // is.
        return Semantics(
          label: semanticsLabel ?? emoji,
          excludeSemantics: true,
          child: CustomPaint(
            size: Size.square(size),
            painter: _EmojiBadgePainter(
              emoji: emoji,
              fontSize: size * 0.56,
              textScaler: MediaQuery.textScalerOf(context),
              locale: Localizations.maybeLocaleOf(context),
            ),
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
    // is telling servers apart. The caller's label wins where there is one —
    // the glyph name describes the drawing, not which server it stands for.
    semanticLabel: semanticsLabel ?? serverIconLabel(icon),
  );
}

/// A [ServerBadge] ringed while the server has a *connected* session.
///
/// The ring replaces the dot that used to sit in the badge's corner. A dot
/// changed only its colour between "nothing open" and "connected", which is
/// the difference the eye is worst at picking out of a list; a ring changes
/// the badge's *silhouette*. Only a live connection draws one — a connecting
/// or dropped session frames nothing, so a border on the badge always means
/// "connected" — and it sits outside the badge with a gap, so it stays a
/// separate mark on any fill, over any image, and beside the accent bar its
/// row carries.
///
/// The two answer one question between them — *which* box, and is it up —
/// which is why they are drawn together rather than side by side in a row
/// that can be as narrow as 200 logical pixels. The ring keeps its own
/// tooltip, so nothing is lost by the arrangement.
class ServerAvatar extends StatelessWidget {
  final ServerConfig server;
  final TerminalStatus connection;

  /// Whether the server has a session open at all. [connection] reports
  /// `disconnected` both for a session that dropped and for none having been
  /// opened, and the ring is drawn only while one is actually connected.
  final bool hasSession;

  /// The badge's edge, or null for the list's usual [ServerBadge.defaultSize].
  /// The compact server row passes a smaller one; the ring and the gap inside
  /// it scale with it, so the whole mark stays in proportion.
  final double? size;

  /// The ring's stroke and the gap between it and the badge, at the default
  /// badge size. The stroke has a floor so a compact row's ring is still a
  /// line rather than a haze.
  static const double _ringWidth = 2;
  static const double _gap = 2;
  static const double _minRingWidth = 1.5;

  /// The side of the whole mark — badge plus ring and gap on both edges — for
  /// a badge of [badgeSize]. Exposed because the row draws its accent bar to
  /// this height, so the colour and the mark it belongs to read as one block
  /// at either density.
  static double extentFor(double badgeSize) {
    final scale = badgeSize / ServerBadge.defaultSize;
    return badgeSize + 2 * (_ringStroke(scale) + _gap * scale);
  }

  static double _ringStroke(double scale) =>
      (_ringWidth * scale).clamp(_minRingWidth, double.infinity);

  const ServerAvatar({
    super.key,
    required this.server,
    required this.connection,
    required this.hasSession,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final badgeSize = size ?? ServerBadge.defaultSize;
    final scale = badgeSize / ServerBadge.defaultSize;
    final ringWidth = _ringStroke(scale);
    final gap = _gap * scale;
    final extent = extentFor(badgeSize);
    // The ring is drawn concentric with the badge's corners, which is what
    // makes it read as a frame around this shape rather than a circle
    // dropped over a square.
    final ringRadius = badgeSize * ServerBadge.cornerRatio + gap + ringWidth;
    return SizedBox(
      // The full extent is reserved whether or not a ring is drawn, so a
      // session opening does not shift every row below it.
      width: extent,
      height: extent,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Decorative, like the tab strip's: every row that shows this puts
          // the server's label in its title, and labelling the badge too
          // would announce the name twice. The parameter stays for a caller
          // that has no such sibling.
          ExcludeSemantics(
            child: ServerBadge(
              tint: ServerTint.of(server),
              mark: server.mark,
              size: badgeSize,
            ),
          ),
          if (hasSession && connection == TerminalStatus.connected)
            Positioned.fill(
              child: _SessionRing(width: ringWidth, radius: ringRadius),
            ),
        ],
      ),
    );
  }
}

/// The frame a connected session draws around its badge, with the tooltip the
/// status dot used to carry.
class _SessionRing extends StatelessWidget {
  final double width;
  final double radius;

  const _SessionRing({required this.width, required this.radius});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'connected',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: StatusColors.online(context),
            width: width,
          ),
        ),
      ),
    );
  }
}

/// Paints an emoji with its *ink* centred in the badge rather than its
/// layout box.
///
/// A `Text` centres the cluster's advance: a system emoji font's bearings and
/// line metrics leave the glyph visibly left-and-low inside it (the font is
/// whatever the host ships, so the offset cannot be nudged out by hand). The
/// cluster's measured bounds — where its pixels actually land — are centred
/// instead, and only ever shrunk to fit: a wide cluster (a family emoji, a
/// flag) keeps all of itself rather than being sliced by the badge's clip,
/// and a single emoji stays at its natural size.
class _EmojiBadgePainter extends CustomPainter {
  final String emoji;

  /// Sized against the glyph the emoji replaces rather than the badge, so an
  /// emoji and an icon sit at the same visual weight. No colour: an emoji
  /// carries its own, and tinting it would either do nothing or ruin it.
  final double fontSize;
  final TextScaler textScaler;
  final Locale? locale;

  const _EmojiBadgePainter({
    required this.emoji,
    required this.fontSize,
    required this.textScaler,
    required this.locale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(text: emoji, style: TextStyle(fontSize: fontSize)),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      locale: locale,
    )..layout();
    canvas.save();
    try {
      final ink = _inkRect(painter);
      final scale = _fit(ink, size);
      canvas
        ..translate(
          size.width / 2 - ink.center.dx * scale,
          size.height / 2 - ink.center.dy * scale,
        )
        ..scale(scale);
      painter.paint(canvas, Offset.zero);
    } finally {
      canvas.restore();
      painter.dispose();
    }
  }

  /// How much [ink] is shrunk to fit inside [bounds]: 1 unless it is wider or
  /// taller than the badge.
  static double _fit(Rect ink, Size bounds) {
    if (ink.isEmpty) return 1;
    final fit = math.min(
      bounds.width / ink.width,
      bounds.height / ink.height,
    );
    return fit.isFinite ? math.min(1, fit) : 1;
  }

  /// Where the cluster's pixels land inside [painter]'s coordinate space.
  ///
  /// The tight selection box is the first answer — it hugs the glyph rather
  /// than the em square — then the grapheme cluster's own layout bounds, and
  /// finally the whole layout box, so a font that reports nothing useful
  /// still centres something rather than throwing.
  static Rect _inkRect(TextPainter painter) {
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: painter.plainText.length),
    );
    if (boxes.isNotEmpty) {
      return boxes
          .map((box) => box.toRect())
          .reduce((a, b) => a.expandToInclude(b));
    }
    final layout = Offset.zero & painter.size;
    return painter
            .getClosestGlyphForOffset(layout.center)
            ?.graphemeClusterLayoutBounds ??
        layout;
  }

  @override
  bool shouldRepaint(_EmojiBadgePainter old) =>
      old.emoji != emoji ||
      old.fontSize != fontSize ||
      old.textScaler != textScaler ||
      old.locale != locale;
}
