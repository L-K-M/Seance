// Ported from Poltergeist app/poltergeist_app/lib/ui/sidebar/sidebar_kit.dart
// @ 58605fa; see docs/POLTERGEIST.md ("The sidebar kit").

/// The sibling sidebar kit (10 §5, §10's contract): the section header,
/// the one-line row, the filter field, and the bottom bar Séance and
/// Poltergeist both draw.
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

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import '../middle_ellipsis_text.dart';

/// The chrome tokens the kit paints with — the adoption seam (see the
/// library doc). Nothing else in this file names the app.
SeanceChrome _chrome(BuildContext context) => SeanceChrome.of(context);

/// The pill inset from the rail's edges and the content padding inside
/// it: rows, headers, and the filter field share these so every leading
/// edge in the rail lines up.
const double _railInset = 6;
const double _contentInset = 8;

/// One nesting level (a favorite group's members) indents by this much.
const double _depthIndent = 8;

/// The leading mark's box and the composed status dot (10 §5).
const double _markExtent = 18;
const double _dotExtent = 7;
const double _dotRing = 1.5;

const double _sectionHeaderExtent = 22;
const double _sectionLeadIn = 4;
const double _bottomBarExtent = 30;
const double _pillRadius = 6;

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
}

/// Provides [SidebarKitStrings] to every kit widget below it.
class SidebarKitScope extends InheritedWidget {
  const SidebarKitScope({
    super.key,
    required this.strings,
    required super.child,
  });

  final SidebarKitStrings strings;

