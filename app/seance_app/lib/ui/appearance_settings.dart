import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/settings_backend.dart';
import '../services/system_fonts.dart';
import '../theme.dart';
import '../theme/app_appearance.dart';
import '../theme/theme_palette.dart';
import '../theme/theme_presets.dart';
import 'color_picker.dart';
import 'font_picker.dart';
import 'settings_layout.dart';
import 'terminal_appearance.dart';
import 'top_toast.dart';

/// The Appearance tab: this device's theme, after Vervellum's
/// `AppearanceView`. Pick a preset, then change anything.
///
/// Written to be played with. Every control writes straight through the
/// backend and the app repaints as it does — there is no Save button, and
/// there should not be one, because the only way to judge a theme is to
/// look at it. The window this tab is in repaints too, so the tab is its
/// own preview.
///
/// The palette is this tab's own copy, edited here and handed to the
/// backend whole, like the Files tab's editor registry: in the settings
/// window, [SettingsBackend.settings] is a copy that trails each write by
/// a round trip.
class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({
    super.key,
    required this.backend,
    required this.systemFonts,
  });

  final SettingsBackend backend;

  /// The installed families behind the interface font's picker.
  final SystemFonts systemFonts;

  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

/// What the Colours section calls each slot.
const Map<ThemeSlot, String> _slotLabels = {
  ThemeSlot.surface: 'Surface',
  ThemeSlot.sidebar: 'Sidebar',
  ThemeSlot.raised: 'Headers and bars',
  ThemeSlot.text: 'Text',
  ThemeSlot.secondaryText: 'Secondary text',
  ThemeSlot.hairline: 'Lines',
  ThemeSlot.selection: 'Selection',
  ThemeSlot.online: 'Online',
  ThemeSlot.offline: 'Offline',
  ThemeSlot.connecting: 'Connecting',
  ThemeSlot.unknown: 'Unknown',
};

const List<ThemeSlot> _colourSlots = [
  ThemeSlot.surface,
  ThemeSlot.sidebar,
  ThemeSlot.raised,
  ThemeSlot.text,
  ThemeSlot.secondaryText,
  ThemeSlot.hairline,
  ThemeSlot.selection,
];

const List<ThemeSlot> _statusSlots = [
  ThemeSlot.online,
  ThemeSlot.offline,
  ThemeSlot.connecting,
  ThemeSlot.unknown,
];

/// The ANSI colours' names, in [ThemeTerminalColors.ansi]'s order.
const List<String> _ansiNames = [
  'Black',
  'Red',
  'Green',
  'Yellow',
  'Blue',
  'Magenta',
  'Cyan',
  'White',
  'Bright black',
  'Bright red',
  'Bright green',
  'Bright yellow',
  'Bright blue',
  'Bright magenta',
  'Bright cyan',
  'Bright white',
];

/// A preset tile's minimum width: two to a row on a phone, four or so in
/// the settings window.
const double _presetTileMinWidth = 148;
const double _presetGap = 10;

/// The corner a preset tile draws at its preset's own scale, so the grid
/// previews the corners as well as the colours.
const double _presetTileRadius = 8;

/// Below this the corner slider says "Square" rather than a percentage.
const double _squareCornerScale = 0.01;

class _AppearanceSettingsState extends State<AppearanceSettings> {
  late ThemePalette _palette = widget.backend.settings.themePalette;
  late ThemeModePreference _mode = widget.backend.settings.themeMode;

  /// Colours handed back to Automatic this session, so switching one off
  /// Automatic again returns what it was rather than starting over. Not
  /// persisted: it is an undo for a click, not a second copy of the theme.
  /// Cleared by anything that replaces the theme wholesale (a preset, a
  /// paste, a reset), which is not what it undoes.
  final Map<ThemeSlot, Color> _setAside = {};
  ThemeTerminalColors? _terminalSetAside;

  late final TextEditingController _font = TextEditingController(
    text: _palette.fontFamily ?? '',
  );

