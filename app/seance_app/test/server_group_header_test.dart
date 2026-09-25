import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_app/ui/sidebar/sidebar_kit.dart';

/// The list's section headers and group disclosure rows are its only
/// collapsible surfaces, so what a screen reader makes of a chevron and a
/// bare count is asserted rather than assumed — in Séance's words, through
/// the strings the pane hands the kit.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required String name,
    required int count,
    required bool collapsed,
    bool nested = true,
    VoidCallback? onToggle,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: SeanceTheme.light(platform: TargetPlatform.macOS),
      home: Scaffold(
        body: SidebarKitScope(
          strings: serverSidebarStrings,
          // The rail's compact headers: the count shows only folded.
          density: SidebarKitDensity.compact,
          child: SidebarSectionHeader(
            headerKey: const ValueKey('header'),
            nested: nested,
            title: name,
            count: count,
            collapsed: collapsed,
            onToggle: onToggle ?? () {},
          ),
        ),
      ),
    ),
  );

  SemanticsData data(WidgetTester tester) => tester
      .getSemantics(find.byKey(const ValueKey('header')))
      .getSemanticsData();

  testWidgets('shows the name and a direction; the count only folded', (
    tester,
  ) async {
    await pump(tester, name: 'Production', count: 3, collapsed: false);
    expect(find.text('Production'), findsOneWidget);
    expect(find.text('3'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    // A collapsed group still says how much it is hiding, so folding one
    // away never looks like losing servers.
    await pump(tester, name: 'Production', count: 3, collapsed: true);
    expect(find.text('3'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  testWidgets('a section header draws caps and announces the spelling', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pump(
        tester,
        name: 'Servers',
        count: 2,
        collapsed: false,
        nested: false,
      );
      expect(find.text('SERVERS'), findsOneWidget);
      expect(data(tester).label, 'Servers, 2 servers');
      expect(tester.getSize(find.byKey(const ValueKey('header'))).height, 26);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('tapping anywhere on the row toggles', (tester) async {
    var toggles = 0;
    await pump(
      tester,
      name: 'Production',
      count: 3,
      collapsed: true,
      onToggle: () => toggles++,
    );
    await tester.tap(find.text('Production'));
    await tester.tap(find.text('3'));
    expect(toggles, 2);
  });

  testWidgets('is announced as one control that says what it holds', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pump(tester, name: 'Production', count: 3, collapsed: false);
      // One merged control, not a name and an orphaned number: the count
      // says what there are three *of*, and the fold state is spoken rather
      // than left to the chevron, which is invisible to a screen reader.
      expect(data(tester).label, 'Production, 3 servers');
      expect(
        tester.getSemantics(find.byKey(const ValueKey('header'))),
        isSemantics(
          isHeader: true,
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
        ),
      );

      await pump(tester, name: 'Production', count: 3, collapsed: true);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('header'))),
        isSemantics(hasExpandedState: true, isExpanded: false),
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a group of one is announced in the singular', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await pump(tester, name: 'CI', count: 1, collapsed: false);
      expect(data(tester).label, 'CI, 1 server');
    } finally {
      semantics.dispose();
    }
  });
}
