import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import 'server_appearance.dart';

/// Picks a colour of the user's own for a server's accent.
///
/// Returns the chosen colour, or null if the dialog was dismissed. [mark] is
/// what the server is currently marked with, so the preview shows the badge
/// the colour will actually be drawn under rather than an empty swatch.
Future<Color?> showServerColorPicker(
  BuildContext context, {
  required Color initial,
  required ServerMark mark,
}) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _ColorPickerDialog(initial: initial, mark: mark),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  final Color initial;
  final ServerMark mark;

  const _ColorPickerDialog({required this.initial, required this.mark});

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  /// The colour, exactly as handed in or typed. What the dialog returns.
  late Color _color = widget.initial;

  /// The same colour as three sliders: hue, saturation and brightness are the
  /// axes people think in, and each gets a track painted with what it will
  /// do — which an RGB slider cannot offer. Held beside [_color] rather than
  /// derived from it on every build, because the derivation forgets: a grey
  /// has no hue, so a hue chosen and then desaturated would snap to zero the
  /// moment saturation hit the floor. And [_color] is not derived from this
  /// either, so a value typed or handed in comes back without a rounding
  /// trip through the sliders' floating point.
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  late final TextEditingController _hex = TextEditingController(
    text: _hexOf(widget.initial),
  );

  /// Set while the hex box holds something that is not a colour, so the
  /// sliders keep the last good value rather than following garbage.
  bool _hexInvalid = false;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  /// The six hex digits of [color], without the `#` the field shows as a
  /// prefix.
  static String _hexOf(Color color) =>
      formatServerCustomColor(color).substring(1);

  void _setHsv(HSVColor hsv) {
    final color = hsv.toColor();
    setState(() {
      _hsv = hsv;
      _color = color;
      _hexInvalid = false;
    });
    // Only when the text differs: rewriting an equal value would still move
    // the caret, which matters if the user is mid-edit in the box.
    final hex = _hexOf(color);
    if (_hex.text.toUpperCase() != hex) {
      _hex.value = TextEditingValue(
        text: hex,
        selection: TextSelection.collapsed(offset: hex.length),
      );
    }
  }

  void _hexChanged(String text) {
    final color = parseServerCustomColor(text);
    if (color == null) {
      setState(() => _hexInvalid = text.trim().isNotEmpty);
      return;
    }
    // Not through `_setHsv`, which would write the hex back and re-case the
    // digits under the caret.
    setState(() {
      _color = color;
      _hsv = HSVColor.fromColor(color);
      _hexInvalid = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _color;
    return AlertDialog(
      title: const Text('Custom colour'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                // Previewed as the badge the list will draw, in this theme:
                // the fill and the foreground are derived from the colour
                // rather than painted raw, and this is where that shows.
                ServerBadge(
                  tint: ServerTint(custom: color),
                  mark: widget.mark,
                  size: 48,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _hex,
                    onChanged: _hexChanged,
                    maxLength: 6,
                    // Hex digits only, and none of a phone keyboard's help:
                    // "beef" and "face" are colours here, not words to
                    // correct, and a pasted `#1E90FF` loses its `#` on the
                    // way in rather than being refused for it.
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                    ],
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      labelText: 'Hex',
                      prefixText: '#',
                      counterText: '',
                      errorText: _hexInvalid ? 'Six hex digits' : null,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _ChannelSlider(
              label: 'Hue',
              value: _hsv.hue,
              max: 360,
              colors: [
                for (var hue = 0; hue <= 360; hue += 60)
                  HSVColor.fromAHSV(1, hue.toDouble(), 1, 1).toColor(),
              ],
              semanticValue: '${_hsv.hue.round()} degrees',
              onChanged: (hue) => _setHsv(_hsv.withHue(hue)),
            ),
            _ChannelSlider(
              label: 'Saturation',
              value: _hsv.saturation,
              max: 1,
              colors: [
                _hsv.withSaturation(0).toColor(),
                _hsv.withSaturation(1).toColor(),
              ],
              semanticValue: '${(_hsv.saturation * 100).round()} percent',
              onChanged: (s) => _setHsv(_hsv.withSaturation(s)),
            ),
            _ChannelSlider(
              label: 'Brightness',
              value: _hsv.value,
              max: 1,
              colors: [
                _hsv.withValue(0).toColor(),
                _hsv.withValue(1).toColor(),
              ],
              semanticValue: '${(_hsv.value * 100).round()} percent',
              onChanged: (v) => _setHsv(_hsv.withValue(v)),
            ),
            const SizedBox(height: 4),
            Text(
              'Drawn as picked, with the mark kept legible on it in both '
              'themes. Devices running an older version show the nearest of '
              'the named colours instead.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
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
        FilledButton(
          // Disabled while the box holds something that is not a colour:
          // confirming would silently hand back the last good value under
          // text that says otherwise. Read when pressed rather than captured
          // at build: a keystroke in the hex box and the press can land in
          // the same frame.
          onPressed: _hexInvalid
              ? null
              : () => Navigator.of(context).pop(_color),
          child: const Text('Use colour'),
        ),
      ],
    );
  }
}

/// One axis of the colour, on a track painted with the colours the axis runs
/// through at the other two axes' current values.
class _ChannelSlider extends StatelessWidget {
  final String label;
  final double value;
  final double max;
  final List<Color> colors;

  /// What a screen reader says the value is: "180 degrees" rather than the
  /// bare percentage a Slider announces by default, which for hue is wrong.
  final String semanticValue;
  final ValueChanged<double> onChanged;

  const _ChannelSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.colors,
    required this.semanticValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 14,
            trackShape: _GradientTrackShape(colors),
            // The track is the colour; a tinted halo over it would muddy the
            // very thing being chosen.
            overlayShape: SliderComponentShape.noOverlay,
          ),
          child: Slider(
            value: value,
            max: max,
            label: semanticValue,
            semanticFormatterCallback: (_) => semanticValue,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// A slider track that is a gradient rather than an active/inactive pair.
///
/// The gradient runs in the reading direction, so the track and the thumb
/// agree on which end is which under a right-to-left locale.
class _GradientTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  final List<Color> colors;

  const _GradientTrackShape(this.colors);

  @override
  bool get isRounded => true;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.isEmpty) return;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: AlignmentDirectional.centerStart,
        end: AlignmentDirectional.centerEnd,
        colors: colors,
      ).createShader(rect, textDirection: textDirection);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      paint,
    );
  }
}
