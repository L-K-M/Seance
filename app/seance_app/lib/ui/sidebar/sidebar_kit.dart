// Ported from Poltergeist app/poltergeist_app/lib/ui/sidebar/sidebar_kit.dart
// @ 58605fa, with Séance's changes ported back, Poltergeist's
// SidebarStatusDot adopted (4ba7851) and its row densities since; see
// docs/POLTERGEIST.md ("The sidebar kit").

/// The sibling sidebar kit (10 §5, §10's contract): the section header,
/// the row in its two densities, the filter field, and the bottom bar
/// Séance and Poltergeist both draw.
///
/// Portable on purpose — Séance copies this file verbatim. It imports
/// Flutter, the chrome tokens (read through [_chrome], the one function a
/// sibling rewrites to point at its own ThemeExtension of the same token
/// names), and the ported [MiddleEllipsisText] (the same path in both
/// apps). Every string arrives through [SidebarKitStrings] and every
/// behavior through a callback: no service, store, or model type crosses
/// into this file, so the two apps can share it without sharing a domain.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import '../../theme.dart';
import '../middle_ellipsis_text.dart';

/// The chrome tokens the kit paints with — the adoption seam (see the
/// library doc). Nothing else in this file names the app.
SeanceChrome _chrome(BuildContext context) => SeanceChrome.of(context);

/// The pill inset from the rail's edges: rows, headers, and the filter
/// field share it so every pill in the rail lines up. The content inside
/// a pill starts at the density's [_RowMetrics.contentInset].
const double _railInset = 6;

/// The accent line down a coloured row's leading edge
/// ([SidebarRow.accent]): as wide as the `ServerAccentBar` both apps'
/// rows carried before the kit, and as tall as the mark it belongs to.
const double _accentWidth = 4;

/// The corner of the badge a connected ring frames (`ServerBadge`'s
/// corner ratio in both apps), so the ring reads as a frame around that
/// shape rather than as a box dropped over it.
const double _markCornerRatio = 0.28;

/// A blocked dot's bar, as fractions of the dot: long and thick enough to
/// read as the no-entry sign at 7 px.
const double _blockedBarLength = 0.65;
const double _blockedBarThickness = 0.25;

const double _sectionHeaderExtent = 22;
const double _sectionLeadIn = 4;
const double _bottomBarExtent = 30;
const double _pillRadius = 6;

/// The touch counterparts of the desktop tokens above. A header is a
/// button (it folds its section), so on touch it grows toward a finger's
/// target without taking a full row's height; the icon buttons and the
/// filter field grow the same way.
const double _touchSectionHeaderExtent = 36;
const double _touchBottomBarExtent = 48;
const double _touchIconButtonExtent = 40;
const double _filterExtent = 26;
const double _touchFilterExtent = 40;

/// A comfortable desktop group's disclosure row: a row among 52 px rows,
/// so it grows past a section caption's 22 px.
const double _comfortableNestedHeaderExtent = 32;

/// The [SidebarKitLayout.list] tokens beyond its row metrics: Material's
/// 48 dp subheader, 24 dp icons in 48 dp targets, and the list item's
/// rounder pill.
const double _listHeaderExtent = 48;
const double _listInset = 8;
const double _listIconButtonExtent = 48;
const double _listIconSize = 24;
const double _listPillRadius = 12;

/// A row's geometry at one density on one kind of screen: the box its
/// mark gets, the dot composed into that box's corner, the gaps around
/// them, and the ring and line drawn about the mark without moving it.
@immutable
final class _RowMetrics {
  const _RowMetrics({
    required this.rowExtent,
    required this.markExtent,
    required this.glyphSize,
    required this.dotExtent,
    required this.dotRing,
    required this.hollowStroke,
    required this.contentInset,
    required this.markGap,
    required this.depthIndent,
    required this.ringStroke,
    required this.ringGap,
    required this.accentGap,
  });

  /// The row's height before text scaling. Null is the chrome's
  /// `sidebarRowExtent`: the compact rail keeps the theme's token.
  final double? rowExtent;

  /// The box a host's mark fills ([sidebarMarkExtent]), and the size a
  /// bare glyph takes inside it ([sidebarGlyphSize]).
  final double markExtent;
  final double glyphSize;

  /// The composed status dot and its cut-out ring.
  final double dotExtent;
  final double dotRing;

  /// The stroke of a [SidebarDotStyle.ring] dot: heavy enough that the
  /// hole reads as deliberate rather than as a dot drawn badly.
  final double hollowStroke;

  /// From the pill's leading edge to the mark, and to a header's title.
  final double contentInset;

  /// Between the mark and the title.
  final double markGap;

  /// One nesting level (a group's members) indents by this much.
  final double depthIndent;

  /// The connected ring ([SidebarRow.markRing]) and the air between it
  /// and the mark.
  final double ringStroke;
  final double ringGap;

  /// Between the accent line ([SidebarRow.accent]) and the mark's box:
  /// the ring fits in it with air on both sides.
  final double accentGap;
}

/// The compact desktop rail (10 §5): one 26 px line, an 18 px mark with a
/// 7 px dot, and the accent line flush with the pill's edge.
const _compactDesktop = _RowMetrics(
  rowExtent: null,
  markExtent: 18,
  glyphSize: 16,
  dotExtent: 7,
  dotRing: 1.5,
  hollowStroke: 1.75,
  contentInset: 8,
  markGap: 6,
  depthIndent: 8,
  ringStroke: 1.5,
  ringGap: 1,
  accentGap: 4,
);

/// Compact on touch: Material's 48 dp rows, the mark and dot scaled with
/// them.
const _compactTouch = _RowMetrics(
  rowExtent: null,
  markExtent: 24,
  glyphSize: 20,
  dotExtent: 9,
  dotRing: 1.5,
  hollowStroke: 1.75,
  contentInset: 8,
  markGap: 12,
  depthIndent: 8,
  ringStroke: 1.5,
  ringGap: 1,
  accentGap: 4,
);

/// Comfortable on desktop: the proportions of Séance's old comfortable
/// rows (a 32 px badge, its ring 2 px out with 2 px of air) at the
/// desktop ramp's 14 px title over a 12 px second line.
const _comfortableDesktop = _RowMetrics(
  rowExtent: 52,
  markExtent: 32,
  glyphSize: 20,
  dotExtent: 10,
  dotRing: 2,
  hollowStroke: 2.25,
  contentInset: 12,
  markGap: 10,
  depthIndent: 16,
  ringStroke: 2,
  ringGap: 2,
  accentGap: 8,
);

/// Comfortable on a touch rail (a tablet): the desktop's mark in a row
/// sized for the touch ramp's 16 sp title.
const _comfortableTouch = _RowMetrics(
  rowExtent: 56,
  markExtent: 32,
  glyphSize: 22,
  dotExtent: 10,
  dotRing: 2,
  hollowStroke: 2.25,
  contentInset: 12,
  markGap: 12,
  depthIndent: 16,
  ringStroke: 2,
  ringGap: 2,
  accentGap: 8,
);

/// The [SidebarKitLayout.list]: Material's list item (56 dp whether or
/// not it has a second line, a 40 dp leading mark 16 dp from the edge and
/// from the text). The composed dot grows with the mark so it still reads
/// at arm's length, and the accent line sits in the margin before the
/// pill, where Material's 16 dp inset leaves it room.
const _listMetrics = _RowMetrics(
  rowExtent: 56,
  markExtent: 40,
  glyphSize: 24,
  dotExtent: 12,
  dotRing: 2,
  hollowStroke: 2.5,
  contentInset: 8,
  markGap: 16,
  depthIndent: 16,
  ringStroke: 2,
  ringGap: 2,
  accentGap: 8,
);

/// How the kit lays itself out, set once on [SidebarKitScope]. [rail] is
/// the sidebar column: the spec's pixel sizes on desktop, Material's
/// 48 dp rows on touch. [list] is a phone's full-screen home list, drawn
/// like the platform's own lists so it matches the screens it opens:
/// 56 dp rows under a 40 dp mark, a 16 sp title, and Material list
/// subheaders (48 dp, 14 sp in the accent colour, as authored rather than
/// in caps) for the sections.
enum SidebarKitLayout { rail, list }

