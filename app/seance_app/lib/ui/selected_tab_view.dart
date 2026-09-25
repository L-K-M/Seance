import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

/// The selected tab's page, swapped in place: [TabBarView] without the
/// carousel.
///
/// [TabBarView] lays its pages side by side in a [PageView], so choosing a
/// tab scrolls the content sideways to it, and a horizontal swipe (a
/// trackpad's two-finger one included) pages between them. Tabs do neither:
/// this shows the [controller]'s selected child and nothing else, so the
/// frame after a tap already has the whole new page. The [TabBar]'s
/// indicator still moves, on the controller's own animation.
///
/// What it keeps from [TabBarView]: only the selected page is built, so a
/// tab that is left loses its widget state (a `PageStorageKey` still brings
/// back its scroll offset), and the page is a [SemanticsRole.tabPanel].
///
/// The same file is in Séance and Poltergeist; change both together.
class SelectedTabView extends StatelessWidget {
  const SelectedTabView({super.key, this.controller, required this.children});

  /// Which tab is selected. Defaults to the enclosing
  /// [DefaultTabController], as [TabBarView]'s does.
  final TabController? controller;

  /// One page per tab, in the [TabBar]'s order.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller ?? DefaultTabController.of(context);
    assert(controller.length == children.length);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final index = controller.index;
        // Keyed by position: two pages whose roots are the same widget type
        // would otherwise share one element, and with it a scroll position
        // or a field's text, where the PageView's slots kept them apart.
        return KeyedSubtree(
          key: ValueKey(index),
          child: Semantics(
            role: SemanticsRole.tabPanel,
            child: children[index],
          ),
        );
      },
    );
  }
}
