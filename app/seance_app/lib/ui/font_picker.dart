import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import '../services/system_fonts.dart';
import '../theme.dart';

/// The host's installed families, or [NoSystemFonts] where there is no
/// user-managed font collection to read.
///
/// Mobile and web are named explicitly rather than left to
/// [SfntSystemFonts] reporting no roots: the comment and the guard should say
/// the same thing, and an app on Android or iOS sees the faces the system
/// gives it rather than a directory it may walk. Matched to the guard style in
/// `window_state.dart`.
SystemFonts hostSystemFonts() {
  if (kIsWeb) return const NoSystemFonts();
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => const NoSystemFonts(),
    _ => SfntSystemFonts(),
  };
}

/// What [showFontPicker] returns for "no family — use the app's own monospace
/// stack", which is what an empty `AppSettings.terminalFontFamily` means.
const String kBuiltInFontStack = '';

/// Picks an installed font family, previewing each one in its own face.
///
/// Returns the chosen family, [kBuiltInFontStack] for the built-in stack, or
/// null if the picker was dismissed. Deliberately a companion to the free-text
/// field rather than a replacement: what the OS has registered and what the
/// engine will actually render are not quite the same set (see [SystemFonts]),
/// so a family this cannot offer must stay typeable.
Future<String?> showFontPicker(
  BuildContext context, {
  required SystemFonts fonts,
  required String current,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _FontPickerDialog(fonts: fonts, current: current),
  );
}

class _FontPickerDialog extends StatefulWidget {
  final SystemFonts fonts;
  final String current;

  const _FontPickerDialog({required this.fonts, required this.current});

  @override
  State<_FontPickerDialog> createState() => _FontPickerDialogState();
}

class _FontPickerDialogState extends State<_FontPickerDialog> {
  final _search = TextEditingController();

  /// A terminal wants a fixed-pitch face, so the list starts filtered. The
  /// flag the filter reads is the font's own declaration and some faces get it
  /// wrong, which is why it can be turned off rather than being the only view.
  bool _monospaceOnly = true;

  late final Future<List<SystemFontFamily>> _families = widget.fonts.families();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<SystemFontFamily> _visible(List<SystemFontFamily> all) {
    final query = _search.text.trim().toLowerCase();
    return [
      for (final family in all)
        if ((!_monospaceOnly || family.monospaced) &&
            (query.isEmpty || family.name.toLowerCase().contains(query)))
          family,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Terminal font'),
      // Bounded so the dialog is the same shape whether the host has four
      // fonts or four hundred, and so the list scrolls rather than the dialog
      // growing past the screen.
      content: SizedBox(
        width: 420,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Filter fonts…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilterChip(
                label: const Text('Monospace only'),
                selected: _monospaceOnly,
                visualDensity: VisualDensity.compact,
                onSelected: (value) =>
                    setState(() => _monospaceOnly = value),
              ),
            ),
            const Divider(),
            Expanded(
              child: FutureBuilder<List<SystemFontFamily>>(
                future: _families,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  // Reading a font collection is a directory walk over files
                  // this build may not understand; a failure is "nothing to
                  // offer", not an error worth a dialog of its own, since the
                  // field behind this one still takes a typed name.
                  final all = snapshot.data ?? const <SystemFontFamily>[];
                  return _FontList(
                    families: _visible(all),
                    current: widget.current,
                    // Distinguishes "this host has none" from "your filter
                    // matched none", which are different things to do next.
                    emptyBecauseFiltered: all.isNotEmpty,
                    onPick: (family) => Navigator.of(context).pop(family),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(kBuiltInFontStack),
          child: const Text('Use built-in stack'),
        ),
      ],
    );
  }
}

class _FontList extends StatelessWidget {
  final List<SystemFontFamily> families;
  final String current;
  final bool emptyBecauseFiltered;
  final ValueChanged<String> onPick;

  const _FontList({
    required this.families,
    required this.current,
    required this.emptyBecauseFiltered,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    if (families.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            emptyBecauseFiltered
                ? 'No font matches. Clear the filter, or turn off '
                      '“Monospace only” — not every fixed-pitch font declares '
                      'itself as one.'
                : 'No installed fonts could be read on this device. Type the '
                      'family name into the field instead.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: families.length,
      itemBuilder: (context, i) {
        final family = families[i];
        final selected = family.name == current;
        return ListTile(
          dense: true,
          selected: selected,
          // The point of the preview: the name drawn in the face it names, so
          // a family is judged rather than guessed at from its name. Fallbacks
          // behind it so a family the engine declines still reads as text.
          title: Text(
            family.name,
            style: TextStyle(
              fontFamily: family.name,
              fontFamilyFallback: SeanceTheme.monoFallback,
            ),
          ),
          subtitle: Text(
            // A sample rather than more prose: what a terminal shows is
            // columns of these, and whether they line up is the question.
            'ILl1 0OQ {}[]()<> —— 123',
            style: TextStyle(
              fontFamily: family.name,
              fontFamilyFallback: SeanceTheme.monoFallback,
            ),
          ),
          trailing: selected ? const Icon(Icons.check) : null,
          onTap: () => onPick(family.name),
        );
      },
    );
  }
}