  /// One write in flight at a time; see [_persist].
  bool _writing = false;
  bool _dirty = false;

  @override
  void dispose() {
    _font.dispose();
    super.dispose();
  }

  /// What Automatic colours follow here, whatever the palette.
  Brightness get _automatic =>
      automaticBrightness(MediaQuery.platformBrightnessOf(context), _mode);

  /// The brightness the palette is drawn at.
  Brightness get _drawnAt => resolveBrightness(
    _palette,
    MediaQuery.platformBrightnessOf(context),
    _mode,
  );

  /// Writes the palette and mode as they are now, one write at a time.
  ///
  /// The controls write through on every change — a corner drag is dozens a
  /// second — and each write is a settings save, and in the settings window
  /// a round trip to the app as well. Changes that land while one is in
  /// flight fold into a single write after it, of whatever is current then,
  /// rather than queueing one each. Finishes even if the tab is closed
  /// mid-drag, so the last value is the one that sticks.
  Future<void> _persist() async {
    if (_writing) {
      _dirty = true;
      return;
    }
    _writing = true;
    try {
      do {
        _dirty = false;
        try {
          await widget.backend.setAppearance(_palette, _mode);
        } catch (e) {
          if (mounted) {
            showTopToastIn(context, message: 'Appearance not saved: $e');
          }
        }
      } while (_dirty);
    } finally {
      _writing = false;
    }
  }

  void _replace(ThemePalette palette) {
    if (palette == _palette) return;
    setState(() => _palette = palette);
    unawaited(_persist());
  }

  /// An edit to one value: the result is named for what it now matches.
  void _edit(ThemePalette palette) => _replace(palette.relabelled());

  /// A whole theme at once — a preset, a paste, the reset.
  void _adopt(ThemePalette palette) {
    _setAside.clear();
    _terminalSetAside = null;
    _font.text = palette.fontFamily ?? '';
    _replace(palette);
  }

  void _setMode(ThemeModePreference mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    unawaited(_persist());
  }

  /// Off Automatic, a slot starts from what it was set aside as, or from
  /// what it draws as right now — so the first change is an adjustment and
  /// not a recovery from black.
  void _setAutomatic(ThemeSlot slot, bool automatic) {
    if (automatic) {
      final current = _palette.slot(slot);
      if (current == null) return;
      _setAside[slot] = current;
      _edit(_palette.withSlot(slot, null));
      return;
    }
    final start =
        _setAside.remove(slot) ??
        SeanceTheme.resolvedSlots(_palette, _automatic)[slot]!;
    _edit(_palette.withSlot(slot, start));
  }

  Future<Color?> _pick(
    String label,
    Color initial, {
    bool allowAlpha = false,
  }) => showColorPicker(
    context,
    initial: initial,
    title: label,
    allowAlpha: allowAlpha,
  );

  Future<void> _pickSlot(ThemeSlot slot, Color current) async {
    final picked = await _pick(
      _slotLabels[slot]!,
      current,
      allowAlpha: slot.allowsAlpha,
    );
    if (picked == null || !mounted) return;
    _edit(_palette.withSlot(slot, picked));
  }

  Future<void> _pickAccent() async {
    final picked = await _pick('Accent', _palette.accent);
    if (picked == null || !mounted) return;
    _edit(_palette.copyWith(accent: picked));
  }

  void _setOwnTerminal(bool own) {
    if (own) {
      _edit(
        _palette.withTerminal(
          _terminalSetAside ??
              SeanceTerminalThemes.toColors(
                SeanceTerminalThemes.builtIn(_drawnAt),
              ),
        ),
      );
      return;
    }
    _terminalSetAside = _palette.terminal;
    _edit(_palette.withTerminal(null));
  }

  Future<void> _pickTerminal(
    String label,
    Color current,
    ThemeTerminalColors Function(ThemeTerminalColors colors, Color picked)
    apply, {
    bool allowAlpha = false,
  }) async {
    final picked = await _pick(label, current, allowAlpha: allowAlpha);
    final colors = _palette.terminal;
    if (picked == null || colors == null || !mounted) return;
    _edit(_palette.withTerminal(apply(colors, picked)));
  }