/// How roomy the rows are, set on [SidebarKitScope] from the user's
/// choice (both apps persist it on the device; comfortable by default).
/// [compact] is the one-line rail (10 §5): 26 px rows under an 18 px
/// mark, secondary facts in the tooltip. [comfortable] is the two-line
/// row both apps drew before the kit: a 32 px mark, a larger title, and
/// the row's [SidebarRow.subtitle] spelled out beneath it, with the
/// section chrome (chevrons, counts, the "+", the row's "⋮") drawn at
/// rest rather than on hover. [SidebarKitLayout.list] is comfortable by
/// definition.
enum SidebarKitDensity { compact, comfortable }

/// A phone home at [density]: the Android list when comfortable, the
/// rail's one-line touch rows when compact.
SidebarKitLayout sidebarHomeLayout(SidebarKitDensity density) =>
    switch (density) {
      SidebarKitDensity.comfortable => SidebarKitLayout.list,
      SidebarKitDensity.compact => SidebarKitLayout.rail,
    };

/// Whether the scope asks for [SidebarKitLayout.list].
bool _list(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<SidebarKitScope>()?.layout ==
    SidebarKitLayout.list;

/// Whether rows draw comfortably: the scope's density, which a list
/// always is. Outside a scope, the scope's default.
bool _comfortable(BuildContext context) {
  final scope = context.dependOnInheritedWidgetOfExactType<SidebarKitScope>();
  return (scope?.density ?? SidebarKitDensity.comfortable) ==
      SidebarKitDensity.comfortable;
}

/// Whether the kit sizes for fingers. The same split the chrome tokens
/// make (desktop platforms get the spec's pixel sizes, everything else
/// Material's touch sizes), read from the theme so a test or capture can
/// render either posture on one host.
bool _touch(BuildContext context) => switch (Theme.of(context).platform) {
  TargetPlatform.macOS ||
  TargetPlatform.linux ||
  TargetPlatform.windows => false,
  _ => true,
};

/// The row geometry for the scope's layout and density on this platform.
_RowMetrics _metrics(BuildContext context) {
  if (_list(context)) return _listMetrics;
  final touch = _touch(context);
  return _comfortable(context)
      ? (touch ? _comfortableTouch : _comfortableDesktop)
      : (touch ? _compactTouch : _compactDesktop);
}

/// The box a row's leading mark should fill: compact 18 px on desktop
/// (10 §5) and 24 on touch, comfortable 32, 40 in the list layout. Hosts
/// size their mark widgets with it so a badge fills the slot the kit
/// reserves.
double sidebarMarkExtent(BuildContext context) => _metrics(context).markExtent;

/// The size a bare glyph mark (an icon with no badge behind it) takes
/// inside [sidebarMarkExtent]: compact 16 px on desktop and 20 on touch,
/// comfortable 20 and 22, 24 in the list layout.
double sidebarGlyphSize(BuildContext context) => _metrics(context).glyphSize;

/// The pill's corner radius (and the focus ring's) for the layout.
double _radius(BuildContext context) =>
    _list(context) ? _listPillRadius : _pillRadius;

/// The copy the kit renders, injected so the kit authors none.
@immutable
final class SidebarKitStrings {
  const SidebarKitStrings({
    required this.sectionSemantics,
    required this.showSection,
    required this.hideSection,
    required this.filterHint,
    required this.filterClear,
    required this.addMenu,
    required this.settings,
    required this.rowMenu,
    required this.compactRows,
    required this.comfortableRows,
  });

  /// A header's merged announcement: its title and member count.
  final String Function(String title, int count) sectionSemantics;

  /// The chevron's tooltip while collapsed / expanded.
  final String showSection;
  final String hideSection;

  final String filterHint;
  final String filterClear;

  /// The bottom bar's "+" and gear tooltips.
  final String addMenu;
  final String settings;

  /// The tooltip of a row's visible "⋮" ([SidebarRow.showMenuButton]).
  final String rowMenu;

  /// The [SidebarDensitySwitch]'s two halves, as tooltips (and so what a
  /// screen reader announces for each).
  final String compactRows;
  final String comfortableRows;
}

/// Provides [SidebarKitStrings] to every kit widget below it, and the
/// surface the rows sit on.
class SidebarKitScope extends InheritedWidget {
  const SidebarKitScope({
    super.key,
    required this.strings,
    this.background,
    this.layout = SidebarKitLayout.rail,
    this.density = SidebarKitDensity.comfortable,
    required super.child,
  }) : assert(
         // The list is the comfortable phone home; a compact home is the
         // rail (see [sidebarHomeLayout]).
         layout != SidebarKitLayout.list ||
             density == SidebarKitDensity.comfortable,
       );

  final SidebarKitStrings strings;

  /// The rail, or a phone's home list (see [SidebarKitLayout]).
  final SidebarKitLayout layout;

  /// Compact or comfortable rows (see [SidebarKitDensity]).
  final SidebarKitDensity density;

  /// What is painted behind the rows, when it is not the rail's own
  /// `sidebarBackground` (a phone's full-screen home list sits on the
  /// page surface). The status dot's cut-out ring takes this colour, so
  /// a wrong one draws a visible halo instead of a cut.
  final Color? background;

  static SidebarKitStrings of(BuildContext context) => _scope(context).strings;

  /// The layout the nearest scope asks for, so a host's own marks can
  /// draw for it (a disc in [SidebarKitLayout.list]).
  static SidebarKitLayout layoutOf(BuildContext context) =>
      _scope(context).layout;

  /// The density the nearest scope asks for, so a host can pick its marks
  /// and the [SidebarDensitySwitch] can show the current choice.
  static SidebarKitDensity densityOf(BuildContext context) =>
      _scope(context).density;

  static SidebarKitScope _scope(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SidebarKitScope>();
    assert(scope != null);
    return scope!;
  }

  @override
  bool updateShouldNotify(SidebarKitScope oldWidget) =>
      !identical(oldWidget.strings, strings) ||
      oldWidget.background != background ||
      oldWidget.layout != layout ||
      oldWidget.density != density;
}

/// The colour behind the rail's rows (see [SidebarKitScope.background]).
Color _railBackground(BuildContext context) =>
    SidebarKitScope._scope(context).background ??
    _chrome(context).sidebarBackground;

/// Focus-ring bookkeeping for the rail's focusable rows and headers: a
/// ring shows only while focus is being driven from the keyboard (10 §5).
///
/// Two facts decide it. [FocusManager.highlightMode] must be traditional
/// (a touch interaction turns rings off app-wide), and the focus must not
/// have come from this widget's own click: the rail moves focus with the
/// pointer so Enter and the arrows act on the row last touched, but a
/// clicked row wearing a ring the pointer did not ask for is noise. The
/// first key the focused widget sees hands the ring back.
mixin _KeyboardFocusRing<T extends StatefulWidget> on State<T> {
  final focusNode = FocusNode();
  bool _pointerFocused = false;

  bool get showFocusRing =>
      focusNode.hasFocus &&
      !_pointerFocused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    focusNode.dispose();
    super.dispose();
  }

  void _onHighlightMode(FocusHighlightMode mode) {
    if (mounted) setState(() {});
  }

  /// A pointer took focus: no ring until a key arrives.
  ///
  /// Through setState: a widget that already holds focus gets no focus
  /// change from the request, and that change is what would otherwise
  /// repaint it without its ring.
  void focusFromPointer() {
    if (!_pointerFocused) setState(() => _pointerFocused = true);
    focusNode.requestFocus();
  }

  /// Call first from the key handler: the keyboard is driving now.
  void noteKey() {
    if (!_pointerFocused) return;
    setState(() => _pointerFocused = false);
  }

  /// Focus left or arrived by traversal: a later arrival is keyboard's
  /// unless a pointer says otherwise.
  void onFocusChanged(bool focused) {
    setState(() {
      if (!focused) _pointerFocused = false;
    });
  }
}

/// The keyboard focus ring (and a row's drop-into outline): painted as a
/// foreground decoration so it never moves what it frames.
BoxDecoration _focusRing(Color color, double radius) => BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: color, width: 2),
);

/// A row's height after text scaling: the token is the floor, and scaled
/// text grows the row rather than clipping (D20).
double _scaledExtent(BuildContext context, double extent) =>
    MediaQuery.textScalerOf(context).scale(extent).clamp(extent, 4 * extent);

// ── Menus ────────────────────────────────────────────────────────────

/// One entry of a row's verbs, rendered as a desktop context menu or a
/// touch bottom sheet from the same list (10 §5's "the same verbs").
sealed class SidebarMenuEntry {
  const SidebarMenuEntry();
}

