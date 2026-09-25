import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/selected_tab_view.dart';

/// The tab view's contract: the selected page in place, the frame after a
/// tap, with no sideways paging and no state leaking from one page to the
/// next.
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

  testWidgets('builds only the selected page', (tester) async {
    await pumpTabs(tester, [const Text('first'), const Text('second')]);

    // Not merely hidden: a page that is not showing is not in the tree, so
    // a pane that starts work when it mounts waits until its tab is opened.
    expect(find.text('second', skipOffstage: false), findsNothing);

    await tester.tap(find.text('Tab 1'));
    await tester.pump();

    expect(find.text('first', skipOffstage: false), findsNothing);
    expect(find.text('second'), findsOneWidget);
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

  testWidgets('pages of the same type do not share state', (tester) async {
    await pumpTabs(tester, [const TextField(), const TextField()]);
    await tester.enterText(find.byType(TextField), 'typed on the first');

    await tester.tap(find.text('Tab 1'));
    await tester.pump();

    expect(find.text('typed on the first'), findsNothing);
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