  void _commitFont() {
    final family = _font.text.trim();
    if (family == (_palette.fontFamily ?? '')) return;
    _edit(_palette.withFontFamily(family));
  }

  Future<void> _pickFont() async {
    final chosen = await showFontPicker(
      context,
      fonts: widget.systemFonts,
      current: _font.text.trim(),
      title: 'Interface font',
      filter: FontPickerFilter.all,
      builtInLabel: 'Use system default',
    );
    if (chosen == null || !mounted) return;
    _font.text = chosen;
    _commitFont();
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(
        text: const JsonEncoder.withIndent('  ').convert(_palette.toJson()),
      ),
    );
    if (mounted) showTopToastIn(context, message: 'Theme copied.');
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    final pasted = text == null ? null : ThemePalette.tryParse(text);
    if (pasted == null) {
      showTopToastIn(
        context,
        message:
            'The clipboard does not hold a theme. Copy one with Copy theme '
            'first.',
      );
      return;
    }
    _adopt(pasted);
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset the theme?'),
        content: Text(
          'Every colour, the terminal colours, the font and the corners go '
          'back to the ${ThemePresets.initial.name} theme. The mode stays as '
          'it is.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _adopt(ThemePresets.initial);
  }

  @override
  Widget build(BuildContext context) {
    final resolved = SeanceTheme.resolvedSlots(_palette, _automatic);
    final current = _palette.matchingPreset;
    return SettingsPage(
      storageKey: const PageStorageKey('appearance-settings'),
      children: [
        const SettingsSectionHeader(
          'Theme',
          helpTitle: 'Themes',
          help:
              'A theme is kept on this device only and never syncs. To use '
              'one elsewhere, copy it here and paste it into Séance on the '
              'other device.',
        ),
        _PresetGrid(selected: current, automatic: _automatic, onPick: _adopt),
        const _Footnote(
          'Picking a theme copies its colours here. It is a starting point, '
          'not a mode, so everything below stays yours to change.',
        ),
        const Divider(height: 40),
        const SettingsSectionHeader('Mode'),
        ..._modeSection(),
        const Divider(height: 40),
        const SettingsSectionHeader(
          'Colours',
          helpTitle: 'Automatic colours',
          help:
              'Automatic colours are the light or dark neutrals Séance '
              'ships with, as the mode picks them. Once you give the theme a '
              'surface of its own, they are mixed from that surface and the '
              'text instead. Lines and the selection may be translucent.',
        ),
        _ColourRow(
          label: 'Accent',
          color: _palette.accent,
          onPick: _pickAccent,
        ),
        for (final slot in _colourSlots) _slotRow(slot, resolved),
        const Divider(height: 40),
        const SettingsSectionHeader('Status colours'),
        for (final slot in _statusSlots) _slotRow(slot, resolved),
        const _Footnote(
          'Each status also keeps its own shape and its name, so these '
          'colours never have to say it alone.',
        ),
        const Divider(height: 40),
        const SettingsSectionHeader(
          'Terminal colours',
          helpTitle: 'Terminal colours',
          help:
              'Terminals use these while their Colors setting on the General '
              'tab is "Follow the app theme". Turned off, they use '
              "Séance's built-in dark or light terminal colours.",
        ),
        ..._terminalSection(),
        const Divider(height: 40),
        const SettingsSectionHeader('Shape and type'),
        ..._shapeSection(),
        const Divider(height: 40),
        const SettingsSectionHeader('Share'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _copy,
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: const Text('Copy theme'),
            ),
            OutlinedButton.icon(
              onPressed: _paste,
              icon: const Icon(Icons.paste_outlined, size: 18),
              label: const Text('Paste theme'),
            ),
          ],
        ),
        const _Footnote(
          'Copies the theme as text you can keep or send. Pasting reads '
          'what it can and leaves everything else at the default.',
        ),
        const Divider(height: 40),
        const SettingsSectionHeader('Start over'),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: _reset,
              child: Text('Reset to ${ThemePresets.initial.name}'),
            ),
            Text(
              current == null
                  ? 'Using your own colours.'
                  : 'Using ${current.name}.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _modeSection() {
    final ownSurface = _palette.surface != null;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'Automatic colours follow',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      SegmentedButton<ThemeModePreference>(
        segments: const [
          ButtonSegment(
            value: ThemeModePreference.system,
            icon: Icon(Icons.brightness_auto_outlined),
            label: Text('System'),
          ),
          ButtonSegment(
            value: ThemeModePreference.light,
            icon: Icon(Icons.light_mode_outlined),
            label: Text('Light'),
          ),
          ButtonSegment(
            value: ThemeModePreference.dark,
            icon: Icon(Icons.dark_mode_outlined),
            label: Text('Dark'),
          ),
        ],
        selected: {_mode},
        // A surface of its own decides the brightness, so no mode can
        // change what is drawn; offering the choice would be a control that
        // does nothing.
        onSelectionChanged: ownSurface
            ? null
            : (selection) => _setMode(selection.single),
      ),
      if (ownSurface)
        _Footnote(
          'This theme has its own surface, so it is always '
          '${_drawnAt == Brightness.dark ? 'dark' : 'light'}. Set Surface to '
          'Automatic to choose a mode.',
        ),
    ];
  }

  Widget _slotRow(ThemeSlot slot, Map<ThemeSlot, Color> resolved) {
    final label = _slotLabels[slot]!;
    final automatic = _palette.slot(slot) == null;
    final shown = _palette.slot(slot) ?? resolved[slot]!;
    return _ColourRow(
      label: label,
      color: shown,
      automatic: automatic,
      onAutomaticChanged: (value) => _setAutomatic(slot, value),
      onPick: () => _pickSlot(slot, shown),
    );
  }

  List<Widget> _terminalSection() {
    final colors = _palette.terminal;
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text("Use the theme's terminal colours"),
        subtitle: const Text('Off, terminals keep the built-in colours.'),
        value: colors != null,
        onChanged: _setOwnTerminal,
      ),
      if (colors != null) ...[
        _ColourRow(
          label: 'Background',
          color: colors.background,
          onPick: () => _pickTerminal(
            'Background',
            colors.background,
            (c, picked) => c.copyWith(background: picked),
          ),
        ),
        _ColourRow(
          label: 'Text',
          color: colors.foreground,
          onPick: () => _pickTerminal(
            'Text',
            colors.foreground,
            (c, picked) => c.copyWith(foreground: picked),
          ),
        ),
        _ColourRow(
          label: 'Cursor',
          color: colors.cursor,
          onPick: () => _pickTerminal(
            'Cursor',
            colors.cursor,
            (c, picked) => c.copyWith(cursor: picked),
          ),
        ),
        _ColourRow(
          label: 'Selection',
          color: colors.selection,
          onPick: () => _pickTerminal(
            'Selection',
            colors.selection,
            (c, picked) => c.copyWith(selection: picked),
            allowAlpha: true,
          ),
        ),
        const SizedBox(height: 8),
        _AnsiGrid(
          colors: colors,
          onPick: (index) => _pickTerminal(
            _ansiNames[index],
            colors.ansi[index],
            (c, picked) => c.withAnsi(index, picked),
          ),
        ),
        const SizedBox(height: 12),
        _TerminalPreview(colors: colors),
      ],
    ];
  }

  List<Widget> _shapeSection() {
    final scale = _palette.cornerScale;
    final cornerLabel = scale <= _squareCornerScale
        ? 'Square'
        : '${(scale * 100).round()}%';
    return [
      TextField(
        controller: _font,
        decoration: InputDecoration(
          labelText: 'Interface font',
          hintText: 'System default',
          helperText: 'Terminals and code keep their monospace font.',
          // Only where there is an installed collection to read, like the
          // terminal font's field on General.
          suffixIcon: widget.systemFonts.isSupported
              ? IconButton(
                  tooltip: 'Choose an installed font',
                  icon: const Icon(Icons.font_download_outlined),
                  onPressed: _pickFont,
                )
              : null,
        ),
        onSubmitted: (_) => _commitFont(),
        onTapOutside: (_) {
          // Overriding onTapOutside replaces TextField's default handler, so
          // the dismissal it would have done has to be done here.
          FocusManager.instance.primaryFocus?.unfocus();
          _commitFont();
        },
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          const Text('Corners'),
          Expanded(
            child: Slider(
              min: ThemePalette.minCornerScale,
              max: ThemePalette.maxCornerScale,
              divisions: 40,
              value: scale,
              label: cornerLabel,
              // The text beside the slider is a sibling, not its label:
              // without this a screen reader says "65%" and never of what.
              semanticFormatterCallback: (_) => 'Corners $cornerLabel',
              onChanged: (value) =>
                  _edit(_palette.copyWith(cornerScale: value)),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              cornerLabel,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    ];
  }
}

/// A line of small print under a section's controls.
class _Footnote extends StatelessWidget {
  const _Footnote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One colour: its name, an Automatic box where it may be Automatic, and a
/// swatch that opens the picker.
class _ColourRow extends StatelessWidget {
  const _ColourRow({
    required this.label,
    required this.color,
    required this.onPick,
    this.automatic,
    this.onAutomaticChanged,
  });

  final String label;

  /// What the swatch shows: the colour set, or what Automatic draws now.
  final Color color;
  final VoidCallback onPick;

  /// Null for a colour that cannot be Automatic.
  final bool? automatic;
  final ValueChanged<bool>? onAutomaticChanged;

  @override
  Widget build(BuildContext context) {
    final automatic = this.automatic;
    final onAutomaticChanged = this.onAutomaticChanged;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          if (automatic != null && onAutomaticChanged != null)
            InkWell(
              onTap: () => onAutomaticChanged(!automatic),
              borderRadius: BorderRadius.circular(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: automatic,
                    semanticLabel: '$label: Automatic',
                    onChanged: (value) => onAutomaticChanged(value ?? false),
                  ),
                  const ExcludeSemantics(child: Text('Automatic')),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          _SwatchButton(
            color: color,
            tooltip: automatic == true
                ? 'Choose a $label colour (now Automatic)'
                : 'Choose the $label colour',
            onPressed: onPick,
          ),
        ],
      ),
    );
  }
}

class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    required this.color,
    required this.tooltip,
    required this.onPressed,
    this.size = 28,
  });

  final Color color;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Merged, tooltip inside: a Tooltip's own annotation above the button
    // would merge into whatever node is above it, which for these rows is
    // the page, and every swatch would say every other's name.
    return MergeSemantics(
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          value: formatThemeColor(color),
          excludeSemantics: true,
          onTap: onPressed,
          child: InkWell(
            onTap: onPressed,
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(size / 6),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: ColorSwatchBox(color: color, size: size),
            ),
          ),
        ),
      ),
    );
  }
}

