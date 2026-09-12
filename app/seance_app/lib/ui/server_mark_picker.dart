import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../services/badge_image.dart';
import 'server_appearance.dart';

/// A starting point for the emoji tab, so the feature is usable without going
/// hunting in the OS picker. Not a substitute for one: the field beside it
/// takes anything, which is what makes the curated list a convenience rather
/// than a limit.
const List<String> kCuratedServerEmoji = [
  '\u{1F5A5}\u{FE0F}', '\u{1F4BB}', '\u{1F4F1}', '\u{2328}\u{FE0F}',
  '\u{1F5A8}\u{FE0F}', '\u{1F4BE}', '\u{1F4BF}', '\u{1F5C4}\u{FE0F}',
  '\u{1F9F0}', '\u{1F9F1}', '\u{2601}\u{FE0F}', '\u{1F310}',
  '\u{1F4E1}', '\u{1F6F0}\u{FE0F}', '\u{1F517}', '\u{1F4F6}',
  '\u{1F50C}', '\u{1F50B}', '\u{1F512}', '\u{1F511}',
  '\u{1F6E1}\u{FE0F}', '\u{1F510}', '\u{1FAAA}', '\u{1F680}',
  '\u{1F525}', '\u{26A1}', '\u{2699}\u{FE0F}', '\u{1F527}',
  '\u{1F6E0}\u{FE0F}', '\u{1F9EA}', '\u{1F52C}', '\u{1F4C8}',
  '\u{1F4CA}', '\u{1F3AF}', '\u{1F3C1}', '\u{1F6A7}',
  '\u{26A0}\u{FE0F}', '\u{2705}', '\u{274C}', '\u{1F9F9}',
  '\u{1F50D}', '\u{1F4E6}', '\u{1F5C3}\u{FE0F}', '\u{1F433}',
  '\u{1F427}', '\u{1F40D}', '\u{1F980}', '\u{2615}',
  '\u{1F375}', '\u{1F3E0}', '\u{1F3E2}', '\u{1F3ED}',
  '\u{1F3DD}\u{FE0F}', '\u{1F332}', '\u{1F5FC}', '\u{1F419}',
  '\u{1F98A}', '\u{1F422}', '\u{1F41D}', '\u{1F989}',
  '\u{1F408}', '\u{1F415}', '\u{1F981}', '\u{1F43C}',
  '\u{1F986}', '\u{1F3AE}', '\u{1F3AC}', '\u{1F3B5}',
  '\u{1F4F7}', '\u{1F4DA}', '\u{1F4DD}', '\u{1F5DE}\u{FE0F}',
  '\u{1F4B0}', '\u{1F6D2}', '\u{1F4B3}', '\u{1F9E0}',
  '\u{1F916}', '\u{1F47B}', '\u{1F383}', '\u{1F480}',
  '\u{1F9D9}', '\u{1F52E}', '\u{2728}', '\u{1F31F}',
  '\u{2B50}', '\u{1F308}', '\u{1F340}',
];

/// Picks what a server is marked with: a built-in glyph, an emoji, or an
/// imported image.
///
/// Returns the new mark, or null if the picker was dismissed. [accent] is the
/// colour currently chosen for the server, so every candidate is previewed on
/// the background it will actually sit on.
Future<ServerMark?> showServerMarkPicker(
  BuildContext context, {
  required ServerMark current,
  required ServerColor? accent,
  /// Test seam: reads the bytes of an image the user chose. Defaults to the
  /// platform file picker, which a widget test cannot drive.
  @visibleForTesting Future<Uint8List?> Function()? readImage,
}) {
  return showDialog<ServerMark>(
    context: context,
    builder: (_) => _MarkPickerDialog(
      current: current,
      accent: accent,
      readImage: readImage ?? _pickImageBytes,
    ),
  );
}

/// The bytes of an image chosen from the platform picker, or null if the user
/// cancelled. `withData` because the bytes are re-encoded rather than kept:
/// there is nothing to stream to, and on Android a document provider may have
/// no path at all (see AGENTS.md on file_picker).
Future<Uint8List?> _pickImageBytes() async {
  final result = await FilePicker.pickFiles(
    type: FileType.image,
    withData: true,
  );
  final files = result?.files ?? const [];
  if (files.isEmpty) return null;
  final bytes = files.first.bytes;
  if (bytes == null) {
    // `withData` was asked for and the picker produced a file without any:
    // reported on some Android document providers. Returning null here would
    // be read as a cancel and the dialog would sit there having silently done
    // nothing, so it is raised for the caller's handler to show.
    throw Exception('the file picker returned no image bytes');
  }
  return bytes;
}

class _MarkPickerDialog extends StatelessWidget {
  final ServerMark current;
  final ServerColor? accent;
  final Future<Uint8List?> Function() readImage;