final class SidebarMenuAction extends SidebarMenuEntry {
  const SidebarMenuAction({
    required this.label,
    required this.onSelected,
    this.key,
    this.icon,
  });

  final String label;

  /// Null renders the verb disabled — visible, so the menu's shape does
  /// not shift with state, but inert.
  final VoidCallback? onSelected;
  final Key? key;
  final IconData? icon;
}

final class SidebarMenuDivider extends SidebarMenuEntry {
  const SidebarMenuDivider();
}

final class SidebarMenuSubmenu extends SidebarMenuEntry {
  const SidebarMenuSubmenu({
    required this.label,
    required this.children,
    this.key,
  });

  final String label;
  final List<SidebarMenuEntry> children;
  final Key? key;
}

/// [entries] without leading, trailing, or doubled dividers — verbs gate
/// on seams, and a gated-out group must not leave its separator behind.
List<SidebarMenuEntry> _tidy(List<SidebarMenuEntry> entries) {
  final result = <SidebarMenuEntry>[];
  for (final entry in entries) {
    if (entry is SidebarMenuDivider &&
        (result.isEmpty || result.last is SidebarMenuDivider)) {
      continue;
    }
    result.add(entry);
  }
  while (result.isNotEmpty && result.last is SidebarMenuDivider) {
    result.removeLast();
  }
  return result;
}

/// The desktop rendering of [entries] for a [MenuAnchor].
///
/// [firstFocus], when given, is attached to the first enabled verb, so a
/// menu opened from the keyboard can put focus inside itself: a menu's own
/// arrow, Enter and Esc handling only works while focus is in it.
List<Widget> sidebarMenuWidgets(
  List<SidebarMenuEntry> entries, {
  FocusNode? firstFocus,
}) {
  final tidy = _tidy(entries);
  final first = tidy.firstWhere(
    (entry) => entry is SidebarMenuAction && entry.onSelected != null,
    orElse: () => const SidebarMenuDivider(),
  );
  return [
    for (final entry in tidy)
      switch (entry) {
        SidebarMenuAction() => MenuItemButton(
          key: entry.key,
          focusNode: identical(entry, first) ? firstFocus : null,
          leadingIcon: entry.icon == null ? null : Icon(entry.icon, size: 16),
          onPressed: entry.onSelected,
          child: Text(entry.label),
        ),
        SidebarMenuDivider() => const Divider(height: 1),
        SidebarMenuSubmenu() => SubmenuButton(
          key: entry.key,
          menuChildren: sidebarMenuWidgets(entry.children),
          child: Text(entry.label),
        ),
      },
  ];
}

/// A row's verbs as custom semantics actions (TalkBack's and VoiceOver's
/// actions menus), with its hover [action]: a screen reader's cursor is
/// no pointer, so a verb that waits for a hover or a right-click would be
/// out of its reach. Enabled top-level verbs only — a submenu's live in
/// the menu and the sheet — and a hover action repeating a verb of the
/// same name is one action. Null when there is none, so a verbless row
/// does not advertise an empty actions menu.
Map<CustomSemanticsAction, VoidCallback>? _semanticsActions(
  List<SidebarMenuEntry>? verbs,
  SidebarRowAction? action,
) {
  final actions = <CustomSemanticsAction, VoidCallback>{
    for (final entry in verbs ?? const <SidebarMenuEntry>[])
      if (entry case SidebarMenuAction(:final label, :final onSelected?))
        CustomSemanticsAction(label: label): onSelected,
    if (action != null)
      CustomSemanticsAction(label: action.tooltip): action.onPressed,
  };
  return actions.isEmpty ? null : actions;
}

/// The touch rendering of [entries]: a modal bottom sheet headed by
/// [title], with [subtitle] (a row's address or path) under it. A
/// submenu's verbs list under its label, indented — a sheet has no room
/// for flyouts.
Future<void> showSidebarMenuSheet(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<SidebarMenuEntry> entries,
}) {
  final chrome = _chrome(context);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // Sized to its verbs rather than capped at 9/16 of the screen: a
    // server's seven verbs would otherwise scroll on a phone, with Delete
    // out of sight. The list still scrolls past the screen's height.
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      List<Widget> tiles(List<SidebarMenuEntry> list, int depth) => [
        for (final entry in _tidy(list))
          ...switch (entry) {
            SidebarMenuAction() => [
              ListTile(
                key: entry.key,
                contentPadding: EdgeInsetsDirectional.only(
                  start: 24.0 + depth * 16,
                  end: 24,
                ),
                leading: entry.icon == null ? null : Icon(entry.icon),
                title: Text(entry.label),
                enabled: entry.onSelected != null,
                onTap: entry.onSelected == null
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        entry.onSelected!();
                      },
              ),
            ],
            SidebarMenuDivider() => [const Divider(height: 1)],
            SidebarMenuSubmenu() => [
              Padding(
                padding: EdgeInsetsDirectional.only(
                  start: 24.0 + depth * 16,
                  top: 12,
                  bottom: 4,
                ),
                child: Text(
                  entry.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: chrome.secondaryText,
                  ),
                ),
              ),
              ...tiles(entry.children, depth + 1),
            ],
          },
      ];
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: chrome.secondaryText,
                      ),
                    ),
                ],
              ),
            ),
            ...tiles(entries, 0),
          ],
        ),
      );
    },
  );
}

// ── Section header ───────────────────────────────────────────────────

/// A collapsible header: a top-level section (DEVICES, FAVORITES, …) in
/// 11 px semibold caps, or — [nested] — a group's disclosure row among
/// the rows. Both are one merged semantics node (header + button +
/// expanded state + "title, N items"), toggle on tap, Enter/Space, and
/// the expandable pattern's ←/→ (a ← or → with nothing to fold or unfold
/// is swallowed, so focus stays in the sidebar), and move focus with ↑/↓.
///
/// Compact, the count shows only while collapsed, and the chevron and the
/// optional "+" appear on hover or keyboard focus (a nested row keeps its
/// chevron: it is the disclosure affordance there). Comfortable, on touch,
/// and in the list layout all three stay drawn. The "+" is Tab's stop
/// after its header but not the arrows': they walk headers and rows.
class SidebarSectionHeader extends StatefulWidget {
  const SidebarSectionHeader({
    super.key,
    required this.title,
    required this.count,
    required this.collapsed,
    required this.onToggle,
    this.nested = false,
    this.depth = 0,
    this.onAdd,
    this.addTooltip,
    this.addKey,
    this.dropHighlight = false,
    this.headerKey,
    this.status,
  });

  final String title;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;

  /// A status dot beside the count, for live rows the header keeps out of
  /// view: a folded group's connected server, or one a filter hides. The
  /// host decides when; null draws none.
  final SidebarStatusDot? status;

  /// A group's disclosure row rather than a section header.
  final bool nested;
  final int depth;

  /// The header's "+" — null draws none.
  final VoidCallback? onAdd;
  final String? addTooltip;
  final Key? addKey;

  /// A drag hovers the header and it will accept the drop.
  final bool dropHighlight;

  /// Keys the header's own box (tests address headers by it).
  final Key? headerKey;

  @override
  State<SidebarSectionHeader> createState() => _SidebarSectionHeaderState();
}

/// Ctrl, Alt or Meta is held, so an arrow is the app's chord (a pane
/// focus or Go Back binding), not a step in the sidebar.
bool _appChordHeld() {
  final keys = HardwareKeyboard.instance;
  return keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed;
}

