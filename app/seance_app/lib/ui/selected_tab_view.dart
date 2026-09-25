import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

/// The selected tab's page, swapped in place: [TabBarView] without the
/// carousel.
///
/// [TabBarView] lays its pages side by side in a [PageView], so choosing a
/// tab scrolls the content sideways to it, and a horizontal swipe (a
/// trackpad's two-finger one included) pages between them. Tabs do neither:
/// this shows the [controller]'s selected page and nothing else, so the
/// frame after a tap already has the whole new page. The [TabBar]'s
/// indicator still moves, on the controller's own animation.
///
/// A page is built the first time its tab is opened and kept from then on,
/// the way a native tab view keeps its panes: a half-typed message, a search
/// or a scroll position is still there when the tab comes back. ([TabBarView]
/// dropped a page once it slid away, unless a focused field held it.) A tab
/// never opened is never built, so a pane that starts work when it mounts
/// waits for its tab. A page that is not showing is not painted, hit,
/// focused, read out or animated, and it is parked on its own scroll
/// controller, so the showing page is the only one on the
/// [PrimaryScrollController]: the one a status-bar tap or a keyboard scroll
/// moves.
///
/// Like [TabBarView]'s, the page is a [SemanticsRole.tabPanel].
///
/// The same file is in Séance and Poltergeist; change both together.
class SelectedTabView extends StatefulWidget {
  const SelectedTabView({super.key, this.controller, required this.children});

  /// Which tab is selected. Defaults to the enclosing
  /// [DefaultTabController], as [TabBarView]'s does.
  final TabController? controller;

  /// One page per tab, in the [TabBar]'s order.
  final List<Widget> children;

  @override
  State<SelectedTabView> createState() => _SelectedTabViewState();
}

class _SelectedTabViewState extends State<SelectedTabView> {
  /// The tabs opened so far, whose pages stay built.
  final Set<int> _opened = {};

  /// Where each hidden page's scroll views wait, by tab.
  final Map<int, ScrollController> _parked = {};

  @override
  void dispose() {
    for (final controller in _parked.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller ?? DefaultTabController.of(context);
    assert(controller.length == widget.children.length);
    final primary = context
        .dependOnInheritedWidgetOfExactType<PrimaryScrollController>();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final selected = controller.index;
        _opened.add(selected);
        return IndexedStack(
          index: selected,
          // Each page fills the view, as a TabBarView page does.
          sizing: StackFit.expand,
          children: [
            for (final (tab, page) in widget.children.indexed)
              _opened.contains(tab)
                  ? _slot(tab, page, showing: tab == selected, primary: primary)
                  : const SizedBox.shrink(),
          ],
        );
      },
    );
  }

  /// A page under the same widgets whether it shows or not: a wrapper that
  /// came and went would rebuild the page from scratch.
  Widget _slot(
    int tab,
    Widget page, {
    required bool showing,
    required PrimaryScrollController? primary,
  }) {
    Widget slot = Semantics(role: SemanticsRole.tabPanel, child: page);
    final inherited = primary?.controller;
    if (inherited != null) {
      // Swapped rather than withheld: a scroll view that stops inheriting
      // rebuilds what is under it, while one handed another controller keeps
      // its position.
      slot = PrimaryScrollController(
        controller: showing
            ? inherited
            : _parked.putIfAbsent(tab, ScrollController.new),
        automaticallyInheritForPlatforms:
            primary!.automaticallyInheritForPlatforms,
        scrollDirection: primary.scrollDirection ?? Axis.vertical,
        child: slot,
      );
    }
    return TickerMode(enabled: showing, child: slot);
  }
}