  const _MarkPickerDialog({
    required this.current,
    required this.accent,
    required this.readImage,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Server mark'),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        // Bounded so the dialog is the same shape whichever tab is open and
        // however many glyphs a later version adds. A fixed height is safe
        // because `SizedBox` clamps its own request to the incoming
        // constraints: measured clean from 390x420 up, and with the soft
        // keyboard taking anything up to 520 of an 800-tall phone.
        width: 460,
        height: 520,
        child: DefaultTabController(
          // Opens on the tab the current mark came from, so the picker shows
          // what is in force rather than always starting at the glyphs.
          initialIndex: switch (current) {
            ServerGlyphMark() => 0,
            ServerEmojiMark() => 1,
            ServerImageMark() => 2,
          },
          length: 3,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: 'Icons'),
                  Tab(text: 'Emoji'),
                  Tab(text: 'Image'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _IconsTab(accent: accent, current: current),
                    _EmojiTab(accent: accent, current: current),
                    _ImageTab(
                      accent: accent,
                      current: current,
                      readImage: readImage,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// The built-in glyphs, under their headings, with a search over labels and
/// the extra terms each glyph carries.
class _IconsTab extends StatefulWidget {
  final ServerColor? accent;
  final ServerMark current;

  const _IconsTab({required this.accent, required this.current});

  @override
  State<_IconsTab> createState() => _IconsTabState();
}

class _IconsTabState extends State<_IconsTab> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The glyph shown as selected: only when a glyph is what is in force. An
  /// emoji or an image keeps a glyph as its fallback, and marking that one as
  /// chosen would say the badge shows it when it does not.
  ServerIcon? get _selected => switch (widget.current) {
    ServerGlyphMark(:final icon) => icon,
    _ => null,
  };

  bool get _glyphInForce => widget.current is ServerGlyphMark;

  @override
  Widget build(BuildContext context) {
    final query = _search.text;
    final sections = [
      for (final (heading, icons) in serverIconGroups)
        if (icons.any((i) => serverIconMatches(i, query)))
          (
            heading,
            [for (final i in icons) if (serverIconMatches(i, query)) i],
          ),
    ];
    final showDefault = serverIconMatches(null, query);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Search icons — try k8s, psql, prod…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: sections.isEmpty && !showDefault
                ? const Center(child: Text('No icon matches.'))
                : ListView(
                    children: [
                      if (showDefault)
                        _IconSection(
                          heading: 'Default',
                          icons: const [null],
                          accent: widget.accent,
                          selected: _selected,
                          selectable: _glyphInForce,
                        ),
                      for (final (heading, icons) in sections)
                        _IconSection(
                          heading: heading,
                          icons: icons,
                          accent: widget.accent,
                          selected: _selected,
                          selectable: _glyphInForce,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _IconSection extends StatelessWidget {
  final String heading;
  final List<ServerIcon?> icons;
  final ServerColor? accent;
  final ServerIcon? selected;

  /// Whether [selected] should be drawn as chosen at all — false when the
  /// badge is showing an emoji or an image rather than a glyph.
  final bool selectable;

  const _IconSection({
    required this.heading,
    required this.icons,
    required this.accent,
    required this.selected,
    required this.selectable,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(heading, style: Theme.of(context).textTheme.labelMedium),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final icon in icons)
              _MarkChoice(
                accent: accent,
                mark: ServerGlyphMark(icon),
                label: serverIconLabel(icon),
                selected: selectable && icon == selected,
              ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// The emoji tab: a field that takes anything the OS can produce, plus a
/// starting grid.
class _EmojiTab extends StatefulWidget {
  final ServerColor? accent;
  final ServerMark current;

  const _EmojiTab({required this.accent, required this.current});

  @override
  State<_EmojiTab> createState() => _EmojiTabState();
}

class _EmojiTabState extends State<_EmojiTab> {
  late final TextEditingController _typed = TextEditingController(
    text: switch (widget.current) {
      ServerEmojiMark(:final emoji) => emoji,
      _ => '',
    },
  );

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  /// How to reach the OS emoji picker here. Worth saying: this is a text
  /// field, and the shortcut is the thing that makes it usable.
  String get _shortcutHint {
    if (kIsWeb) return '';
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS => 'Press Control-Command-Space for the '
          'system emoji picker.',
      TargetPlatform.windows => 'Press Windows-. for the system emoji picker.',
      TargetPlatform.linux => 'Your desktop may offer an emoji picker with '
          'Control-Shift-E or Control-.',
      _ => 'Switch your keyboard to emoji.',
    };
  }

  ServerIcon? get _fallback => widget.current.fallback;

  void _commit(String emoji) {
    final mark = ServerEmojiMark(emoji, fallback: _fallback);
    // Validated through the protocol rather than here, so the picker cannot
    // offer something a record would then refuse.
    if (mark.stored.emoji == null) return;
    Navigator.of(context).pop(mark);
  }

  @override
  Widget build(BuildContext context) {
    final typed = normalizeServerEmoji(_typed.text);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _typed,
                  onChanged: (_) => setState(() {}),
                  // Normalized first, exactly as the Use button's own gate
                  // does: otherwise "rocket then a space" works by button and
                  // silently does nothing by Enter.
                  onSubmitted: (value) {
                    final normalized = normalizeServerEmoji(value);
                    if (normalized != null) _commit(normalized);
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Any emoji',
                    border: const OutlineInputBorder(),
                    errorText: _typed.text.trim().isEmpty || typed != null
                        ? null
                        : 'One emoji, please.',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: typed == null ? null : () => _commit(typed),
                child: const Text('Use'),
              ),
            ],
          ),
          // The prose scrolls with the grid rather than sitting above it. Kept
          // out of the Column's fixed part because it wraps to three or four
          // lines on a phone: pinned, it starved the Expanded below and the
          // column overflowed (measured 16 pixels at 390x800 with the
          // keyboard up). The field stays pinned, which is the part being
          // typed into.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Text(
                    // No leading space when the hint is empty, which is what
                    // web reports.
                    '${_shortcutHint.isEmpty ? '' : '$_shortcutHint '}'
                    'An emoji is drawn with the system\u2019s own emoji font, '
                    'so a device without one shows a box — the icon chosen '
                    'under Icons is what it falls back to there.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Divider(height: 24),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final emoji in kCuratedServerEmoji)
                        _MarkChoice(
                          accent: widget.accent,
                          mark: ServerEmojiMark(emoji, fallback: _fallback),
                          label: emoji,
                          selected: widget.current is ServerEmojiMark &&
                              normalizeServerEmoji(_typed.text) == emoji,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The image tab: import a file, see what will be stored, or take it off.
class _ImageTab extends StatefulWidget {
  final ServerColor? accent;
  final ServerMark current;
  final Future<Uint8List?> Function() readImage;

  const _ImageTab({
    required this.accent,
    required this.current,
    required this.readImage,
  });

  @override
  State<_ImageTab> createState() => _ImageTabState();
}

class _ImageTabState extends State<_ImageTab> {
  bool _busy = false;
  String? _error;

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final source = await widget.readImage();
      if (source == null) return;
      // The dialog can be dismissed while the platform picker covers the
      // app; skip decoding an image nobody will be shown.
      if (!mounted) return;
      final result = await encodeBadgeImage(
        source,
        maxBytes: kMaxServerIconImageBytes,
      );
      if (!mounted) return;
      final image = result.image;
      if (image == null) {
        setState(() => _error = _message(result.failure!));
        return;
      }
      Navigator.of(context).pop(
        ServerImageMark(image.png, fallback: widget.current.fallback),
      );
    } on Exception catch (error) {
      // The platform picker throws for a document provider that went away, a
      // permission the user revoked, and several other cases. Without this the
      // spinner would clear and nothing else would happen, while the error
      // surfaced only in the console. Bound and logged, because otherwise a
      // platform-picker crash, a revoked permission and the no-bytes case all
      // read identically and there is nothing to debug a report with.
      debugPrint('server mark image import failed: $error');
      if (mounted) {
        setState(() => _error = 'That file could not be opened. Try another.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What went wrong, in terms of what to do about it.
  String _message(BadgeImageFailure failure) => switch (failure) {
    BadgeImageFailure.tooLarge =>
      'That file is too big to read. Crop or export it smaller first.',
    BadgeImageFailure.undecodable =>
      'That file could not be read as an image.',
    BadgeImageFailure.incompressible =>
      'That image would not fit in a server record even at badge size. Try a '
          'simpler picture — a logo rather than a photograph.',
  };

  @override
  Widget build(BuildContext context) {
    final image = widget.current is ServerImageMark
        ? widget.current as ServerImageMark
        : null;
    // Scrollable: the explanation below is several lines, and at large text
    // scales or in a short window the column would otherwise overflow.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ServerBadge(
                color: widget.accent,
                mark: widget.current,
                size: 64,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  image == null
                      ? 'No image on this server yet.'
                      : 'This server carries an image.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _import,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.image_outlined),
                label: Text(image == null ? 'Choose image…' : 'Replace image…'),
              ),
              if (image != null)
                OutlinedButton.icon(
                  // Back to the glyph the image was keeping as its fallback,
                  // which is also what an older build was drawing all along.
                  onPressed: () => Navigator.of(context).pop(
                    ServerGlyphMark(widget.current.fallback),
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove image'),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            // A live region, or an import failure is visible only to someone
            // watching the dialog: the spinner clears and a screen reader says
            // nothing at all.
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          const Divider(height: 24),
          Text(
            'The image is cropped square, stored at $kBadgeImageSide pixels, '
            'and travels inside this server\u2019s own settings — so it '
            'reaches '
            'your other devices with everything else about the server, and '
            'never arrives without it. Anything larger than a badge can show '
            'would only be paid for on every sync.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// One candidate mark, previewed on the colour the server is actually using.
class _MarkChoice extends StatelessWidget {
  final ServerColor? accent;
  final ServerMark mark;
  final String label;
  final bool selected;

  static const double _size = 36;

  const _MarkChoice({
    required this.accent,
    required this.mark,
    required this.label,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: () => Navigator.of(context).pop(mark),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 2.5,
            ),
          ),
          padding: const EdgeInsets.all(2),
          child: Semantics(
            label: label,
            selected: selected,
            button: true,
            child: ServerBadge(color: accent, mark: mark, size: _size),
          ),
        ),
      ),
    );
  }
}