/// The presets as small pictures of themselves: surface, accent, name and
/// the four status colours — which is what actually differs between two
/// themes that both read as "dark blue" in a list of names.
class _PresetGrid extends StatelessWidget {
  const _PresetGrid({
    required this.selected,
    required this.automatic,
    required this.onPick,
  });

  final ThemePalette? selected;

  /// What a preset that leaves its surface Automatic would be drawn at.
  final Brightness automatic;
  final ValueChanged<ThemePalette> onPick;

  /// What each preset looks like at a brightness, in [ThemePresets.all]'s
  /// order. Worked out once per run: the presets never change, the tab
  /// rebuilds on every edit, and each look seeds a Material colour scheme.
  static final Map<Brightness, List<Map<ThemeSlot, Color>>> _looks = {};

  @override
  Widget build(BuildContext context) {
    final looks = _looks.putIfAbsent(
      automatic,
      () => [
        for (final preset in ThemePresets.all)
          SeanceTheme.resolvedSlots(preset, automatic),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns =
            ((width + _presetGap) / (_presetTileMinWidth + _presetGap))
                .floor()
                .clamp(1, ThemePresets.all.length);
        final tileWidth = (width - _presetGap * (columns - 1)) / columns;
        return Wrap(
          spacing: _presetGap,
          runSpacing: _presetGap,
          children: [
            for (final (i, preset) in ThemePresets.all.indexed)
              SizedBox(
                width: tileWidth,
                child: _PresetTile(
                  preset: preset,
                  colours: looks[i],
                  selected: selected?.name == preset.name,
                  onTap: () => onPick(preset),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.colours,
    required this.selected,
    required this.onTap,
  });

  final ThemePalette preset;
  final Map<ThemeSlot, Color> colours;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(
      _presetTileRadius * preset.cornerScale,
    );
    final text = colours[ThemeSlot.text]!;
    // Merged with the tooltip inside, as in [_SwatchButton].
    return MergeSemantics(
      child: Tooltip(
        message: 'Use the ${preset.name} theme',
        child: Semantics(
          button: true,
          selected: selected,
          child: Material(
            color: colours[ThemeSlot.surface],
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(
                color: selected ? preset.accent : colours[ThemeSlot.hairline]!,
                width: selected ? 2 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            color: preset.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            preset.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // In the preset's own text colour: the tile is
                            // drawn in the preset's colours, and Terminal's
                            // name in the app's black would vanish on it.
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: text,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: preset.accent,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        for (final (i, slot) in _statusSlots.indexed) ...[
                          if (i > 0) const SizedBox(width: 3),
                          Expanded(
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: colours[slot],
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sixteen ANSI colours as two rows of eight, normal over bright.
class _AnsiGrid extends StatelessWidget {
  const _AnsiGrid({required this.colors, required this.onPick});

  final ThemeTerminalColors colors;
  final ValueChanged<int> onPick;

  static const int _perRow = 8;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var row = 0; row < 2; row++)
          Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  row == 0 ? 'Normal' : 'Bright',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (var column = 0; column < _perRow; column++)
                Builder(
                  builder: (context) {
                    final index = row * _perRow + column;
                    return _SwatchButton(
                      color: colors.ansi[index],
                      size: 24,
                      tooltip: 'Choose the ${_ansiNames[index]} colour',
                      onPressed: () => onPick(index),
                    );
                  },
                ),
            ],
          ),
      ],
    );
  }
}

/// A few words of shell output in the terminal colours: a prompt, an
/// error, a warning, a success — the colours a terminal mostly shows.
class _TerminalPreview extends StatelessWidget {
  const _TerminalPreview({required this.colors});

  final ThemeTerminalColors colors;

  @override
  Widget build(BuildContext context) {
    final ansi = colors.ansi;
    TextSpan span(String text, Color color) => TextSpan(
      text: text,
      style: TextStyle(color: color),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(SeanceChrome.of(context).corner(6)),
      ),
      child: Text.rich(
        TextSpan(
          style: TextStyle(
            color: colors.foreground,
            fontFamily: SeanceTheme.monoFallback.first,
            fontFamilyFallback: SeanceTheme.monoFallback,
            fontSize: 13,
          ),
          children: [
            span('deploy@web', ansi[2]),
            span(':', colors.foreground),
            span('~/site', ansi[4]),
            span(r'$ make', colors.foreground),
            const TextSpan(text: '\n'),
            span('error:', ansi[1]),
            span(' missing target\n', colors.foreground),
            span('warning:', ansi[3]),
            span(' 2 files skipped\n', colors.foreground),
            span('ok', ansi[6]),
            span(' 14 passed ', colors.foreground),
            span('(0.8 s)', ansi[5]),
          ],
        ),
        semanticsLabel: 'Terminal colours preview',
      ),
    );
  }
}