class _SidebarSectionHeaderState extends State<SidebarSectionHeader>
    with _KeyboardFocusRing {
  bool _hovering = false;

  /// The "+". It skips traversal, so the arrows (and a row's ↑ from
  /// below) pass it by; the header hands it Tab instead (see [_onKey]).
  final _addFocus = FocusNode(
    debugLabel: 'SidebarSectionHeader add',
    skipTraversal: true,
  );

  /// The "+" holds focus: it stays drawn, or hiding it would drop the
  /// focus it just took and leave the keyboard nowhere.
  bool _addFocused = false;

  @override
  void dispose() {
    _addFocus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    noteKey();
    final key = event.logicalKey;
    final keys = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.tab &&
        widget.onAdd != null &&
        !keys.isShiftPressed &&
        !keys.isControlPressed &&
        !keys.isMetaPressed &&
        !keys.isAltPressed) {
      _addFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
    }
    // ← and → belong to the disclosure even when there is nothing to fold
    // or unfold: let through, directional traversal would carry focus out
    // of the sidebar into the pane beside it (Finder keeps it here).
    final horizontal =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    // A chord goes on to the app's shortcuts, held or not, and folds
    // nothing on the way.
    if (horizontal && _appChordHeld()) return KeyEventResult.ignored;
    // Repeats may drive traversal, never activation — a held key must
    // not flicker the collapse state.
    if (event is KeyRepeatEvent) {
      return horizontal ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        // Right expands, Left collapses: a blind toggle on either would
        // read inverted half the time.
        (key == LogicalKeyboardKey.arrowRight && widget.collapsed) ||
        (key == LogicalKeyboardKey.arrowLeft && !widget.collapsed)) {
      widget.onToggle();
      return KeyEventResult.handled;
    }
    return horizontal ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Keys on the "+": the arrows rejoin the walk it sits outside of. Tab
  /// and Shift+Tab need nothing here — traversal moves on from the node
  /// that holds focus even though it skips traversal itself.
  KeyEventResult _onAddKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      focusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _addFocus.nextFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final chrome = _chrome(context);
    final theme = Theme.of(context);
    final strings = SidebarKitScope.of(context);
    final focused = showFocusRing;
    final touch = _touch(context);
    final list = _list(context);
    final comfortable = _comfortable(context);
    final metrics = _metrics(context);
    // Touch has no hover to reveal on, so the chevron and the "+" stay
    // drawn there: hidden until a hover that never comes, the disclosure
    // would have no visible affordance at all. Comfortable rows, the
    // list's included, draw them at rest too: that density trades the
    // rail's quiet for every affordance in view.
    final revealed =
        _hovering || focused || _addFocused || touch || comfortable;
    final nested = widget.nested;
    final inset = list ? _listInset : _railInset;
    final radius = _radius(context);
    // A nested disclosure row is a row among rows, so on touch it takes a
    // row's height, and among comfortable desktop rows it grows with them;
    // a section caption grows only toward a finger's target. A list's
    // subheader is Material's 48 dp, and its lead-in is part of it.
    final lineExtent = list
        ? _listHeaderExtent
        : touch
        ? (nested ? chrome.sidebarRowExtent : _touchSectionHeaderExtent)
        : (nested && comfortable
              ? _comfortableNestedHeaderExtent
              : _sectionHeaderExtent);
    final leadIn = nested || list ? 0.0 : _sectionLeadIn;
    final Color? fill = widget.dropHighlight
        ? chrome.hoverFill
        : (nested && _hovering ? chrome.hoverFill : null);
    final background = _railBackground(context);

    final titleStyle = switch ((list, nested)) {
      (true, false) => theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.primary,
      ),
      (true, true) => theme.textTheme.titleSmall?.copyWith(
        color: chrome.secondaryText,
      ),
      (false, true) =>
        (comfortable ? theme.textTheme.bodyMedium : theme.textTheme.labelMedium)
            ?.copyWith(
              color: chrome.secondaryText,
              fontWeight: FontWeight.w600,
            ),
      (false, false) => theme.textTheme.labelSmall?.copyWith(
        color: chrome.secondaryText,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
    };
    final chevron = Icon(
      widget.collapsed ? Icons.chevron_right : Icons.expand_more,
      size: list ? _listIconSize : (touch ? 18 : (comfortable ? 16 : 14)),
      color: chrome.secondaryText,
    );
    final count = Text(
      widget.count.toString(),
      style: (list ? theme.textTheme.labelLarge : theme.textTheme.labelSmall)
          ?.copyWith(
            color: chrome.secondaryText,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
    );

    final header = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      // The focus node's own semantics (focusable) merge into the
      // header's: outside it they would be a second, unlabeled stop for
      // a screen reader before the header itself.
      child: MergeSemantics(
        child: Focus(
          focusNode: focusNode,
          onKeyEvent: _onKey,
          onFocusChange: onFocusChanged,
          child: Semantics(
            header: true,
            button: true,
            expanded: !widget.collapsed,
            label: strings.sectionSemantics(widget.title, widget.count),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // The pointer moves focus with it, like the rows: the keys
              // act on the header last touched.
              onTap: () {
                focusFromPointer();
                widget.onToggle();
              },
              child: ExcludeSemantics(
                child: Container(
                  key: widget.headerKey,
                  height: _scaledExtent(context, lineExtent + leadIn),
                  margin: EdgeInsets.symmetric(horizontal: inset),
                  // A section header leads in with 4 px of air above its
                  // 22 px line; the "+" below centres on the same line.
                  padding: EdgeInsetsDirectional.only(
                    start:
                        metrics.contentInset +
                        widget.depth * metrics.depthIndent,
                    // A list's chevron centres over the rows' "⋮".
                    end: list ? 8 : 4,
                    top: leadIn,
                  ),
                  alignment: AlignmentDirectional.centerStart,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  // Painted over the content, not around it: a border in
                  // the decoration insets the child by its width, and the
                  // title would jump 2 px whenever focus arrived.
                  foregroundDecoration: focused
                      ? _focusRing(theme.colorScheme.primary, radius)
                      : null,
                  child: Row(
                    children: [
                      if (nested) ...[
                        SizedBox(
                          width: sidebarMarkExtent(context),
                          child: Center(child: chevron),
                        ),
                        SizedBox(width: metrics.markGap),
                      ],
                      Expanded(
                        child: Text(
                          // Caps are visual only; the announcement keeps
                          // the authored spelling (a screen reader spells
                          // out all-caps words letter by letter). A list's
                          // subheader keeps it on screen too.
                          nested || list
                              ? widget.title
                              : widget.title.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                      ),
                      if (widget.status case final status?) ...[
                        _StatusDotMark(
                          dot: status,
                          metrics: metrics,
                          cutOut: fill == null
                              ? background
                              : Color.alphaBlend(fill, background),
                        ),
                        SizedBox(width: list ? 8 : 4),
                      ],
                      if (widget.collapsed || comfortable || touch) ...[
                        count,
                        SizedBox(width: list ? 8 : 4),
                      ],
                      if (!nested)
                        SizedBox(
                          width: list ? _listIconSize : 18,
                          child: Visibility.maintain(
                            visible: revealed,
                            child: Tooltip(
                              message: widget.collapsed
                                  ? strings.showSection
                                  : strings.hideSection,
                              child: chevron,
                            ),
                          ),
                        ),
                      // The "+" floats over this slot (see below), so
                      // the count and chevron never slide under it.
                      if (widget.onAdd != null)
                        SizedBox(
                          width: list
                              ? _listIconButtonExtent
                              : (touch ? _touchIconButtonExtent + 2 : 24),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // The "+" sits OUTSIDE the merged node and the toggle gesture: it
    // announces and acts on itself.
    final onAdd = widget.onAdd;
    if (onAdd == null) return header;
    return Stack(
      children: [
        header,
        PositionedDirectional(
          end: list ? _listInset : _railInset + 2,
          top: leadIn,
          bottom: 0,
          child: Visibility(
            visible: revealed,
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            maintainInteractivity: false,
            // Focusable while hidden, so a header that holds focus without
            // drawing it (a click's) can still hand Tab over: the focus it
            // takes is what draws it.
            maintainFocusability: true,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onAddKey,
              onFocusChange: (focused) => setState(() => _addFocused = focused),
              // Its own exit as well as its enter: the "+" sits over the
              // header, so the header's region has already reported the
              // pointer gone, and a pointer leaving from here straight onto
              // a row would otherwise leave the header revealed.
              child: MouseRegion(
                onEnter: (_) => setState(() => _hovering = true),
                onExit: (_) => setState(() => _hovering = false),
                child: Center(
                  child: _KitIconButton(
                    key: widget.addKey,
                    icon: Icons.add,
                    tooltip: widget.addTooltip,
                    focusNode: _addFocus,
                    onPressed: onAdd,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A borderless 22 px icon button (40 on touch, Material's 48 in the list
/// layout) with the hover capsule the header uses.
class _KitIconButton extends StatelessWidget {
  const _KitIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.focusNode,
    this.fill,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final FocusNode? focusNode;

  /// A resting fill, for the chosen half of a [SidebarDensitySwitch]; its
  /// icon then takes the full text colour rather than the secondary one.
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final chrome = _chrome(context);
    final touch = _touch(context);
    final list = _list(context);
    final extent = list
        ? _listIconButtonExtent
        : (touch ? _touchIconButtonExtent : 22.0);
    return IconButton(
      iconSize: list ? _listIconSize : (touch ? 20 : 15),
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: extent, height: extent),
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        hoverColor: chrome.hoverFill,
        backgroundColor: fill,
        // A list's icon buttons ink as Material's circles.
        shape: list
            ? const CircleBorder()
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_pillRadius),
              ),
      ),
      tooltip: tooltip,
      focusNode: focusNode,
      onPressed: onPressed,
      icon: Icon(
        icon,
        color: fill == null
            ? chrome.secondaryText
            : Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

// ── Row ──────────────────────────────────────────────────────────────

/// How a row was activated: a pointer click may carry modifier keys the
/// app reads (new tab, other pane); a keyboard activation is always the
/// plain open.
enum SidebarActivation { pointer, keyboard }

/// Where a drag hovering the row would land, drawn by the row.
enum SidebarDropIndicator { none, before, after, into }

/// A row's hover-only trailing verb (eject, disconnect).
@immutable
final class SidebarRowAction {
  const SidebarRowAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Key? key;
}

/// How a row's status dot is drawn. [solid] is live truth (connected,
/// connecting, failed); [ring] is a weaker, observed fact — a probe that
/// found the host reachable (or not) with nothing connected — so it reads
/// as a lesser mark of the same colour rather than a second dot.
/// [blocked] is a refusal the user has to act on (a host key that no
/// longer matches): the solid dot crossed by a bar cut out of it, the
/// no-entry sign, so it never passes for a plain failure of the same
/// colour. The bar takes the cut-out colour, so it stands off the dot by
/// the same contrast the dot stands off the row.
enum SidebarDotStyle { solid, ring, blocked }

/// The one status dot a row composes into its mark's corner (10 §5): its
/// colour and how it is drawn, as one value — a style without a colour
/// cannot be expressed.
@immutable
final class SidebarStatusDot {
  const SidebarStatusDot(this.color, {this.style = SidebarDotStyle.solid});

  final Color color;
  final SidebarDotStyle style;

  @override
  bool operator ==(Object other) =>
      other is SidebarStatusDot &&
      other.color == color &&
      other.style == style;

  @override
  int get hashCode => Object.hash(color, style);
}

/// One sidebar row (10 §5): a [mark] with ONE composed status dot, a
/// middle-ellipsis [title], and trailing tabular [trailingText] or, on
/// hover, [hoverAction]. Compact, it is the chrome's `sidebarRowExtent`
/// tall (26 px on desktop) with an 18 px mark, a 7 px dot and a 13 px
/// title; comfortable, it is 52 px (56 on touch) with a 32 px mark, a
/// larger title, and [subtitle] beneath it (see [SidebarKitDensity]).
/// An [accent] line and a connected [markRing] frame the mark in either.
///
/// Hover fills; [selected] draws the rounded pill (the location the active
/// pane shows) with a semibold title; the focus ring shows only in keyboard
/// mode. Right-click opens [menuEntries] at the pointer, Shift+F10 and the
/// Menu key open them from the keyboard, and a touch long-press opens the
/// same verbs as a bottom sheet. The arrows walk rows and headers; the
/// hover action and the "⋮" are Tab's stops after their row, not the
/// arrows', like a header's "+".
class SidebarRow extends StatefulWidget {
  const SidebarRow({
    super.key,
    required this.mark,
    required this.title,
    this.status,
    this.italic = false,
    this.subtitle,
    this.trailingIcon,
    this.trailingText,
    this.hoverAction,
    this.showMenuButton,
    this.accent,
    this.markRing,
    this.selected = false,
    this.depth = 0,
    this.onActivate,
    this.menuEntries,
    this.tooltip,
    this.semanticLabel,
    this.dropIndicator = SidebarDropIndicator.none,
  });

  /// The leading glyph or badge, sized to [sidebarMarkExtent].
  final Widget mark;
  final String title;

  /// The one status dot composed into the mark's corner; null draws none.
  final SidebarStatusDot? status;

  /// Unsaved rows (a live Quick Connect session) set their title in
  /// italics.
  final bool italic;

  /// A second, secondary line under the title (an address, a path, a
  /// state). Hosts always pass it; the kit draws it only when comfortable
  /// (compact rows keep to one line and leave the fact to [tooltip]), and
  /// the long-press sheet shows it under its title either way.
  final String? subtitle;

  /// A small standing mark before the trailing text (a server kept off
  /// sync). Decorative: the host says what it means in [tooltip] and
  /// [semanticLabel].
  final IconData? trailingIcon;
  final String? trailingText;
  final SidebarRowAction? hoverAction;

  /// Draws a trailing "⋮" that opens [menuEntries]: the visible way to the
  /// verbs where a long-press or right-click is not discoverable enough. It
  /// opens the sheet on touch, the menu elsewhere. Null follows the kit:
  /// drawn when comfortable or on touch, left to the right-click and the
  /// keyboard on a compact desktop rail. A host passes true or false to
  /// decide for itself.
  final bool? showMenuButton;

  /// The row's own colour (a server's), as a 4 px rounded line leading
  /// the mark, as tall as it. It takes no room: marks and titles line up
  /// with rows that have none. Null draws none.
  final Color? accent;

  /// A ring around the mark in this colour: a server with a live
  /// connection, beside the status dot. Drawn about the mark's box, so it
  /// moves nothing when it comes and goes. Null draws none.
  final Color? markRing;
  final bool selected;

  /// Nesting under a group disclosure row.
  final int depth;

  /// Null renders the row inert: no button role, no activation.
  final void Function(SidebarActivation how)? onActivate;

  /// The row's verbs. Null means no menu.
  final List<SidebarMenuEntry> Function()? menuEntries;

  /// Secondary facts (a path, an address, a failure), on hover in either
  /// density: a compact row has no other place for them, and a
  /// comfortable row's second line has room for only one.
  final String? tooltip;

  /// The announced label; defaults to [title]. Rows fold dynamic state
  /// ("connected") in here because their visuals are excluded.
  final String? semanticLabel;
  final SidebarDropIndicator dropIndicator;

  @override
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> with _KeyboardFocusRing {
  final _menu = MenuController();
  final _contentKey = GlobalKey();

  /// The menu's first enabled verb, for a keyboard-opened menu to focus.
  final _firstVerbFocus = FocusNode(debugLabel: 'SidebarRow first verb');

  /// The row's own buttons: the hover action and the "⋮". They skip
  /// traversal, so the arrows (and the next row's ↑) walk rows past them,
  /// as they pass a header's "+"; the row hands them Tab instead (see
  /// [_onKey] and [_onButtonKey]).
  final _actionFocus = FocusNode(
    debugLabel: 'SidebarRow action',
    skipTraversal: true,
  );
  final _menuButtonFocus = FocusNode(
    debugLabel: 'SidebarRow menu button',
    skipTraversal: true,
  );
  bool _hovering = false;
  PointerDeviceKind? _lastPointer;

  /// Where a Mac Control-click went down, while its tap is pending: AppKit
  /// makes that click the secondary one, so it opens the verbs rather
  /// than activating the row.
  Offset? _controlClickAt;

  @override
  void dispose() {
    _firstVerbFocus.dispose();
    _actionFocus.dispose();
    _menuButtonFocus.dispose();
    super.dispose();
  }

  void _activate(SidebarActivation how) => widget.onActivate?.call(how);

  /// The trailing "⋮" is drawn (see [SidebarRow.showMenuButton]).
  bool get _drawsMenuButton =>
      widget.menuEntries != null &&
      (widget.showMenuButton ?? (_comfortable(context) || _touch(context)));

  /// Tab or Shift+Tab with no other modifier: Control, Meta and Alt make
  /// it a chord the app binds (switching tabs), not a step between stops.
  static bool _isTab(LogicalKeyboardKey key, {required bool shift}) {
    final keys = HardwareKeyboard.instance;
    return key == LogicalKeyboardKey.tab &&
        keys.isShiftPressed == shift &&
        !keys.isControlPressed &&
        !keys.isMetaPressed &&
        !keys.isAltPressed;
  }

  /// Keys on the row's own buttons. The arrows rejoin the walk the
  /// buttons sit outside of: ↑ returns to the row and ↓ moves on past it
  /// (traversal moves on from the node that holds focus even though it
  /// skips traversal itself). Tab and Shift+Tab step between the two;
  /// past them, traversal needs nothing here.
  KeyEventResult _onButtonKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      focusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (_actionFocus.hasPrimaryFocus &&
        _drawsMenuButton &&
        _isTab(key, shift: false)) {
      _menuButtonFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (_menuButtonFocus.hasPrimaryFocus &&
        widget.hoverAction != null &&
        _isTab(key, shift: true)) {
      _actionFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Opens the verbs. From the keyboard ([focusFirst]) focus moves into the
  /// menu once it has mounted, or Shift+F10 would open a menu the keyboard
  /// could not operate: the arrows would still walk the rows behind it.
  void _openMenu({Offset? position, bool focusFirst = false}) {
    if (widget.menuEntries == null) return;
    _menu.open(position: position);
    if (!focusFirst) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _menu.isOpen) _firstVerbFocus.requestFocus();
    });
  }

  void _openSheet() {
    final entries = widget.menuEntries;
    if (entries == null) return;
    unawaited(
      showSidebarMenuSheet(
        context,
        title: widget.title,
        subtitle: widget.subtitle,
        entries: entries(),
      ),
    );
  }

  /// The "⋮": the sheet on touch; on desktop the menu, dropped from the
  /// button's own corner rather than from the row's leading edge.
  void _openFromButton(BuildContext buttonContext) {
    if (_touch(context)) {
      _openSheet();
      return;
    }
    // The menu hands focus to the row; a click asked for no ring.
    focusFromPointer();
    final button = buttonContext.findRenderObject() as RenderBox?;
    final row = _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (button == null || row == null) {
      _openMenu();
      return;
    }
    _openMenu(
      position: row.globalToLocal(
        button.localToGlobal(button.size.bottomLeft(Offset.zero)),
      ),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    _lastPointer = event.kind;
    final controlClick =
        Theme.of(context).platform == TargetPlatform.macOS &&
        event.buttons == kPrimaryButton &&
        HardwareKeyboard.instance.isControlPressed;
    _controlClickAt = controlClick ? event.localPosition : null;
  }

  void _onTap() {
    final at = _controlClickAt;
    _controlClickAt = null;
    if (at == null) {
      _activate(SidebarActivation.pointer);
      return;
    }
    _openMenu(position: at);
  }

  void _onLongPress() {
    // A slow mouse click is still a click; only touch (and stylus) turn
    // a long-press into the verb sheet.
    if (_lastPointer == PointerDeviceKind.mouse ||
        _lastPointer == PointerDeviceKind.trackpad) {
      _activate(SidebarActivation.pointer);
      return;
    }
    _openSheet();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // Keys bubble up from focused descendants: the row's own buttons and,
    // through the anchor's overlay, the open menu's verbs. Enter on one of
    // those belongs to it, not to the row.
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    noteKey();
    final key = event.logicalKey;
    // A menu opened by right-click leaves focus on the row (the anchor's
    // child focus): Esc closes it, and an arrow steps into it, as a
    // desktop context menu does.
    if (_menu.isOpen) {
      if (key == LogicalKeyboardKey.escape) {
        _menu.close();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowUp) {
        _firstVerbFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    // Tab reaches the row's buttons, which the arrows pass by: the hover
    // action first (a focused row draws it), then the "⋮".
    if (_isTab(key, shift: false)) {
      final button = widget.hoverAction != null
          ? _actionFocus
          : (_drawsMenuButton ? _menuButtonFocus : null);
      if (button != null) {
        button.requestFocus();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
    }
    // A row has nothing to open sideways, and a ← or → let through would
    // carry focus out of the sidebar by directional traversal (Finder
    // keeps it here, as the headers do). A chord is the app's.
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      return _appChordHeld() ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      // Repeats may drive traversal, never activation; an inert row
      // must not swallow the key.
      if (event is KeyRepeatEvent || widget.onActivate == null) {
        return KeyEventResult.ignored;
      }
      _activate(SidebarActivation.keyboard);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 &&
            HardwareKeyboard.instance.isShiftPressed)) {
      if (event is KeyRepeatEvent || widget.menuEntries == null) {
        return KeyEventResult.ignored;
      }
      _openMenu(focusFirst: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final chrome = _chrome(context);
    final theme = Theme.of(context);
    final focused = showFocusRing;
    final selected = widget.selected;
    final dropInto = widget.dropIndicator == SidebarDropIndicator.into;
    final background = _railBackground(context);

    final Color? fill = selected
        ? chrome.inactiveSelectionFill
        : (_hovering || dropInto ? chrome.hoverFill : null);
    // The dot's ring reads as a cut-out: it takes the colour actually
    // behind the mark, pill or hover included.
    final ring = fill == null ? background : Color.alphaBlend(fill, background);
    final list = _list(context);
    final comfortable = _comfortable(context);
    final metrics = _metrics(context);
    final radius = _radius(context);

    final titleStyle =
        (comfortable ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium)
            ?.copyWith(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              fontStyle: widget.italic ? FontStyle.italic : FontStyle.normal,
            );
    final captionStyle =
        (comfortable ? theme.textTheme.labelMedium : theme.textTheme.labelSmall)
            ?.copyWith(
              color: chrome.secondaryText,
              fontFeatures: const [FontFeature.tabularFigures()],
            );
    final action = widget.hoverAction;
    final showAction = action != null && (_hovering || focused);
    final Widget? trailing = showAction
        ? Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onButtonKey,
            child: _KitIconButton(
              key: action.key,
              icon: action.icon,
              tooltip: action.tooltip,
              focusNode: _actionFocus,
              onPressed: action.onPressed,
            ),
          )
        : (widget.trailingText == null
              ? null
              : ExcludeSemantics(
                  child: Text(
                    widget.trailingText!,
                    maxLines: 1,
                    style: captionStyle,
                  ),
                ));
    final trailingIcon = widget.trailingIcon;
    final entries = widget.menuEntries;
    // Built once per frame: the menu and the row's semantics actions list
    // the same verbs.
    final verbs = entries?.call();
    final menuButton = _drawsMenuButton
        ? Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onButtonKey,
            child: Builder(
              builder: (buttonContext) => _KitIconButton(
                icon: Icons.more_vert,
                tooltip: SidebarKitScope.of(context).rowMenu,
                focusNode: _menuButtonFocus,
                onPressed: () => _openFromButton(buttonContext),
              ),
            ),
          )
        : null;

    // The kit, not the host, decides whether the second line shows, so
    // the two apps cannot drift apart on it.
    final subtitle = comfortable ? widget.subtitle : null;
    final Widget label = subtitle == null
        ? MiddleEllipsisText(widget.title, style: titleStyle)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MiddleEllipsisText(widget.title, style: titleStyle),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: chrome.secondaryText,
                ),
              ),
            ],
          );
    // A comfortable row is one height whether or not it has a second line,
    // like Material's list item: its mark leaves no room for less, and a
    // list whose rows change height reads as ragged.
    final extent = metrics.rowExtent ?? chrome.sidebarRowExtent;

    Widget content = Container(
      key: _contentKey,
      height: _scaledExtent(context, extent),
      margin: EdgeInsets.symmetric(horizontal: list ? _listInset : _railInset),
      padding: EdgeInsetsDirectional.only(
        start: metrics.contentInset + widget.depth * metrics.depthIndent,
        // A list's "⋮" target reaches the pill's edge, as a list item's
        // trailing icon button does.
        end: list && menuButton != null ? 0 : 4,
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
      ),
      // Over the content, as on the header: a decoration border would
      // shift the mark and title by its width while focused.
      foregroundDecoration: focused || dropInto
          ? _focusRing(theme.colorScheme.primary, radius)
          : null,
      // The painted parts are excluded one by one, not the whole row: the
      // row's label says what they show, but its buttons (the hover action,
      // the "⋮") announce and act on themselves.
      child: Row(
        children: [
          ExcludeSemantics(
            child: _SidebarMark(
              mark: widget.mark,
              dot: widget.status,
              cutOut: ring,
              accent: widget.accent,
              markRing: widget.markRing,
            ),
          ),
          SizedBox(width: metrics.markGap),
          Expanded(child: ExcludeSemantics(child: label)),
          if (trailingIcon != null) ...[
            const SizedBox(width: 6),
            Icon(
              trailingIcon,
              size: list ? 16 : (comfortable ? 14 : 12),
              color: chrome.secondaryText,
            ),
          ],
          if (trailing != null) ...[const SizedBox(width: 6), trailing],
          ?menuButton,
        ],
      ),
    );
    final tooltip = widget.tooltip;
    if (tooltip != null) {
      content = Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 700),
        // Hover still shows it (the mode never gates mice); touch's
        // long-press belongs to the verb sheet, not the tooltip.
        triggerMode: TooltipTriggerMode.manual,
        // The host folds what a screen reader needs into the label.
        excludeFromSemantics: true,
        child: content,
      );
    }
    if (widget.dropIndicator
        case SidebarDropIndicator.before || SidebarDropIndicator.after) {
      final line = Container(height: 2, color: theme.colorScheme.primary);
      content = Stack(
        children: [
          content,
          PositionedDirectional(
            start: list ? _listInset : _railInset,
            end: list ? _listInset : _railInset,
            top: widget.dropIndicator == SidebarDropIndicator.before ? 0 : null,
            bottom: widget.dropIndicator == SidebarDropIndicator.after
                ? 0
                : null,
            child: line,
          ),
        ],
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      // One node per row: the container sits outside the focus node, so
      // its focusable flag merges into the row rather than wrapping it in
      // a second, unlabeled stop for a screen reader.
      child: Semantics(
        container: true,
        button: widget.onActivate != null,
        selected: selected,
        label: widget.semanticLabel ?? widget.title,
        customSemanticsActions: _semanticsActions(verbs, action),
        child: Focus(
          focusNode: focusNode,
          onKeyEvent: _onKey,
          onFocusChange: onFocusChanged,
          // The detector's tap and long-press reach the row's node — an
          // announced button a screen reader cannot activate is WCAG
          // 4.1.2's failure.
          child: Listener(
            onPointerDown: _onPointerDown,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // The pointer moves focus with it: Enter and the arrows
              // keep working from the row the user last touched.
              onTapDown: (_) => focusFromPointer(),
              onTap: widget.onActivate == null ? null : _onTap,
              onTapCancel: () => _controlClickAt = null,
              // A right-click takes focus too, so Esc and the arrows reach
              // the menu it opens.
              onSecondaryTapDown: entries == null
                  ? null
                  : (_) => focusFromPointer(),
              onSecondaryTapUp: entries == null
                  ? null
                  : (details) => _openMenu(position: details.localPosition),
              onLongPress: entries == null && widget.onActivate == null
                  ? null
                  : _onLongPress,
              // The anchor's overlay sits here in the semantics tree, so
              // nothing above it may exclude semantics: an open menu's
              // verbs would have no nodes at all.
              child: verbs == null
                  ? content
                  : MenuAnchor(
                      controller: _menu,
                      // Focus returns to the row when the menu closes.
                      childFocusNode: focusNode,
                      menuChildren: sidebarMenuWidgets(
                        verbs,
                        firstFocus: _firstVerbFocus,
                      ),
                      child: content,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The mark with its one corner dot, ringed in the colour behind the row
/// so the dot reads as cut out of the mark (10 §5), and the two things
/// drawn about the mark without taking room from the row: the accent line
/// before it and the connected ring around it.
class _SidebarMark extends StatelessWidget {
  const _SidebarMark({
    required this.mark,
    required this.dot,
    required this.cutOut,
    this.accent,
    this.markRing,
  });

  final Widget mark;
  final SidebarStatusDot? dot;

  /// The colour behind the row: the dot's cut-out.
  final Color cutOut;
  final Color? accent;
  final Color? markRing;

  @override
  Widget build(BuildContext context) {
    final metrics = _metrics(context);
    final extent = metrics.markExtent;
    final list = _list(context);
    final dot = this.dot;
    final accent = this.accent;
    final markRing = this.markRing;
    final ringOutset = metrics.ringStroke + metrics.ringGap;
    return SizedBox(
      width: extent,
      height: extent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (accent != null)
            PositionedDirectional(
              start: -(metrics.accentGap + _accentWidth),
              top: 0,
              bottom: 0,
              width: _accentWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(_accentWidth / 2),
                ),
              ),
            ),
          Center(child: mark),
          // Concentric with the badge it frames: a circle round a list's
          // disc, a rounded square round the rail's badge.
          if (markRing != null)
            Positioned(
              left: -ringOutset,
              top: -ringOutset,
              right: -ringOutset,
              bottom: -ringOutset,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: list ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius: list
                      ? null
                      : BorderRadius.circular(
                          extent * _markCornerRatio + ringOutset,
                        ),
                  border: Border.all(
                    color: markRing,
                    width: metrics.ringStroke,
                  ),
                ),
              ),
            ),
          // On a list's round mark the corner puts the dot's centre on
          // the circle's edge: the avatar badge Material draws presence
          // with.
          if (dot != null)
            PositionedDirectional(
              end: -metrics.dotRing,
              bottom: -metrics.dotRing,
              child: _StatusDotMark(dot: dot, metrics: metrics, cutOut: cutOut),
            ),
        ],
      ),
    );
  }
}

/// One status dot at [metrics]' size inside a ring of [cutOut], the
/// colour behind it: composed into a row's mark, or standing beside a
/// header's count.
class _StatusDotMark extends StatelessWidget {
  const _StatusDotMark({
    required this.dot,
    required this.metrics,
    required this.cutOut,
  });

  final SidebarStatusDot dot;
  final _RowMetrics metrics;
  final Color cutOut;

  @override
  Widget build(BuildContext context) {
    final extent = metrics.dotExtent;
    final ring = metrics.dotRing;
    final Widget? inner = switch (dot.style) {
      SidebarDotStyle.solid => null,
      SidebarDotStyle.ring => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: dot.color, width: metrics.hollowStroke),
        ),
      ),
      SidebarDotStyle.blocked => Center(
        child: SizedBox(
          width: extent * _blockedBarLength,
          height: extent * _blockedBarThickness,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cutOut,
              borderRadius: BorderRadius.circular(
                extent * _blockedBarThickness / 2,
              ),
            ),
          ),
        ),
      ),
    };
    return Container(
      width: extent + 2 * ring,
      height: extent + 2 * ring,
      decoration: BoxDecoration(
        // A ring's hole shows the row, not the mark under it: the cut-out
        // colour fills it.
        color: dot.style == SidebarDotStyle.ring ? cutOut : dot.color,
        shape: BoxShape.circle,
        border: Border.all(color: cutOut, width: ring),
      ),
      child: inner,
    );
  }
}

// ── Filter field ─────────────────────────────────────────────────────

/// The rail's one filter field (10 §5): compact, Esc hands control back
/// through [onDismiss] (clear first, then close — the owner decides),
/// Enter runs [onSubmitted] (open the first match), and [countText]
/// ("3 of 12 · ↵ opens the first") reads on a line under the field while
/// a query is live: inside it, a hint that long would crowd out the query
/// at the rail's narrowest.
///
/// [query] is the owner's truth; the field follows it when it changes
/// elsewhere (a clear from the owner). [focusNode] is the owner's too, so
/// a command-registry chord can focus the field — including one that
/// mounts in the very frame the chord opened it.
class SidebarFilterField extends StatefulWidget {
  const SidebarFilterField({
    super.key,
    required this.query,
    required this.onChanged,
    required this.onDismiss,
    this.onSubmitted,
    this.countText,
    this.focusNode,
    this.fieldKey,
  });

  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onDismiss;
  final VoidCallback? onSubmitted;
  final String? countText;
  final FocusNode? focusNode;
  final Key? fieldKey;

  @override
  State<SidebarFilterField> createState() => _SidebarFilterFieldState();
}

class _SidebarFilterFieldState extends State<SidebarFilterField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.query,
  );
  @override
  void didUpdateWidget(SidebarFilterField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != _text.text) {
      _text.value = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chrome = _chrome(context);
    final theme = Theme.of(context);
    final touch = _touch(context);
    final small = touch
        ? theme.textTheme.bodyMedium
        : theme.textTheme.bodySmall;
    final count = widget.query.isEmpty ? null : widget.countText;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_railInset, 4, _railInset, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(context, small),
          if (count != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6, top: 2),
              child: Text(
                count,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: chrome.secondaryText,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _field(BuildContext context, TextStyle? small) {
    final chrome = _chrome(context);
    final strings = SidebarKitScope.of(context);
    final touch = _touch(context);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              widget.onDismiss();
              return null;
            },
          ),
        },
        child: SizedBox(
          height: _scaledExtent(
            context,
            touch ? _touchFilterExtent : _filterExtent,
          ),
          child: TextField(
            key: widget.fieldKey,
            controller: _text,
            focusNode: widget.focusNode,
            onChanged: widget.onChanged,
            onSubmitted: (_) => widget.onSubmitted?.call(),
            textInputAction: TextInputAction.go,
            style: small,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: chrome.capsuleFill,
              contentPadding: const EdgeInsets.symmetric(horizontal: 6),
              hintText: strings.filterHint,
              hintStyle: small?.copyWith(color: chrome.secondaryText),
              prefixIcon: Icon(
                Icons.search,
                size: touch ? 18 : 14,
                color: chrome.secondaryText,
              ),
              prefixIconConstraints: BoxConstraints(
                minWidth: touch ? 36 : 26,
                minHeight: 20,
              ),
              suffixIconConstraints: const BoxConstraints(minHeight: 20),
              suffixIcon: widget.query.isEmpty
                  ? null
                  : _KitIconButton(
                      icon: Icons.cancel,
                      tooltip: strings.filterClear,
                      onPressed: () => widget.onChanged(''),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(_pillRadius),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Bottom bar ───────────────────────────────────────────────────────

/// How the sync chip reads (10 §5): [normal] ("Synced · 2 min"),
/// [busy] (a spinner beside the label), [error] (red — a click retries),
/// [muted] (sync is off; a click leads to setting it up).
enum SidebarSyncTone { normal, busy, error, muted }

@immutable
final class SidebarSyncChipData {
  const SidebarSyncChipData({
    required this.label,
    required this.tone,
    this.tooltip,
    this.onPressed,
    this.key,
  });

  final String label;
  final SidebarSyncTone tone;
  final String? tooltip;
  final VoidCallback? onPressed;
  final Key? key;
}

/// The rail's 30 px foot (10 §5): a "+" menu of creation verbs, the sync
/// status chip, the [SidebarDensitySwitch], and the Settings gear.
///
/// At the rail's narrowest the chip gives way first: its label shortens,
/// then only its icon shows, then (a touch rail's 40 dp buttons at
/// 180 px) it steps aside, so the buttons never overflow.
class SidebarBottomBar extends StatefulWidget {
  const SidebarBottomBar({
    super.key,
    required this.addEntries,
    this.sync,
    this.onSettings,
    this.onDensityChanged,
    this.addKey,
    this.settingsKey,
    this.densityKey,
  });

  final List<SidebarMenuEntry> Function() addEntries;
  final SidebarSyncChipData? sync;
  final VoidCallback? onSettings;

  /// Draws the [SidebarDensitySwitch] before the gear, showing the scope's
  /// density; a pick reports here. Null draws none.
  final ValueChanged<SidebarKitDensity>? onDensityChanged;
  final Key? addKey;
  final Key? settingsKey;
  final Key? densityKey;

  @override
  State<SidebarBottomBar> createState() => _SidebarBottomBarState();
}

class _SidebarBottomBarState extends State<SidebarBottomBar> {
  final _addMenu = MenuController();

  @override
  Widget build(BuildContext context) {
    final chrome = _chrome(context);
    final strings = SidebarKitScope.of(context);
    final entries = widget.addEntries();
    return Container(
      height: _scaledExtent(
        context,
        _touch(context) ? _touchBottomBarExtent : _bottomBarExtent,
      ),
      padding: const EdgeInsets.symmetric(horizontal: _railInset),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: chrome.separator)),
      ),
      child: Row(
        children: [
          MenuAnchor(
            controller: _addMenu,
            menuChildren: sidebarMenuWidgets(entries),
            child: _KitIconButton(
              key: widget.addKey,
              icon: Icons.add,
              tooltip: strings.addMenu,
              onPressed: entries.isEmpty
                  ? null
                  : () => _addMenu.isOpen ? _addMenu.close() : _addMenu.open(),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: widget.sync == null
                ? const SizedBox.shrink()
                : _SyncSlot(data: widget.sync!),
          ),
          if (widget.onDensityChanged case final onChanged?) ...[
            SidebarDensitySwitch(key: widget.densityKey, onChanged: onChanged),
            const SizedBox(width: 2),
          ],
          if (widget.onSettings != null)
            _KitIconButton(
              key: widget.settingsKey,
              icon: Icons.settings_outlined,
              tooltip: strings.settings,
              onPressed: widget.onSettings,
            ),
        ],
      ),
    );
  }
}

/// The chip, or as much of it as the bar has room for.
class _SyncSlot extends StatelessWidget {
  const _SyncSlot({required this.data});

  final SidebarSyncChipData data;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (box.maxWidth < _syncChipIconOnlyWidth) return const SizedBox.shrink();
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: _SyncChip(
          data: data,
          iconOnly: box.maxWidth < _syncChipLabelWidth,
        ),
      );
    },
  );
}

/// The narrowest the sync chip reads at: with a few letters of its label,
/// and as its icon alone (the label then in its tooltip).
const double _syncChipLabelWidth = 54;
const double _syncChipIconOnlyWidth = 25;

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.data, this.iconOnly = false});

  final SidebarSyncChipData data;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final chrome = _chrome(context);
    final theme = Theme.of(context);
    final color = switch (data.tone) {
      SidebarSyncTone.error => theme.colorScheme.error,
      _ => chrome.secondaryText,
    };
    final Widget lead = switch (data.tone) {
      SidebarSyncTone.busy => SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
      ),
      SidebarSyncTone.error => Icon(Icons.sync_problem, size: 13, color: color),
      SidebarSyncTone.muted => Icon(Icons.cloud_off, size: 13, color: color),
      SidebarSyncTone.normal => Icon(
        Icons.cloud_done_outlined,
        size: 13,
        color: color,
      ),
    };
    final Widget chip = TextButton(
      key: data.key,
      onPressed: data.onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 22),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        foregroundColor: color,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_pillRadius),
        ),
      ),
      child: iconOnly
          ? Semantics(label: data.label, child: lead)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                lead,
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    data.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: color,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
    );
    // An icon alone, or a label the slot ellipsizes, keeps the whole
    // label within reach of a pointer.
    return Tooltip(message: data.tooltip ?? data.label, child: chip);
  }
}

