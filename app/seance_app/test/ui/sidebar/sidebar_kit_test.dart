// Ported from Poltergeist app/poltergeist_app/test/ui/sidebar/sidebar_kit_test.dart
// @ 58605fa, with the theme and chrome renamed.

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/middle_ellipsis_text.dart';
import 'package:seance_app/ui/sidebar/sidebar_kit.dart';

/// The kit takes its copy from the host app — these fixed strings prove
/// no string of its own reaches the screen or the semantics tree.
final _strings = SidebarKitStrings(
  sectionSemantics: (title, count) => '$title ($count)',
  showSection: 'kit-show',
  hideSection: 'kit-hide',
  filterHint: 'kit-filter',
  filterClear: 'kit-clear',
  addMenu: 'kit-add',
  settings: 'kit-settings',
  rowMenu: 'kit-more',
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  TargetPlatform platform = TargetPlatform.macOS,
  Color? background,
}) async {
  tester.view.physicalSize = const Size(600, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: SeanceTheme.light(platform: platform),
      home: Scaffold(
        body: SidebarKitScope(
          strings: _strings,
          background: background,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 240, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<TestGesture> _hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
  return mouse;
}

void main() {
  group('SidebarSectionHeader', () {
    testWidgets('caps the title visually, announces it as authored', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await _pump(
          tester,
          SidebarSectionHeader(
            headerKey: const ValueKey('h'),
            title: 'Servers',
            count: 3,
            collapsed: false,
            onToggle: () {},
          ),
        );
        expect(find.text('SERVERS'), findsOneWidget);
        final data = tester
            .getSemantics(find.byKey(const ValueKey('h')))
            .getSemanticsData();
        expect(data.label, 'Servers (3)');
        expect(data.flagsCollection.isHeader, isTrue);
        expect(data.flagsCollection.isExpanded, ui.Tristate.isTrue);
        // 22 px of rhythm plus the section's 4 px lead-in.
        expect(tester.getSize(find.byKey(const ValueKey('h'))).height, 26);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('the count shows only while collapsed', (tester) async {
      Widget header(bool collapsed) => SidebarSectionHeader(
        title: 'Favorites',
        count: 7,
        collapsed: collapsed,
        onToggle: () {},
      );
      await _pump(tester, header(false));
      expect(find.text('7'), findsNothing);
      await _pump(tester, header(true));
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('the + appears on hover and acts on its own', (tester) async {
      var toggles = 0;
      var adds = 0;
      await _pump(
        tester,
        SidebarSectionHeader(
          headerKey: const ValueKey('h'),
          title: 'Favorites',
          count: 1,
          collapsed: false,
          onToggle: () => toggles++,
          onAdd: () => adds++,
          addKey: const ValueKey('add'),
          addTooltip: 'kit-add-folder',
        ),
      );
      final add = find.byKey(const ValueKey('add'));
      await tester.tap(add, warnIfMissed: false);
      expect(adds, 0, reason: 'hidden until hovered');

      // (That tap fell through to the header, which folded.)
      final before = toggles;
      await _hover(tester, find.byKey(const ValueKey('h')));
      await tester.tap(add);
      expect(adds, 1);
      expect(toggles, before, reason: 'the + must not fold the section');
    });

    testWidgets('Enter, Space and the arrows drive the disclosure', (
      tester,
    ) async {
      var collapsed = false;
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => SidebarSectionHeader(
            headerKey: const ValueKey('h'),
            title: 'Servers',
            count: 1,
            collapsed: collapsed,
            onToggle: () => setState(() => collapsed = !collapsed),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('h')));
      await tester.pump();
      expect(collapsed, isTrue);

      // → expands a collapsed header; ← on a collapsed one does nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(collapsed, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(collapsed, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(collapsed, isTrue);
    });
  });

  group('SidebarRow', () {
    testWidgets('is one 26 px line with a middle-ellipsis title', (
      tester,
    ) async {
      await _pump(
        tester,
        const SidebarRow(
          key: ValueKey('r'),
          mark: Icon(Icons.folder_outlined, size: 16),
          title: 'prod-web-server-01.eu-west-1.example.internal',
          trailingText: '69 GB',
        ),
      );
      expect(tester.getSize(find.byKey(const ValueKey('r'))).height, 26);
      expect(find.byType(MiddleEllipsisText), findsOneWidget);
      final shown = tester
          .widget<Text>(
            find.descendant(
              of: find.byType(MiddleEllipsisText),
              matching: find.byType(Text),
            ),
          )
          .data!;
      // The distinguishing tail survives the truncation.
      expect(shown, contains('…'));
      expect(
        'prod-web-server-01.eu-west-1.example.internal',
        endsWith(shown.split('…').last),
      );
      expect(shown.split('…').last, isNotEmpty);
      expect(find.text('69 GB'), findsOneWidget);
    });

    testWidgets('the selected pill sets the title semibold and announces '
        'selected', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _pump(
          tester,
          SidebarRow(
            mark: const Icon(Icons.home_outlined, size: 16),
            title: 'deploy',
            selected: true,
            onActivate: (_) {},
          ),
        );
        final title = tester.widget<Text>(
          find.descendant(
            of: find.byType(MiddleEllipsisText),
            matching: find.byType(Text),
          ),
        );
        expect(title.style?.fontWeight, FontWeight.w600);
        final data = tester
            .getSemantics(find.bySemanticsLabel('deploy'))
            .getSemanticsData();
        expect(data.flagsCollection.isSelected, ui.Tristate.isTrue);
        expect(data.flagsCollection.isButton, isTrue);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('the hover action replaces the trailing text on hover', (
      tester,
    ) async {
      var ejected = 0;
      await _pump(
        tester,
        SidebarRow(
          key: const ValueKey('r'),
          mark: const Icon(Icons.usb, size: 16),
          title: 'STICK',
          trailingText: '2 GB',
          hoverAction: SidebarRowAction(
            key: const ValueKey('eject'),
            icon: Icons.eject,
            tooltip: 'kit-eject',
            onPressed: () => ejected++,
          ),
        ),
      );
      expect(find.text('2 GB'), findsOneWidget);
      expect(find.byKey(const ValueKey('eject')), findsNothing);

      await _hover(tester, find.byKey(const ValueKey('r')));
      expect(find.text('2 GB'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('eject')));
      expect(ejected, 1);
    });

    testWidgets('the status dot rings in the colour behind the mark', (
      tester,
    ) async {
      await _pump(
        tester,
        const SidebarRow(
          mark: Icon(Icons.dns_outlined, size: 16),
          title: 'demo',
          statusColor: Colors.green,
        ),
      );
      final chrome = SeanceChrome.of(tester.element(find.byType(SidebarRow)));
      final dot = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.shape == BoxShape.circle);
      expect(dot.color, Colors.green);
      expect((dot.border! as Border).top.color, chrome.sidebarBackground);
    });

    testWidgets('an activation reports how it happened', (tester) async {
      final hows = <SidebarActivation>[];
      await _pump(
        tester,
        SidebarRow(
          key: const ValueKey('r'),
          mark: const Icon(Icons.folder, size: 16),
          title: 'Docs',
          onActivate: hows.add,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('r')));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(hows, [SidebarActivation.pointer, SidebarActivation.keyboard]);
    });

    testWidgets('the Menu key opens the verbs; a disabled verb stays '
        'visible', (tester) async {
      var opened = 0;
      await _pump(
        tester,
        SidebarRow(
          key: const ValueKey('r'),
          mark: const Icon(Icons.folder, size: 16),
          title: 'Docs',
          onActivate: (_) {},
          menuEntries: () => [
            SidebarMenuAction(
              key: const ValueKey('open'),
              label: 'kit-open',
              onSelected: () => opened++,
            ),
            const SidebarMenuDivider(),
            const SidebarMenuDivider(),
            const SidebarMenuAction(
              key: ValueKey('off'),
              label: 'kit-off',
              onSelected: null,
            ),
            const SidebarMenuDivider(),
          ],
        ),
      );
      await tester.tap(find.byKey(const ValueKey('r')));
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('off')), findsOneWidget);
      expect(
        tester
            .widget<MenuItemButton>(find.byKey(const ValueKey('off')))
            .onPressed,
        isNull,
      );
      // Doubled and trailing separators are tidied away.
      expect(find.byType(Divider), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });
  });

  // Séance additions (see docs/POLTERGEIST.md, "The sidebar kit"): the
  // hollow dot, the host's row surface, the touch posture, and the
  // visible menu button.
  group('SidebarRow additions', () {
    /// The dot's circles, outermost first. Read off the DecoratedBoxes (a
    /// Container paints through one), so each circle counts once.
    List<BoxDecoration> circles(WidgetTester tester) => [
      for (final box in tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(SidebarRow),
          matching: find.byType(DecoratedBox),
        ),
      ))
        if (box.decoration case final BoxDecoration d
            when d.shape == BoxShape.circle)
          d,
    ];

    testWidgets('a ring dot is a hollow stroke in the status colour', (
      tester,
    ) async {
      await _pump(
        tester,
        const SidebarRow(
          mark: Icon(Icons.dns_outlined, size: 16),
          title: 'demo',
          statusColor: Colors.green,
          statusStyle: SidebarDotStyle.ring,
        ),
      );
      final chrome = SeanceChrome.of(tester.element(find.byType(SidebarRow)));
      final [outer, inner] = circles(tester);
      // The hole shows the row's own surface, not a fill of the status
      // colour: that is what tells it from a solid dot at 7 px.
      expect(outer.color, chrome.sidebarBackground);
      expect((outer.border! as Border).top.color, chrome.sidebarBackground);
      expect(inner.color, isNull);
      expect((inner.border! as Border).top.color, Colors.green);
    });

    testWidgets('the cut-out takes the surface the host says it paints', (
      tester,
    ) async {
      const surface = Color(0xFFFFFFFF);
      await _pump(
        tester,
        const SidebarRow(
          mark: Icon(Icons.dns_outlined, size: 16),
          title: 'demo',
          statusColor: Colors.green,
        ),
        background: surface,
      );
      final dot = circles(tester).single;
      expect(dot.color, Colors.green);
      expect((dot.border! as Border).top.color, surface);
    });

    testWidgets('a subtitle adds a second line; a trailing icon shows', (
      tester,
    ) async {
      await _pump(
        tester,
        const SidebarRow(
          key: ValueKey('r'),
          mark: Icon(Icons.dns_outlined, size: 16),
          title: 'demo',
          subtitle: 'deploy@demo:22',
          trailingIcon: Icons.cloud_off_outlined,
          trailingText: '×2',
        ),
      );
      expect(find.text('deploy@demo:22'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      expect(find.text('×2'), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('r'))).height, 40);
    });

    testWidgets('the menu button opens the menu on desktop', (tester) async {
      var opened = 0;
      await _pump(
        tester,
        SidebarRow(
          mark: const Icon(Icons.dns_outlined, size: 16),
          title: 'demo',
          showMenuButton: true,
          menuEntries: () => [
            SidebarMenuAction(
              key: const ValueKey('open'),
              label: 'kit-open',
              onSelected: () => opened++,
            ),
          ],
        ),
      );
      await tester.tap(find.byTooltip('kit-more'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('a keyboard-opened menu takes focus; Esc hands it back', (
      tester,
    ) async {
      final picked = <String>[];
      var activations = 0;
      await _pump(
        tester,
        SidebarRow(
          key: const ValueKey('r'),
          mark: const Icon(Icons.folder, size: 16),
          title: 'Docs',
          onActivate: (_) => activations++,
          menuEntries: () => [
            const SidebarMenuAction(
              key: ValueKey('off'),
              label: 'kit-off',
              onSelected: null,
            ),
            SidebarMenuAction(
              key: const ValueKey('one'),
              label: 'kit-one',
              onSelected: () => picked.add('one'),
            ),
            SidebarMenuAction(
              key: const ValueKey('two'),
              label: 'kit-two',
              onSelected: () => picked.add('two'),
            ),
          ],
        ),
      );
      final row = find.byKey(const ValueKey('r'));
      await tester.tap(row);
      activations = 0;
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      // The first *enabled* verb: a disabled one cannot hold focus.
      expect(
        Focus.of(tester.element(find.text('kit-one'))).hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      // Enter belongs to the focused verb, not to the row behind it.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked, ['two']);
      expect(activations, 0);

      // A right-clicked menu leaves focus on the row; Esc still closes it.
      await tester.tap(row, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('kit-one'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('kit-one'), findsNothing);
    });

    testWidgets('on touch the row is 48 dp and the menu button opens the '
        'sheet', (tester) async {
      var opened = 0;
      await _pump(
        tester,
        SidebarRow(
          key: const ValueKey('r'),
          mark: const Icon(Icons.dns_outlined, size: 20),
          title: 'demo',
          showMenuButton: true,
          menuEntries: () => [
            SidebarMenuAction(
              key: const ValueKey('open'),
              label: 'kit-open',
              onSelected: () => opened++,
            ),
          ],
        ),
        platform: TargetPlatform.android,
      );
      expect(tester.getSize(find.byKey(const ValueKey('r'))).height, 48);
      await tester.tap(find.byTooltip('kit-more'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('on touch a header keeps its chevron drawn and grows', (
      tester,
    ) async {
      await _pump(
        tester,
        SidebarSectionHeader(
          headerKey: const ValueKey('h'),
          title: 'Servers',
          count: 3,
          collapsed: false,
          onToggle: () {},
        ),
        platform: TargetPlatform.android,
      );
      // No hover ever comes on touch: without this the disclosure would
      // have no visible affordance.
      final chevron = tester.widget<Visibility>(
        find.ancestor(
          of: find.byIcon(Icons.expand_more),
          matching: find.byType(Visibility),
        ),
      );
      expect(chevron.visible, isTrue);
      expect(tester.getSize(find.byKey(const ValueKey('h'))).height, 40);
    });
  });

  group('SidebarFilterField', () {
    testWidgets('follows the owner, clears via the owner, and takes the '
        "owner's focus", (tester) async {
      var query = 'web';
      var dismissed = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => SidebarFilterField(
            fieldKey: const ValueKey('f'),
            query: query,
            focusNode: focus,
            countText: '2 of 9',
            onChanged: (value) => setState(() => query = value),
            onDismiss: () => dismissed++,
          ),
        ),
      );
      expect(find.text('2 of 9'), findsOneWidget);
      expect(find.byTooltip('kit-clear'), findsOneWidget);

      await tester.tap(find.byTooltip('kit-clear'));
      await tester.pump();
      expect(query, isEmpty);
      expect(find.text('kit-filter'), findsOneWidget);

      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(dismissed, 1);
    });
  });

  group('SidebarBottomBar', () {
    testWidgets('carries the + menu, the sync chip and the gear', (
      tester,
    ) async {
      var synced = 0;
      var settings = 0;
      var added = 0;
      await _pump(
        tester,
        SidebarBottomBar(
          addKey: const ValueKey('add'),
          settingsKey: const ValueKey('gear'),
          addEntries: () => [
            SidebarMenuAction(
              key: const ValueKey('new'),
              label: 'kit-new',
              onSelected: () => added++,
            ),
          ],
          sync: SidebarSyncChipData(
            key: const ValueKey('chip'),
            label: 'kit-synced',
            tone: SidebarSyncTone.error,
            onPressed: () => synced++,
          ),
          onSettings: () => settings++,
        ),
      );
      expect(tester.getSize(find.byType(SidebarBottomBar)).height, 30);
      expect(find.byTooltip('kit-add'), findsOneWidget);
      expect(find.byTooltip('kit-settings'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chip')));
      await tester.tap(find.byKey(const ValueKey('gear')));
      await tester.tap(find.byKey(const ValueKey('add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new')));
      await tester.pumpAndSettle();
      expect((synced, settings, added), (1, 1, 1));

      // The error tone paints the chip in the scheme's error colour.
      final label = tester.widget<Text>(find.text('kit-synced'));
      final scheme = Theme.of(
        tester.element(find.text('kit-synced')),
      ).colorScheme;
      expect(label.style?.color, scheme.error);
    });
  });
}
