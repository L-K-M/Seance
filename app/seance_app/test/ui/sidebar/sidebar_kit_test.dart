// Ported from Poltergeist app/poltergeist_app/test/ui/sidebar/sidebar_kit_test.dart
// @ 58605fa, with the theme and chrome renamed.

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
  compactRows: 'kit-compact',
  comfortableRows: 'kit-comfortable',
);

/// The production theme the kit paints under, for [brightness] on
/// [platform] (a sibling's copy of this file names its own here).
ThemeData _theme(Brightness brightness, TargetPlatform platform) =>
    brightness == Brightness.dark
    ? SeanceTheme.dark(platform: platform)
    : SeanceTheme.light(platform: platform);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  TargetPlatform platform = TargetPlatform.macOS,
  Brightness brightness = Brightness.light,
  Color? background,
  SidebarKitLayout layout = SidebarKitLayout.rail,
  SidebarKitDensity? density,
  double width = 240,
}) async {
  tester.view.physicalSize = const Size(600, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(brightness, platform),
      home: Scaffold(
        body: SidebarKitScope(
          strings: _strings,
          background: background,
          layout: layout,
          // The kit defaults to comfortable; most of this file pins the
          // compact rail's one-line anatomy, so compact unless asked (a
          // list is comfortable by definition).
          density:
              density ??
              (layout == SidebarKitLayout.list
                  ? SidebarKitDensity.comfortable
                  : SidebarKitDensity.compact),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// WCAG contrast between two opaque colours.
double _contrast(Color a, Color b) {
  final (la, lb) = (a.computeLuminance(), b.computeLuminance());
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
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
          status: SidebarStatusDot(Colors.green),
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
          status: SidebarStatusDot(
            Colors.green,
            style: SidebarDotStyle.ring,
          ),
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
          status: SidebarStatusDot(Colors.green),
        ),
        background: surface,
      );
      final dot = circles(tester).single;
      expect(dot.color, Colors.green);
      expect((dot.border! as Border).top.color, surface);
    });

    testWidgets('a comfortable subtitle adds a second line; a trailing icon '
        'shows', (tester) async {
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
        density: SidebarKitDensity.comfortable,
      );
      expect(find.text('deploy@demo:22'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      expect(find.text('×2'), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('r'))).height, 52);
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

    testWidgets('on macOS a Control-click opens the menu, as a right-click '
        'does; elsewhere it is a click', (tester) async {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
        var activations = 0;
        await _pump(
          tester,
          SidebarRow(
            key: const ValueKey('r'),
            mark: const Icon(Icons.folder, size: 16),
            title: 'Docs',
            onActivate: (_) => activations++,
            menuEntries: () => [
              SidebarMenuAction(
                key: const ValueKey('one'),
                label: 'kit-one',
                onSelected: () {},
              ),
            ],
          ),
          platform: platform,
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tap(
          find.byKey(const ValueKey('r')),
          kind: PointerDeviceKind.mouse,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        final mac = platform == TargetPlatform.macOS;
        expect(
          find.text('kit-one'),
          mac ? findsOneWidget : findsNothing,
          reason: '$platform',
        );
        expect(activations, mac ? 0 : 1, reason: '$platform');
        if (mac) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
      }
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

    testWidgets('the keyboard focus ring does not move what it frames', (
      tester,
    ) async {
      await _pump(
        tester,
        SidebarRow(
          key: const ValueKey('r'),
          mark: const Icon(Icons.folder, size: 16),
          title: 'Docs',
          onActivate: (_) {},
        ),
      );
      final title = find.text('Docs');
      final before = tester.getTopLeft(title);
      Container? ringed() => tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(const ValueKey('r')),
              matching: find.byType(Container),
            ),
          )
          .where((c) => c.foregroundDecoration != null)
          .firstOrNull;
      expect(ringed(), isNull);

      // A click focuses without a ring; the next key hands the ring back.
      await tester.tap(find.byKey(const ValueKey('r')));
      await tester.pump();
      expect(ringed(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(ringed(), isNotNull);
      expect(tester.getTopLeft(title), before);

      // A click on the row that already holds focus takes the ring away
      // too. Focus does not move, and the pointer is already hovering, so
      // nothing else would repaint the row.
      final mouse = await _hover(tester, find.byKey(const ValueKey('r')));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(ringed(), isNotNull);
      await mouse.down(tester.getCenter(find.byKey(const ValueKey('r'))));
      await mouse.up();
      await tester.pump();
      expect(ringed(), isNull);
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

  // Reach without a pointer: the header's "+" has to be operable from the
  // keyboard.
  group('keyboard reach', () {
    Widget section({required VoidCallback onAdd}) => Column(
      children: [
        SidebarSectionHeader(
          headerKey: const ValueKey('h'),
          title: 'Servers',
          count: 2,
          collapsed: false,
          onToggle: () {},
          onAdd: onAdd,
          addKey: const ValueKey('add'),
          addTooltip: 'kit-add-server',
        ),
        for (final name in ['alpha', 'beta'])
          SidebarRow(
            mark: const Icon(Icons.dns_outlined, size: 16),
            title: name,
            onActivate: (_) {},
          ),
      ],
    );

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }

    testWidgets('Tab reaches a header\'s + and leaves it; the arrows walk '
        'past it', (tester) async {
      var adds = 0;
      await _pump(tester, section(onAdd: () => adds++));
      FocusNode nodeOf(Finder finder) => Focus.of(tester.element(finder));
      final header = nodeOf(find.byKey(const ValueKey('h')));
      final add = nodeOf(find.byIcon(Icons.add));
      final alpha = nodeOf(find.text('alpha'));
      final beta = nodeOf(find.text('beta'));
      bool addShown() => tester
          .widget<Visibility>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('add')),
                  matching: find.byType(Visibility),
                )
                .first,
          )
          .visible;

      await press(tester, LogicalKeyboardKey.tab);
      expect(header.hasPrimaryFocus, isTrue);

      // Tab lands on the "+", which stays drawn while it holds focus (it
      // used to hide as the header lost focus, and focus bounced back).
      await press(tester, LogicalKeyboardKey.tab);
      expect(add.hasPrimaryFocus, isTrue);
      expect(addShown(), isTrue);
      await press(tester, LogicalKeyboardKey.enter);
      expect(adds, 1);
      await press(tester, LogicalKeyboardKey.tab);
      expect(alpha.hasPrimaryFocus, isTrue);
      expect(addShown(), isFalse);

      // The arrows walk headers and rows: the "+" is Tab's stop only.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(header.hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(alpha.hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(beta.hasPrimaryFocus, isTrue);

      // From the "+", the arrows rejoin the walk.
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.tab);
      expect(add.hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(alpha.hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.tab);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(header.hasPrimaryFocus, isTrue);
    });

    testWidgets('a clicked header still hands Tab to its +', (tester) async {
      await _pump(tester, section(onAdd: () {}));
      await tester.tap(find.byKey(const ValueKey('h')));
      await tester.pump();
      // The pointer is gone, so nothing but focus can reveal the "+".
      await press(tester, LogicalKeyboardKey.tab);
      expect(
        Focus.of(tester.element(find.byIcon(Icons.add))).hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('a pointer leaving from the + hides it again', (tester) async {
      await _pump(tester, section(onAdd: () {}));
      bool addShown() => tester
          .widget<Visibility>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('add')),
                  matching: find.byType(Visibility),
                )
                .first,
          )
          .visible;
      final mouse = await _hover(tester, find.byKey(const ValueKey('h')));
      expect(addShown(), isTrue);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('add'))));
      await tester.pump();
      expect(addShown(), isTrue);
      // Straight down onto the row, never crossing the header again: the
      // "+" sits over the header, so only its own exit can clear the hover.
      await mouse.moveTo(tester.getCenter(find.text('alpha')));
      await tester.pump();
      expect(addShown(), isFalse);
    });

  });

  // A row's verbs have to reach a screen reader, which has no pointer to
  // hover or right-click with.
  group('screen-reader reach', () {
    testWidgets('a row offers its verbs and its hover action as semantics '
        'actions', (tester) async {
      final semantics = tester.ensureSemantics();
      final picked = <String>[];
      await _pump(
        tester,
        SidebarRow(
          key: const ValueKey('r'),
          mark: const Icon(Icons.dns_outlined, size: 16),
          title: 'demo',
          onActivate: (_) {},
          hoverAction: SidebarRowAction(
            icon: Icons.eject,
            tooltip: 'kit-disconnect',
            onPressed: () => picked.add('disconnect'),
          ),
          menuEntries: () => [
            SidebarMenuAction(
              label: 'kit-open',
              onSelected: () => picked.add('open'),
            ),
            const SidebarMenuDivider(),
            const SidebarMenuAction(label: 'kit-off', onSelected: null),
            SidebarMenuAction(
              label: 'kit-disconnect',
              onSelected: () => picked.add('disconnect'),
            ),
          ],
        ),
      );
      // No hover needed: a screen reader's cursor is not a pointer. A
      // disabled verb is not offered, and the hover action and the verb
      // it repeats are one action.
      final row = find.semantics.byLabel('demo');
      final ids = row
          .evaluate()
          .single
          .getSemanticsData()
          .customSemanticsActionIds;
      expect([
        for (final id in ids ?? const <int>[])
          CustomSemanticsAction.getAction(id)!.label,
      ], unorderedEquals(['kit-open', 'kit-disconnect']));
      tester.semantics.customAction(
        row,
        const CustomSemanticsAction(label: 'kit-open'),
      );
      tester.semantics.customAction(
        row,
        const CustomSemanticsAction(label: 'kit-disconnect'),
      );
      expect(picked, ['open', 'disconnect']);
      semantics.dispose();
    });

    testWidgets('an open menu, the hover action and the menu button are in '
        'the semantics tree', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        SidebarRow(
          key: const ValueKey('r'),
          mark: const Icon(Icons.dns_outlined, size: 16),
          title: 'demo',
          onActivate: (_) {},
          showMenuButton: true,
          hoverAction: SidebarRowAction(
            icon: Icons.eject,
            tooltip: 'kit-disconnect',
            onPressed: () {},
          ),
          menuEntries: () => [
            SidebarMenuAction(label: 'kit-rename', onSelected: () {}),
          ],
        ),
      );
      SemanticsFinder button(String tooltip) => find.semantics.byPredicate(
        (node) =>
            node.tooltip == tooltip &&
            node.getSemanticsData().hasAction(SemanticsAction.tap),
      );
      expect(button('kit-more'), findsOne);

      await _hover(tester, find.byKey(const ValueKey('r')));
      expect(button('kit-disconnect'), findsOne);

      await tester.tap(
        find.byKey(const ValueKey('r')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('kit-rename'), findsOneWidget);
      expect(find.semantics.byLabel('kit-rename'), findsOne);
      semantics.dispose();
    });
  });

  // The two views: compact is the one-line rail the kit shipped with,
  // comfortable the roomy two-line rows both apps drew before it.
  group('density', () {
    /// A mark that fills the slot the kit reserves, and reports the glyph
    /// size the kit hands a bare icon.
    double? glyph;
    Widget probe() => Builder(
      builder: (context) {
        glyph = sidebarGlyphSize(context);
        return SizedBox.square(
          key: const ValueKey('mark'),
          dimension: sidebarMarkExtent(context),
        );
      },
    );

    Finder titleOf(String key) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(MiddleEllipsisText),
    );

    testWidgets('the scope defaults to comfortable and tells its dependents '
        'when the density changes', (tester) async {
      final seen = <SidebarKitDensity>[];
      // One instance across both pumps: only the scope's notification can
      // rebuild it.
      final dependent = Builder(
        builder: (context) {
          seen.add(SidebarKitScope.densityOf(context));
          return const SizedBox();
        },
      );
      await tester.pumpWidget(
        SidebarKitScope(strings: _strings, child: dependent),
      );
      expect(seen, [SidebarKitDensity.comfortable]);
      await tester.pumpWidget(
        SidebarKitScope(
          strings: _strings,
          density: SidebarKitDensity.compact,
          child: dependent,
        ),
      );
      expect(seen, [SidebarKitDensity.comfortable, SidebarKitDensity.compact]);
    });

    test('a list is comfortable by definition', () {
      expect(
        () => SidebarKitScope(
          strings: _strings,
          layout: SidebarKitLayout.list,
          density: SidebarKitDensity.compact,
          child: const SizedBox(),
        ),
        throwsAssertionError,
      );
      expect(
        sidebarHomeLayout(SidebarKitDensity.comfortable),
        SidebarKitLayout.list,
      );
      expect(
        sidebarHomeLayout(SidebarKitDensity.compact),
        SidebarKitLayout.rail,
      );
    });

    testWidgets('comfortable desktop rows are roomy: 52 px, a 32 px mark, a '
        '14 px title over a 12 px second line', (tester) async {
      await _pump(
        tester,
        Column(
          children: [
            SidebarRow(
              key: const ValueKey('two'),
              mark: probe(),
              title: 'demo',
              subtitle: 'deploy@demo',
            ),
            const SidebarRow(
              key: ValueKey('one'),
              mark: Icon(Icons.dns_outlined),
              title: 'bare',
            ),
          ],
        ),
        density: SidebarKitDensity.comfortable,
      );
      expect(tester.getSize(find.byKey(const ValueKey('two'))).height, 52);
      // Every comfortable row is one height, second line or not.
      expect(tester.getSize(find.byKey(const ValueKey('one'))).height, 52);
      expect(
        tester.getSize(find.byKey(const ValueKey('mark'))),
        const Size(32, 32),
      );
      expect(glyph, 20);
      expect(
        tester.widget<MiddleEllipsisText>(titleOf('two')).style?.fontSize,
        14,
      );
      expect(tester.widget<Text>(find.text('deploy@demo')).style?.fontSize, 12);
      // The second line sits under the title, not beside it.
      expect(
        tester.getTopLeft(find.text('deploy@demo')).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(titleOf('two')).dy),
      );
    });

    testWidgets('compact desktop rows stay one 26 px line: an 18 px mark, a '
        '13 px title, and no second line even when a host passes one', (
      tester,
    ) async {
      await _pump(
        tester,
        SidebarRow(
          key: const ValueKey('r'),
          mark: probe(),
          title: 'demo',
          subtitle: 'deploy@demo',
        ),
      );
      expect(tester.getSize(find.byKey(const ValueKey('r'))).height, 26);
      expect(
        tester.getSize(find.byKey(const ValueKey('mark'))),
        const Size(18, 18),
      );
      expect(glyph, 16);
      expect(
        tester.widget<MiddleEllipsisText>(titleOf('r')).style?.fontSize,
        13,
      );
      expect(find.text('deploy@demo'), findsNothing);
    });

    testWidgets('a touch rail follows the density too', (tester) async {
      for (final (density, extent, mark, glyphSize, twoLines) in [
        (SidebarKitDensity.comfortable, 56.0, 32.0, 22.0, true),
        (SidebarKitDensity.compact, 48.0, 24.0, 20.0, false),
      ]) {
        await _pump(
          tester,
          SidebarRow(
            key: const ValueKey('r'),
            mark: probe(),
            title: 'demo',
            subtitle: 'deploy@demo',
          ),
          platform: TargetPlatform.android,
          density: density,
        );
        final reason = density.name;
        expect(
          tester.getSize(find.byKey(const ValueKey('r'))).height,
          extent,
          reason: reason,
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('mark'))),
          Size(mark, mark),
          reason: reason,
        );
        expect(glyph, glyphSize, reason: reason);
        expect(
          find.text('deploy@demo'),
          twoLines ? findsOneWidget : findsNothing,
          reason: reason,
        );
      }
    });

    testWidgets('the "⋮" follows the density unless the host says '
        'otherwise: comfortable or touch draws it', (tester) async {
      Widget row({bool? showMenuButton}) => SidebarRow(
        mark: const Icon(Icons.dns_outlined),
        title: 'demo',
        showMenuButton: showMenuButton,
        menuEntries: () => [
          SidebarMenuAction(label: 'kit-open', onSelected: () {}),
        ],
      );
      for (final (platform, density, shown) in [
        (TargetPlatform.macOS, SidebarKitDensity.compact, false),
        (TargetPlatform.macOS, SidebarKitDensity.comfortable, true),
        (TargetPlatform.android, SidebarKitDensity.compact, true),
        (TargetPlatform.android, SidebarKitDensity.comfortable, true),
      ]) {
        await _pump(tester, row(), platform: platform, density: density);
        expect(
          find.byTooltip('kit-more'),
          shown ? findsOneWidget : findsNothing,
          reason: '$platform ${density.name}',
        );
      }
      await _pump(
        tester,
        row(showMenuButton: false),
        density: SidebarKitDensity.comfortable,
      );
      expect(find.byTooltip('kit-more'), findsNothing);
      await _pump(tester, row(showMenuButton: true));
      expect(find.byTooltip('kit-more'), findsOneWidget);
    });

    testWidgets('the accent is a 4 px rounded line leading the mark, in both '
        'densities, and moves nothing', (tester) async {
      const accent = Color(0xFF00897B);
      Finder line(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color == accent,
        ),
      );
      for (final (density, extent) in [
        (SidebarKitDensity.compact, 18.0),
        (SidebarKitDensity.comfortable, 32.0),
      ]) {
        await _pump(
          tester,
          Column(
            children: [
              SidebarRow(
                key: const ValueKey('a'),
                mark: probe(),
                title: 'accented',
                accent: accent,
                depth: 1,
              ),
              const SidebarRow(
                key: ValueKey('b'),
                mark: Icon(Icons.dns_outlined),
                title: 'plain',
                depth: 1,
              ),
            ],
          ),
          density: density,
        );
        final reason = density.name;
        expect(line('a'), findsOneWidget, reason: reason);
        expect(line('b'), findsNothing, reason: reason);
        expect(tester.getSize(line('a')), Size(4, extent), reason: reason);
        final decoration =
            tester.widget<DecoratedBox>(line('a')).decoration as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(2));
        final mark = find.byKey(const ValueKey('mark'));
        // Leading the mark, level with it, inside the row's pill.
        expect(
          tester.getTopRight(line('a')).dx,
          lessThan(tester.getTopLeft(mark).dx),
          reason: reason,
        );
        expect(
          tester.getCenter(line('a')).dy,
          tester.getCenter(mark).dy,
          reason: reason,
        );
        expect(
          tester.getTopLeft(line('a')).dx,
          greaterThanOrEqualTo(6),
          reason: reason,
        );
        // A coloured row and a plain one keep one column of titles.
        expect(
          tester.getTopLeft(titleOf('a')).dx,
          tester.getTopLeft(titleOf('b')).dx,
          reason: reason,
        );
      }
    });

    testWidgets('the connected ring frames the mark in both densities, '
        'sized to each, and moves nothing', (tester) async {
      const green = Color(0xFF2E7D32);
      Finder ring(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color == null &&
              ((widget.decoration as BoxDecoration).border as Border?)
                      ?.top
                      .color ==
                  green,
        ),
      );
      for (final (density, layout, platform, outer, stroke, shape) in [
        (
          SidebarKitDensity.compact,
          SidebarKitLayout.rail,
          TargetPlatform.macOS,
          23.0,
          1.5,
          BoxShape.rectangle,
        ),
        (
          SidebarKitDensity.comfortable,
          SidebarKitLayout.rail,
          TargetPlatform.macOS,
          40.0,
          2.0,
          BoxShape.rectangle,
        ),
        (
          SidebarKitDensity.comfortable,
          SidebarKitLayout.list,
          TargetPlatform.android,
          48.0,
          2.0,
          BoxShape.circle,
        ),
      ]) {
        await _pump(
          tester,
          Column(
            children: [
              SidebarRow(
                key: const ValueKey('a'),
                mark: probe(),
                title: 'up',
                markRing: green,
                status: const SidebarStatusDot(green),
              ),
              const SidebarRow(
                key: ValueKey('b'),
                mark: Icon(Icons.dns_outlined),
                title: 'down',
              ),
            ],
          ),
          platform: platform,
          layout: layout,
          density: density,
        );
        final reason = '${layout.name} ${density.name}';
        expect(ring('a'), findsOneWidget, reason: reason);
        expect(ring('b'), findsNothing, reason: reason);
        expect(tester.getSize(ring('a')), Size(outer, outer), reason: reason);
        expect(
          tester.getCenter(ring('a')),
          tester.getCenter(find.byKey(const ValueKey('mark'))),
          reason: reason,
        );
        final decoration =
            tester.widget<DecoratedBox>(ring('a')).decoration as BoxDecoration;
        expect(
          (decoration.border! as Border).top.width,
          stroke,
          reason: reason,
        );
        expect(decoration.shape, shape, reason: reason);
        expect(
          tester.getTopLeft(titleOf('a')).dx,
          tester.getTopLeft(titleOf('b')).dx,
          reason: reason,
        );
      }
    });

    testWidgets('a blocked dot is the no-entry sign: the solid dot crossed by '
        'a bar cut out of it, at 3:1 on the rail and on the pill', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        for (final selected in [false, true]) {
          late Color error;
          await _pump(
            tester,
            Builder(
              builder: (context) {
                error = Theme.of(context).colorScheme.error;
                return SidebarRow(
                  key: const ValueKey('r'),
                  mark: const Icon(Icons.dns_outlined, size: 16),
                  title: 'demo',
                  selected: selected,
                  status: SidebarStatusDot(
                    error,
                    style: SidebarDotStyle.blocked,
                  ),
                );
              },
            ),
            brightness: brightness,
          );
          final reason = '${brightness.name}${selected ? ', selected' : ''}';
          final dotFinder = find.descendant(
            of: find.byKey(const ValueKey('r')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Container &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).shape ==
                      BoxShape.circle &&
                  (widget.decoration as BoxDecoration).color == error,
            ),
          );
          expect(dotFinder, findsOneWidget, reason: reason);
          final dot = tester.widget<Container>(dotFinder);
          final cutOut =
              ((dot.decoration! as BoxDecoration).border! as Border).top.color;
          final barFinder = find.descendant(
            of: dotFinder,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).color == cutOut,
            ),
          );
          expect(barFinder, findsOneWidget, reason: reason);
          final bar = tester.getSize(barFinder);
          expect(bar.width, greaterThan(bar.height * 2), reason: reason);
          expect(
            _contrast(error, cutOut),
            greaterThanOrEqualTo(3),
            reason: reason,
          );
        }
      }

      // A failed dot is the plain disc: nothing crosses it.
      await _pump(
        tester,
        const SidebarRow(
          key: ValueKey('r'),
          mark: Icon(Icons.dns_outlined, size: 16),
          title: 'demo',
          status: SidebarStatusDot(Colors.red),
        ),
      );
      final solid = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const ValueKey('r')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).color == Colors.red,
          ),
        ),
      );
      expect(solid.child, isNull);
    });

    testWidgets('the long-press sheet shows the subtitle under its title, '
        'whatever the row draws', (tester) async {
      await _pump(
        tester,
        SidebarRow(
          key: const ValueKey('r'),
          mark: const Icon(Icons.dns_outlined),
          title: 'demo',
          subtitle: 'deploy@demo',
          onActivate: (_) {},
          menuEntries: () => [
            SidebarMenuAction(label: 'kit-open', onSelected: () {}),
          ],
        ),
        platform: TargetPlatform.android,
      );
      // Compact touch rows draw no second line: the sheet is where a
      // finger gets the fact a pointer reads from the tooltip.
      expect(find.text('deploy@demo'), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('r')));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      final title = find.descendant(of: sheet, matching: find.text('demo'));
      final subtitle = find.descendant(
        of: sheet,
        matching: find.text('deploy@demo'),
      );
      expect(subtitle, findsOneWidget);
      expect(
        tester.getTopLeft(subtitle).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
      );
      expect(
        tester.getBottomLeft(subtitle).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('kit-open')).dy),
      );
    });
  });

  group('SidebarSectionHeader density', () {
    Visibility visibilityOf(WidgetTester tester, Finder finder) =>
        tester.widget<Visibility>(
          find.ancestor(of: finder, matching: find.byType(Visibility)).first,
        );

    testWidgets('comfortable headers keep the chevron, the count and the + '
        'drawn', (tester) async {
      Widget header({bool nested = false}) => SidebarSectionHeader(
        title: 'Servers',
        count: 3,
        collapsed: false,
        nested: nested,
        onToggle: () {},
        onAdd: nested ? null : () {},
        addKey: const ValueKey('add'),
      );
      await _pump(tester, header(), density: SidebarKitDensity.comfortable);
      expect(find.text('3'), findsOneWidget);
      expect(
        visibilityOf(tester, find.byIcon(Icons.expand_more)).visible,
        isTrue,
      );
      expect(
        visibilityOf(tester, find.byKey(const ValueKey('add'))).visible,
        isTrue,
      );

      await _pump(
        tester,
        header(nested: true),
        density: SidebarKitDensity.comfortable,
      );
      expect(find.text('3'), findsOneWidget);

      // Compact keeps them for hover, focus, or a folded section.
      await _pump(tester, header());
      expect(find.text('3'), findsNothing);
      expect(
        visibilityOf(tester, find.byIcon(Icons.expand_more)).visible,
        isFalse,
      );
      expect(
        visibilityOf(tester, find.byKey(const ValueKey('add'))).visible,
        isFalse,
      );
    });

    testWidgets('a header carries a status dot for rows it hides', (
      tester,
    ) async {
      const green = Color(0xFF2E7D32);
      Iterable<Container> dots(WidgetTester tester) => tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(SidebarSectionHeader),
              matching: find.byType(Container),
            ),
          )
          .where(
            (box) =>
                box.decoration is BoxDecoration &&
                (box.decoration! as BoxDecoration).shape == BoxShape.circle &&
                (box.decoration! as BoxDecoration).color == green,
          );
      for (final nested in [false, true]) {
        await _pump(
          tester,
          SidebarSectionHeader(
            title: 'Production',
            count: 3,
            collapsed: true,
            nested: nested,
            onToggle: () {},
            status: const SidebarStatusDot(green),
          ),
        );
        expect(dots(tester), hasLength(1), reason: 'nested: $nested');
        // Beside the count it summarises, after the title.
        expect(
          tester.getTopLeft(find.byWidget(dots(tester).single)).dx,
          greaterThanOrEqualTo(
            tester
                .getTopRight(
                  find.textContaining(
                    RegExp('production', caseSensitive: false),
                  ),
                )
                .dx,
          ),
        );
      }
      await _pump(
        tester,
        SidebarSectionHeader(
          title: 'Production',
          count: 3,
          collapsed: true,
          onToggle: () {},
        ),
      );
      expect(dots(tester), isEmpty);
    });
  });

  group('SidebarDensitySwitch', () {
    testWidgets('two halves in one capsule: the current one selected and '
        'filled, a tap on the other reports it', (tester) async {
      final semantics = tester.ensureSemantics();
      final picked = <SidebarKitDensity>[];
      await _pump(tester, SidebarDensitySwitch(onChanged: picked.add));
      expect(find.byIcon(Icons.density_small), findsOneWidget);
      expect(find.byIcon(Icons.density_medium), findsOneWidget);

      // The node a screen reader lands on: the half's merged one.
      SemanticsData half(String tooltip) => find.semantics
          .byPredicate(
            (node) =>
                !node.isMergedIntoParent &&
                node.getSemanticsData().tooltip == tooltip,
          )
          .evaluate()
          .single
          .getSemanticsData();
      final compact = half('kit-compact');
      final comfortable = half('kit-comfortable');
      expect(compact.flagsCollection.isButton, isTrue);
      expect(compact.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      expect(compact.flagsCollection.isSelected, ui.Tristate.isTrue);
      expect(comfortable.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      expect(comfortable.flagsCollection.isSelected, ui.Tristate.isFalse);
      expect(comfortable.hasAction(SemanticsAction.tap), isTrue);

      Color? fillOf(IconData icon) => tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(icon),
              matching: find.byType(IconButton),
            ),
          )
          .style
          ?.backgroundColor
          ?.resolve(const <WidgetState>{});
      expect(fillOf(Icons.density_small), isNotNull);
      expect(fillOf(Icons.density_medium), isNull);

      await tester.tap(find.byTooltip('kit-comfortable'));
      await tester.tap(find.byTooltip('kit-compact'));
      expect(picked, [SidebarKitDensity.comfortable]);
      semantics.dispose();
    });

    testWidgets('an explicit value wins over the scope', (tester) async {
      await _pump(
        tester,
        SidebarDensitySwitch(
          value: SidebarKitDensity.comfortable,
          onChanged: (_) {},
        ),
      );
      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.density_medium),
          matching: find.byType(IconButton),
        ),
      );
      expect(
        button.style?.backgroundColor?.resolve(const <WidgetState>{}),
        isNotNull,
      );
    });

    testWidgets('the bottom bar draws it before the gear only when asked, '
        'and nothing overflows at the rail\'s 180 px minimum', (tester) async {
      final picked = <SidebarKitDensity>[];
      Widget bar({ValueChanged<SidebarKitDensity>? onDensityChanged}) =>
          SidebarBottomBar(
            settingsKey: const ValueKey('gear'),
            addEntries: () => const [],
            sync: const SidebarSyncChipData(
              label: 'kit-synced · 2 min',
              tone: SidebarSyncTone.normal,
            ),
            onSettings: () {},
            onDensityChanged: onDensityChanged,
          );

      await _pump(tester, bar());
      expect(find.byType(SidebarDensitySwitch), findsNothing);

      for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
        await _pump(
          tester,
          bar(onDensityChanged: picked.add),
          platform: platform,
          width: 180,
        );
        expect(tester.takeException(), isNull, reason: '$platform');
        final toggle = find.byType(SidebarDensitySwitch);
        final gear = find.byKey(const ValueKey('gear'));
        expect(toggle, findsOneWidget, reason: '$platform');
        expect(
          tester.getTopRight(toggle).dx,
          lessThanOrEqualTo(tester.getTopLeft(gear).dx),
          reason: '$platform',
        );
        expect(tester.getTopRight(gear).dx, lessThanOrEqualTo(180));
      }
      // The desktop chip still reads at the minimum, shortened.
      await _pump(tester, bar(onDensityChanged: picked.add), width: 180);
      expect(find.textContaining('kit-synced'), findsOneWidget);

      await tester.tap(find.byTooltip('kit-comfortable'));
      expect(picked, [SidebarKitDensity.comfortable]);
    });
  });

  group('SidebarFilterField count', () {
    testWidgets('the count reads under the field, where a long hint fits', (
      tester,
    ) async {
      const hint = '2 of 9 · ↵ opens the first';
      Widget field(String query) => SidebarFilterField(
        fieldKey: const ValueKey('f'),
        query: query,
        countText: hint,
        onChanged: (_) {},
        onDismiss: () {},
      );
      await _pump(tester, field('web'), width: 180);
      expect(tester.takeException(), isNull);
      expect(find.text(hint), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(hint)).dy,
        greaterThanOrEqualTo(
          tester.getBottomLeft(find.byKey(const ValueKey('f'))).dy,
        ),
      );
      // No query, no count.
      await _pump(tester, field(''), width: 180);
      expect(find.text(hint), findsNothing);
    });
  });

  group('horizontal arrows', () {
    testWidgets('Left and Right keep focus in the sidebar: a header folds '
        'or unfolds and otherwise swallows them, and so does a row', (
      tester,
    ) async {
      final outside = FocusNode(debugLabel: 'beside the sidebar');
      addTearDown(outside.dispose);
      var collapsed = false;
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 160,
                child: Column(
                  children: [
                    SidebarSectionHeader(
                      headerKey: const ValueKey('h'),
                      title: 'Servers',
                      count: 1,
                      collapsed: collapsed,
                      onToggle: () => setState(() => collapsed = !collapsed),
                    ),
                    SidebarRow(
                      key: const ValueKey('r'),
                      mark: const Icon(Icons.dns_outlined, size: 16),
                      title: 'alpha',
                      onActivate: (_) {},
                    ),
                  ],
                ),
              ),
              // A pane beside the rail, where directional traversal would
              // take an arrow the sidebar let through.
              Focus(
                focusNode: outside,
                child: const SizedBox(width: 60, height: 60),
              ),
            ],
          ),
        ),
      );
      final header = Focus.of(tester.element(find.byKey(const ValueKey('h'))));
      final row = Focus.of(tester.element(find.text('alpha')));
      header.requestFocus();
      await tester.pump();

      Future<void> press(LogicalKeyboardKey key, {bool repeat = false}) async {
        if (repeat) {
          await tester.sendKeyDownEvent(key);
          await tester.sendKeyRepeatEvent(key);
          await tester.sendKeyUpEvent(key);
        } else {
          await tester.sendKeyEvent(key);
        }
        await tester.pump();
      }

      // Right on an expanded header, held or not: nothing to open.
      await press(LogicalKeyboardKey.arrowRight);
      await press(LogicalKeyboardKey.arrowRight, repeat: true);
      expect(header.hasPrimaryFocus, isTrue);
      expect(collapsed, isFalse);

      await press(LogicalKeyboardKey.arrowLeft);
      expect(collapsed, isTrue);
      // Left on a collapsed one, held or not: nothing to close.
      await press(LogicalKeyboardKey.arrowLeft);
      await press(LogicalKeyboardKey.arrowLeft, repeat: true);
      expect(header.hasPrimaryFocus, isTrue);
      expect(collapsed, isTrue);
      // A held Right opens it once, not on every repeat.
      await press(LogicalKeyboardKey.arrowRight, repeat: true);
      expect(collapsed, isFalse);
      expect(header.hasPrimaryFocus, isTrue);

      row.requestFocus();
      await tester.pump();
      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowLeft,
      ]) {
        await press(key);
        await press(key, repeat: true);
        expect(row.hasPrimaryFocus, isTrue, reason: '$key');
      }
      expect(outside.hasFocus, isFalse);
    });

    testWidgets('Left and Right with Ctrl, Alt or Meta are the app\'s: they '
        'reach its shortcuts from a row or a header', (tester) async {
      final fired = <String>[];
      var collapsed = false;
      await _pump(
        tester,
        // The host's chords, above the sidebar as an app's shortcuts are
        // (Poltergeist's pane focus is Ctrl+Alt+arrow, or Cmd+Option+arrow
        // on macOS).
        CallbackShortcuts(
          bindings: {
            const SingleActivator(
              LogicalKeyboardKey.arrowRight,
              control: true,
              alt: true,
            ): () =>
                fired.add('ctrl+alt+right'),
            const SingleActivator(
              LogicalKeyboardKey.arrowLeft,
              control: true,
              alt: true,
            ): () =>
                fired.add('ctrl+alt+left'),
            const SingleActivator(
              LogicalKeyboardKey.arrowRight,
              meta: true,
              alt: true,
            ): () =>
                fired.add('meta+alt+right'),
            const SingleActivator(
              LogicalKeyboardKey.arrowLeft,
              alt: true,
            ): () =>
                fired.add('alt+left'),
          },
          child: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                SidebarSectionHeader(
                  headerKey: const ValueKey('h'),
                  title: 'Servers',
                  count: 1,
                  collapsed: collapsed,
                  onToggle: () => setState(() => collapsed = !collapsed),
                ),
                SidebarRow(
                  mark: const Icon(Icons.dns_outlined, size: 16),
                  title: 'alpha',
                  onActivate: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      final header = Focus.of(tester.element(find.byKey(const ValueKey('h'))));
      final row = Focus.of(tester.element(find.text('alpha')));

      Future<void> chord(
        List<LogicalKeyboardKey> modifiers,
        LogicalKeyboardKey key, {
        bool repeat = false,
      }) async {
        for (final modifier in modifiers) {
          await tester.sendKeyDownEvent(modifier);
        }
        await tester.sendKeyDownEvent(key);
        if (repeat) await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyUpEvent(key);
        for (final modifier in modifiers.reversed) {
          await tester.sendKeyUpEvent(modifier);
        }
        await tester.pump();
      }

      const ctrlAlt = [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
      ];
      const metaAlt = [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.altLeft];
      const alt = [LogicalKeyboardKey.altLeft];

      row.requestFocus();
      await tester.pump();
      await chord(ctrlAlt, LogicalKeyboardKey.arrowRight);
      await chord(ctrlAlt, LogicalKeyboardKey.arrowLeft);
      await chord(metaAlt, LogicalKeyboardKey.arrowRight);
      await chord(alt, LogicalKeyboardKey.arrowLeft);
      expect(fired, [
        'ctrl+alt+right',
        'ctrl+alt+left',
        'meta+alt+right',
        'alt+left',
      ]);

      // A header lets them by too, held or not, and does not fold or
      // unfold on the way.
      fired.clear();
      header.requestFocus();
      await tester.pump();
      await chord(ctrlAlt, LogicalKeyboardKey.arrowLeft);
      await chord(ctrlAlt, LogicalKeyboardKey.arrowRight, repeat: true);
      await chord(alt, LogicalKeyboardKey.arrowLeft);
      expect(fired, [
        'ctrl+alt+left',
        'ctrl+alt+right',
        'ctrl+alt+right',
        'alt+left',
      ]);
      expect(collapsed, isFalse);
    });
  });
}