/// The rows' two densities as one capsule: a compact half and a
/// comfortable half (the icons Séance's old app-bar switch used), the
/// current one filled with the selection pill's tone. Each half is a
/// button a screen reader hears as selected or not in a mutually
/// exclusive group, named by [SidebarKitStrings.compactRows] and
/// [SidebarKitStrings.comfortableRows]; a tap on the other half reports
/// it through [onChanged].
///
/// [value] is the density shown; null reads the nearest
/// [SidebarKitScope]'s. It reads its strings from that scope, so a host
/// placing it outside one (a phone home's app bar) wraps it in one.
class SidebarDensitySwitch extends StatelessWidget {
  const SidebarDensitySwitch({super.key, required this.onChanged, this.value});

  final ValueChanged<SidebarKitDensity> onChanged;
  final SidebarKitDensity? value;

  @override
  Widget build(BuildContext context) {
    final chrome = _chrome(context);
    final strings = SidebarKitScope.of(context);
    final current = value ?? SidebarKitScope.densityOf(context);
    Widget half(SidebarKitDensity density) {
      final selected = density == current;
      // One node per half: the button, its tooltip for a name, and the
      // selection it reports.
      return MergeSemantics(
        child: Semantics(
          selected: selected,
          inMutuallyExclusiveGroup: true,
          child: _KitIconButton(
            icon: switch (density) {
              SidebarKitDensity.compact => Icons.density_small,
              SidebarKitDensity.comfortable => Icons.density_medium,
            },
            tooltip: switch (density) {
              SidebarKitDensity.compact => strings.compactRows,
              SidebarKitDensity.comfortable => strings.comfortableRows,
            },
            fill: selected ? chrome.inactiveSelectionFill : null,
            onPressed: () {
              if (!selected) onChanged(density);
            },
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: chrome.separator),
        borderRadius: BorderRadius.circular(_radius(context) + 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final density in SidebarKitDensity.values) half(density),
        ],
      ),
    );
  }
}