  static SidebarKitStrings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SidebarKitScope>();
    assert(scope != null);
    return scope!.strings;
  }

  @override
  bool updateShouldNotify(SidebarKitScope oldWidget) =>
      !identical(oldWidget.strings, strings);
}

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
  void focusFromPointer() {
    _pointerFocused = true;
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
List<Widget> sidebarMenuWidgets(List<SidebarMenuEntry> entries) => [
  for (final entry in _tidy(entries))
    switch (entry) {
      SidebarMenuAction() => MenuItemButton(
        key: entry.key,
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

/// The touch rendering of [entries]: a modal bottom sheet headed by
/// [title]. A submenu's verbs list under its label, indented — a sheet
/// has no room for flyouts.
Future<void> showSidebarMenuSheet(
  BuildContext context, {
  required String title,
  required List<SidebarMenuEntry> entries,
}) {
  final chrome = _chrome(context);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
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
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
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
/// the expandable pattern's ←/→, and move focus with ↑/↓.
///
/// The count shows only while collapsed; the chevron and the optional
/// "+" appear on hover or keyboard focus (a nested row keeps its
/// chevron: it is the disclosure affordance there).
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
  });

  final String title;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;

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

class _SidebarSectionHeaderState extends State<SidebarSectionHeader>
    with _KeyboardFocusRing {
  bool _hovering = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    noteKey();
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
    }
    // Repeats may drive traversal, never activation — a held key must
    // not flicker the collapse state.
    if (event is KeyRepeatEvent) return KeyEventResult.ignored;
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
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final chrome = _chrome(context);
    final theme = Theme.of(context);
    final strings = SidebarKitScope.of(context);
    final focused = showFocusRing;
    final revealed = _hovering || focused;
    final nested = widget.nested;

    final titleStyle = nested
        ? theme.textTheme.labelMedium?.copyWith(
            color: chrome.secondaryText,
            fontWeight: FontWeight.w600,
          )
        : theme.textTheme.labelSmall?.copyWith(
            color: chrome.secondaryText,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          );
    final chevron = Icon(
      widget.collapsed ? Icons.chevron_right : Icons.expand_more,
      size: 14,
      color: chrome.secondaryText,
    );
    final count = Text(
      widget.count.toString(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: chrome.secondaryText,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

    final header = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Focus(
        focusNode: focusNode,
        onKeyEvent: _onKey,
        onFocusChange: onFocusChanged,
        child: MergeSemantics(
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
                  height: _scaledExtent(
                    context,
                    nested
                        ? _sectionHeaderExtent
                        : _sectionHeaderExtent + _sectionLeadIn,
                  ),
                  margin: const EdgeInsets.symmetric(horizontal: _railInset),
                  // A section header leads in with 4 px of air above its
                  // 22 px line; the "+" below centres on the same line.
                  padding: EdgeInsetsDirectional.only(
                    start: _contentInset + widget.depth * _depthIndent,
                    end: 4,
                    top: nested ? 0 : _sectionLeadIn,
                  ),
                  alignment: AlignmentDirectional.centerStart,
                  decoration: BoxDecoration(
                    color: widget.dropHighlight
                        ? chrome.hoverFill
                        : (nested && _hovering ? chrome.hoverFill : null),
                    borderRadius: BorderRadius.circular(_pillRadius),
                    border: focused
                        ? Border.all(color: theme.colorScheme.primary, width: 2)
                        : null,
                  ),
                  child: Row(
                    children: [
                      if (nested) ...[
                        SizedBox(
                          width: _markExtent,
                          child: Center(child: chevron),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          // Caps are visual only; the announcement keeps
                          // the authored spelling (a screen reader spells
                          // out all-caps words letter by letter).
                          nested ? widget.title : widget.title.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                      ),
                      if (widget.collapsed) ...[
                        count,
                        const SizedBox(width: 4),
                      ],
                      if (!nested)
                        SizedBox(
                          width: 18,
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
                      if (widget.onAdd != null) const SizedBox(width: 24),
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
          end: _railInset + 2,
          top: nested ? 0 : _sectionLeadIn,
          bottom: 0,
          child: Visibility(
            visible: revealed,
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            maintainInteractivity: false,
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovering = true),
              child: Center(
                child: _KitIconButton(
                  key: widget.addKey,
                  icon: Icons.add,
                  tooltip: widget.addTooltip,
                  onPressed: onAdd,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A borderless 20 px icon button with the hover capsule the header uses.
class _KitIconButton extends StatelessWidget {
  const _KitIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chrome = _chrome(context);
    return IconButton(
      iconSize: 15,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 22, height: 22),
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        hoverColor: chrome.hoverFill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_pillRadius),
        ),
      ),
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: chrome.secondaryText),
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

/// One sidebar row (10 §5): [SidebarRowExtent] tall, an 18 px [mark] with
/// ONE composed 7 px status dot, a 13 px middle-ellipsis [title], and
/// trailing 11 px tabular [trailingText] or, on hover, [hoverAction].
///
/// Hover fills; [selected] draws the rounded pill (the location the active
/// pane shows) with a semibold title; the focus ring shows only in keyboard
/// mode. Right-click opens [menuEntries] at the pointer, Shift+F10 and the
/// Menu key open them from the keyboard, and a touch long-press opens the
/// same verbs as a bottom sheet.
class SidebarRow extends StatefulWidget {
  const SidebarRow({
    super.key,
    required this.mark,
    required this.title,
    this.statusColor,
    this.italic = false,
    this.trailingText,
    this.hoverAction,
    this.selected = false,
    this.depth = 0,
    this.onActivate,
    this.menuEntries,
    this.tooltip,
    this.semanticLabel,
    this.dropIndicator = SidebarDropIndicator.none,
  });

  /// The 18 px leading glyph or badge.
  final Widget mark;
  final String title;

  /// The one status dot composed into the mark's corner; null draws none.
  final Color? statusColor;

  /// Unsaved rows (a live Quick Connect session) set their title in
  /// italics.
  final bool italic;
  final String? trailingText;
  final SidebarRowAction? hoverAction;
  final bool selected;

  /// Nesting under a group disclosure row.
  final int depth;

  /// Null renders the row inert: no button role, no activation.
  final void Function(SidebarActivation how)? onActivate;

  /// The row's verbs, built when a menu opens. Null means no menu.
  final List<SidebarMenuEntry> Function()? menuEntries;

  /// Secondary facts (a path, an address, a failure) — 10 §2 keeps them
  /// out of the row and in the tooltip.
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
  bool _hovering = false;
  PointerDeviceKind? _lastPointer;

  void _activate(SidebarActivation how) => widget.onActivate?.call(how);

  void _openMenu({Offset? position}) {
    if (widget.menuEntries == null) return;
    _menu.open(position: position);
  }

  void _openSheet() {
    final entries = widget.menuEntries;
    if (entries == null) return;
    unawaited(
      showSidebarMenuSheet(context, title: widget.title, entries: entries()),
    );
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
    noteKey();
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
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
      _openMenu();
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

    final Color? fill = selected
        ? chrome.inactiveSelectionFill
        : (_hovering || dropInto ? chrome.hoverFill : null);
    // The dot's ring reads as a cut-out: it takes the colour actually
    // behind the mark, pill or hover included.
    final ring = fill == null
        ? chrome.sidebarBackground
        : Color.alphaBlend(fill, chrome.sidebarBackground);

    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      fontStyle: widget.italic ? FontStyle.italic : FontStyle.normal,
    );
    final action = widget.hoverAction;
    final showAction = action != null && (_hovering || focused);
    final Widget? trailing = showAction
        ? _KitIconButton(
            key: action.key,
            icon: action.icon,
            tooltip: action.tooltip,
            onPressed: action.onPressed,
          )
        : (widget.trailingText == null
              ? null
              : Text(
                  widget.trailingText!,
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: chrome.secondaryText,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ));

    Widget content = Container(
      height: _scaledExtent(context, chrome.sidebarRowExtent),
      margin: const EdgeInsets.symmetric(horizontal: _railInset),
      padding: EdgeInsetsDirectional.only(
        start: _contentInset + widget.depth * _depthIndent,
        end: 4,
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(_pillRadius),
        border: focused || dropInto
            ? Border.all(color: theme.colorScheme.primary, width: 2)
            : null,
      ),
      child: Row(
        children: [
          _SidebarMark(mark: widget.mark, dot: widget.statusColor, ring: ring),
          const SizedBox(width: 6),
          Expanded(child: MiddleEllipsisText(widget.title, style: titleStyle)),
          if (trailing != null) ...[const SizedBox(width: 6), trailing],
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
            start: _railInset,
            end: _railInset,
            top: widget.dropIndicator == SidebarDropIndicator.before ? 0 : null,
            bottom: widget.dropIndicator == SidebarDropIndicator.after
                ? 0
                : null,
            child: line,
          ),
        ],
      );
    }

    final entries = widget.menuEntries;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Focus(
        focusNode: focusNode,
        onKeyEvent: _onKey,
        onFocusChange: onFocusChanged,
        child: Semantics(
          container: true,
          button: widget.onActivate != null,
          selected: selected,
          label: widget.semanticLabel ?? widget.title,
          // The detector sits OUTSIDE ExcludeSemantics so its tap reaches
          // the semantics tree — an announced button a screen reader
          // cannot activate is WCAG 4.1.2's failure.
          child: Listener(
            onPointerDown: (event) => _lastPointer = event.kind,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // The pointer moves focus with it: Enter and the arrows
              // keep working from the row the user last touched.
              onTapDown: (_) => focusFromPointer(),
              onTap: widget.onActivate == null
                  ? null
                  : () => _activate(SidebarActivation.pointer),
              onSecondaryTapUp: entries == null
                  ? null
                  : (details) => _openMenu(position: details.localPosition),
              onLongPress: entries == null && widget.onActivate == null
                  ? null
                  : _onLongPress,
              child: ExcludeSemantics(
                child: entries == null
                    ? content
                    : MenuAnchor(
                        controller: _menu,
                        menuChildren: sidebarMenuWidgets(entries()),
                        child: content,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The 18 px mark with its one corner dot, ringed in the colour behind
/// the row so the dot reads as cut out of the mark (10 §5).
class _SidebarMark extends StatelessWidget {
  const _SidebarMark({
    required this.mark,
    required this.dot,
    required this.ring,
  });

  final Widget mark;
  final Color? dot;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _markExtent,
      height: _markExtent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(child: mark),
          if (dot != null)
            PositionedDirectional(
              end: -_dotRing,
              bottom: -_dotRing,
              child: Container(
                width: _dotExtent + 2 * _dotRing,
                height: _dotExtent + 2 * _dotRing,
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  border: Border.all(color: ring, width: _dotRing),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Filter field ─────────────────────────────────────────────────────

/// The rail's one filter field (10 §5): compact, Esc hands control back
/// through [onDismiss] (clear first, then close — the owner decides),
/// Enter runs [onSubmitted] (open the first match), and [countText]
/// ("3 of 12") sits inside the field while a query is live.
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
    final strings = SidebarKitScope.of(context);
    final small = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_railInset, 4, _railInset, 4),
      child: Shortcuts(
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
            height: _scaledExtent(context, 26),
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
                  size: 14,
                  color: chrome.secondaryText,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 26,
                  minHeight: 20,
                ),
                suffixIconConstraints: const BoxConstraints(minHeight: 20),
                suffixIcon: widget.query.isEmpty
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.countText case final count?) ...[
                            Text(
                              count,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: chrome.secondaryText,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            const SizedBox(width: 2),
                          ],
                          _KitIconButton(
                            icon: Icons.cancel,
                            tooltip: strings.filterClear,
                            onPressed: () => widget.onChanged(''),
                          ),
                        ],
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(_pillRadius),
                  borderSide: BorderSide.none,
                ),
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
/// status chip, and the Settings gear.
class SidebarBottomBar extends StatefulWidget {
  const SidebarBottomBar({
    super.key,
    required this.addEntries,
    this.sync,
    this.onSettings,
    this.addKey,
    this.settingsKey,
  });

  final List<SidebarMenuEntry> Function() addEntries;
  final SidebarSyncChipData? sync;
  final VoidCallback? onSettings;
  final Key? addKey;
  final Key? settingsKey;

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
      height: _scaledExtent(context, _bottomBarExtent),
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
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: widget.sync == null ? null : _SyncChip(data: widget.sync!),
            ),
          ),
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

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.data});

  final SidebarSyncChipData data;

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
    Widget chip = TextButton(
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
      child: Row(
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
    final tooltip = data.tooltip;
    if (tooltip != null) chip = Tooltip(message: tooltip, child: chip);
    return chip;
  }
}
