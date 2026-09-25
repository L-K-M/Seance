import 'package:flutter/material.dart';

import '../family_hues.dart';
import '../main.dart';
import '../theme.dart';
import 'app_menus.dart';
import 'settings_screen.dart';
import 'chat_sidebar.dart';
import 'files_pane.dart';
import 'git_pane.dart';
import 'snippets_pane.dart';

/// The right-hand utility panel: an Assistant tab (the LLM chat, when a provider
/// is configured) and a Snippets tab (always available). Used both as a tiled
/// pane on wide layouts and inside the end-drawer on narrow ones.
class SidebarPanel extends StatefulWidget {
  final bool includeFiles;

  const SidebarPanel({super.key, this.includeFiles = true});

  @override
  State<SidebarPanel> createState() => _SidebarPanelState();
}

class _SidebarPanelState extends State<SidebarPanel>
    with SingleTickerProviderStateMixin {
  TabController? _tabs;
  bool _filesVisited = false;
  bool _gitVisited = false;

  /// The Git tab is always last; the Files tab only exists when
  /// [SidebarPanel.includeFiles] is on.
  int get _gitIndex => widget.includeFiles ? 3 : 2;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_tabs != null) return;
    final state = AppScope.of(context);
    // includeFiles is fixed at every call site (const constructions), so the
    // controller's length never needs to track a rebuild-time change.
    _tabs = TabController(
      length: widget.includeFiles ? 4 : 3,
      initialIndex: state.llmConfigured ? 0 : 1,
      vsync: this,
    )..addListener(_tabChanged);
  }

  void _tabChanged() {
    if (widget.includeFiles && _tabs?.index == 2 && !_filesVisited) {
      setState(() => _filesVisited = true);
    }
    if (_tabs?.index == _gitIndex && !_gitVisited) {
      setState(() => _gitVisited = true);
    }
  }

  @override
  void dispose() {
    _tabs?.removeListener(_tabChanged);
    _tabs?.dispose();
    super.dispose();
  }

  /// The tabs in order, each with its family hue (Poltergeist's D34, the
  /// sibling apps' colour vocabulary): the Assistant the AI purple, the
  /// Snippets the saved-recipe teal, Files the places blue, Git the code
  /// orange.
  List<_PanelTab> get _panelTabs => [
    const _PanelTab('Assistant', Icons.auto_awesome, FamilyHue.purple),
    const _PanelTab('Snippets', Icons.bookmarks, FamilyHue.teal),
    if (widget.includeFiles)
      const _PanelTab('Files', Icons.folder, FamilyHue.blue),
    const _PanelTab('Git', Icons.account_tree, FamilyHue.orange),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final tabs = _panelTabs;
    final controller = _tabs!;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return SafeArea(
          child: Column(
            children: [
              // The underline takes the open tab's hue, blending from one
              // tab's colour to the next as it slides.
              AnimatedBuilder(
                animation: controller.animation!,
                builder: (context, _) => TabBar(
                  controller: controller,
                  labelPadding: const EdgeInsets.symmetric(
                    horizontal: _tabLabelPadding,
                  ),
                  labelColor: Theme.of(context).colorScheme.onSurface,
                  unselectedLabelColor: SeanceChrome.of(context).secondaryText,
                  labelStyle: _tabLabelStyle(
                    context,
                  )?.copyWith(fontWeight: FontWeight.w600),
                  unselectedLabelStyle: _tabLabelStyle(context),
                  indicatorColor: _indicatorColor(
                    context,
                    tabs,
                    controller.animation!.value,
                  ),
                  tabs: [for (final tab in tabs) _PanelTabLabel(tab)],
                ),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    state.llmConfigured
                        ? const ChatSidebar()
                        : const _AssistantSetupPrompt(),
                    const SnippetsPane(),
                    if (widget.includeFiles)
                      _filesVisited
                          ? const FilesPane()
                          : const SizedBox.shrink(),
                    _gitVisited ? const GitPane() : const SizedBox.shrink(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A panel tab's horizontal inset: tighter than Material's 16 so four
/// tabs keep their words at the panel's narrower widths.
const double _tabLabelPadding = 4;

/// The label under a tab's glyph: the small toolbar size the old
/// source-list apps set under their icons.
TextStyle? _tabLabelStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelMedium;

/// The underline's colour at [position] (the tab controller's animation
/// value): the hue of the tab it rests on, or a blend of the two it is
/// sliding between.
Color _indicatorColor(
  BuildContext context,
  List<_PanelTab> tabs,
  double position,
) {
  final palette = FamilyPalette.of(context);
  final last = tabs.length - 1;
  final from = position.floor().clamp(0, last);
  final to = position.ceil().clamp(0, last);
  return Color.lerp(
    palette.glyph(tabs[from].hue),
    palette.glyph(tabs[to].hue),
    position - from,
  )!;
}

class _PanelTab {
  const _PanelTab(this.label, this.glyph, this.hue);

  final String label;
  final IconData glyph;
  final FamilyHue hue;
}

/// A tab's glyph in its hue over its label, as Postbox's and iTunes'
/// toolbars set theirs: four words fit the panel's usual width this
/// way, where a glyph beside each would crowd them into ellipses. The
/// label ellipsizes only on a very narrow panel and gives way to the
/// glyph alone (with the label as its tooltip) once no word fits.
class _PanelTabLabel extends StatelessWidget {
  const _PanelTabLabel(this.tab);

  /// Below this width only the glyph is drawn.
  static const double _glyphOnlyWidth = 40;
  static const double _glyphSize = 18;

  /// Glyph, gap and label, with Material's text tab's breathing room.
  static const double _height = 52;

  final _PanelTab tab;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      tab.glyph,
      size: _glyphSize,
      color: FamilyPalette.of(context).glyph(tab.hue),
    );
    return Tab(
      height: _height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < _glyphOnlyWidth) {
            // The label speaks once: the tooltip is for the pointer.
            return Tooltip(
              message: tab.label,
              excludeFromSemantics: true,
              child: Semantics(label: tab.label, child: glyph),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              glyph,
              const SizedBox(height: 3),
              Text(
                tab.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AssistantSetupPrompt extends StatelessWidget {
  const _AssistantSetupPrompt();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 36,
              color: FamilyPalette.of(context).glyph(FamilyHue.purple),
            ),
            const SizedBox(height: 12),
            Text(
              'Assistant not set up',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Add an LLM provider (Anthropic, or a local OpenAI-compatible '
              'endpoint) to chat about your session and turn plain language '
              'into commands.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => openSettings(SettingsTab.assistant),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}
