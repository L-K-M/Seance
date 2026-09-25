import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/selected_tab_view.dart';

/// The tab view's contract: the selected page in place, the frame after a
/// tap, with no sideways paging; each page built when its tab is first
/// opened and kept, with its own state, from then on.
void main() {
  Future<void> pumpTabs(WidgetTester tester, List<Widget> pages) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: pages.length,
          child: Scaffold(
            appBar: AppBar(
              bottom: TabBar(
                tabs: [
                  for (var i = 0; i < pages.length; i++) Tab(text: 'Tab $i'),
                ],
              ),
            ),
            body: SelectedTabView(children: pages),
          ),
        ),
      ),
    );
  }

  testWidgets('a tap swaps the page on the next frame, in place', (
    tester,
  ) async {
    await pumpTabs(tester, [
      const Center(child: Text('first')),
      const Center(child: Text('second')),
      const Center(child: Text('third')),
    ]);
    final first = tester.getCenter(find.text('first'));

    await tester.tap(find.text('Tab 2'));
    await tester.pump();

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsNothing);
    expect(tester.getCenter(find.text('third')), first);
  });

  testWidgets('builds a page when its tab is first opened', (tester) async {
    await pumpTabs(tester, [const Text('first'), const Text('second')]);

    // Not merely hidden: a tab never opened has no page in the tree, so a
    // pane that starts work when it mounts waits for its tab.
    expect(find.text('second', skipOffstage: false), findsNothing);

    await tester.tap(find.text('Tab 1'));
    await tester.pump();

    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
    expect(find.text('first', skipOffstage: false), findsOneWidget);
  });

  testWidgets('a sideways fling leaves the tab as it was', (tester) async {
    await pumpTabs(tester, [
      const Center(child: Text('first')),
      const Center(child: Text('second')),
    ]);

    await tester.fling(find.text('first'), const Offset(-400, 0), 2000);
    await tester.pumpAndSettle();

    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);
  });

  testWidgets('each page keeps its own state while another shows', (
    tester,
  ) async {
    await pumpTabs(tester, [const TextField(), const TextField()]);
    await tester.enterText(find.byType(TextField), 'typed on the first');

    await tester.tap(find.text('Tab 1'));
    await tester.pump();
    // The second tab's own field, not the first one's.
    expect(find.text('typed on the first'), findsNothing);

    await tester.tap(find.text('Tab 0'));
    await tester.pump();
    expect(find.text('typed on the first'), findsOneWidget);
  });

  testWidgets('a hidden page stops animating and leaves the primary '
      'scroll controller', (tester) async {
    late bool animating;
    ScrollController? primary;
    await pumpTabs(tester, [
      Builder(
        builder: (context) {
          animating = TickerMode.valuesOf(context).enabled;
          primary = PrimaryScrollController.maybeOf(context);
          return const SizedBox.expand();
        },
      ),
      const Text('second'),
    ]);
    final screens = PrimaryScrollController.of(
      tester.element(find.byType(SelectedTabView)),
    );
    expect(animating, isTrue);
    expect(primary, same(screens));

    await tester.tap(find.text('Tab 1'));
    await tester.pump();

    expect(animating, isFalse);
    expect(primary, isNot(same(screens)));
  });

  testWidgets('a scrolled page keeps its offset, and only the showing page '
      'is on the primary scroll controller', (tester) async {
    Widget rows(String name) => ListView(
      children: [
        for (var i = 0; i < 100; i++)
          SizedBox(height: 50, child: Text('$name $i')),
      ],
    );
    await pumpTabs(tester, [rows('first'), rows('second')]);
    final screens = PrimaryScrollController.of(
      tester.element(find.byType(SelectedTabView)),
    );
    double offset() =>
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    final scrolled = offset();
    expect(scrolled, greaterThan(0));

    await tester.tap(find.text('Tab 1'));
    await tester.pump();
    expect(offset(), 0);
    expect(screens.positions, hasLength(1));

    await tester.tap(find.text('Tab 0'));
    await tester.pump();
    expect(offset(), scrolled);
    expect(screens.positions, hasLength(1));
  });

  testWidgets('a page inherits the primary controller only as the screen '
      'allows', (tester) async {
    final screens = ScrollController();
    addTearDown(screens.dispose);
    final tabs = TabController(length: 2, vsync: const TestVSync());
    addTearDown(tabs.dispose);
    await tester.pumpWidget(
      MaterialApp(
        // A primary controller that no scroll view inherits by itself.
        home: PrimaryScrollController(
          controller: screens,
          scrollDirection: null,
          child: SelectedTabView(
            controller: tabs,
            children: [
              ListView(children: const [Text('row')]),
              const Text('second'),
            ],
          ),
        ),
      ),
    );

    expect(screens.hasClients, isFalse);
  });

  testWidgets('follows an explicit controller', (tester) async {
    final controller = TabController(length: 2, vsync: const TestVSync());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SelectedTabView(
          controller: controller,
          children: const [Text('first'), Text('second')],
        ),
      ),
    );

    controller.index = 1;
    await tester.pump();

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('the page is a tab panel to assistive technology', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpTabs(tester, [const Text('first'), const Text('second')]);

    expect(
      find.semantics.byPredicate(
        (node) => node.role == SemanticsRole.tabPanel,
      ),
      findsOne,
    );
    semantics.dispose();
  });
}
