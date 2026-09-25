import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme_palette.dart';

/// Picks a colour: hue, saturation and brightness sliders, and a hex box.
///
/// Returns the chosen colour, or null if the dialog was dismissed. [preview]
/// draws the colour the way it will be used (a server's badge, say) beside
/// the hex box; without one the dialog shows a plain swatch. [allowAlpha]
/// adds an opacity slider and lets the box take `RRGGBBAA` — for colours
/// drawn over something else, like a divider or a selection. [note] is a
/// line under the sliders.
Future<Color?> showColorPicker(
  BuildContext context, {
  required Color initial,
  String title = 'Custom colour',
  bool allowAlpha = false,
  Widget Function(BuildContext context, Color color)? preview,
  String? note,
}) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _ColorPickerDialog(
      initial: initial,
      title: title,
      allowAlpha: allowAlpha,
      preview: preview,
      note: note,
    ),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  final Color initial;
  final String title;
  final bool allowAlpha;
  final Widget Function(BuildContext context, Color color)? preview;
  final String? note;

  const _ColorPickerDialog({
    required this.initial,
    required this.title,
    required this.allowAlpha,
    required this.preview,
    required this.note,
  });

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  /// The colour, exactly as handed in or typed. What the dialog returns.
  late Color _color = _allowed(widget.initial);

  /// The same colour as three sliders (four with alpha): hue, saturation
  /// and brightness are the axes people think in, and each gets a track
  /// painted with what it will do — which an RGB slider cannot offer. Held
  /// beside [_color] rather than derived from it on every build, because
  /// the derivation forgets: a grey has no hue, so a hue chosen and then
  /// desaturated would snap to zero the moment saturation hit the floor.
  /// And [_color] is not derived from this either, so a value typed or
  /// handed in comes back without a rounding trip through the sliders'
  /// floating point.
  late HSVColor _hsv = HSVColor.fromColor(_color);

  late final TextEditingController _hex = TextEditingController(
    text: _hexOf(_color),
  );

  /// Set while the hex box holds something that is not a colour, so the
  /// sliders keep the last good value rather than following garbage.
  bool _hexInvalid = false;

  bool get _alpha => widget.allowAlpha;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  /// [color] as this dialog may return it: opaque unless it takes alpha.
  Color _allowed(Color color) => _alpha ? color : color.withAlpha(0xFF);

  /// The hex digits of [color], without the `#` the field shows as a
  /// prefix: six, or eight when it is translucent and may be.
  String _hexOf(Color color) => formatThemeColor(_allowed(color)).substring(1);

  /// The colour the box's [text] names, or null. Only the full lengths
  /// count: the box filters to hex digits, so a short value is simply one
  /// still being typed.
  Color? _parse(String text) {
    final digits = text.trim();
    if (digits.length == 6 || (_alpha && digits.length == 8)) {
      return parseThemeColor(digits);
    }
    return null;
  }

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
    final color = _parse(text);
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
    final note = widget.note;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                widget.preview?.call(context, color) ??
                    ColorSwatchBox(color: color, size: 48),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _hex,
                    onChanged: _hexChanged,
                    maxLength: _alpha ? 8 : 6,
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
                      errorText: _hexInvalid
                          ? (_alpha
                                ? 'Six or eight hex digits'
                                : 'Six hex digits')
                          : null,
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
                _hsv.withSaturation(0).withAlpha(1).toColor(),
                _hsv.withSaturation(1).withAlpha(1).toColor(),
              ],
              semanticValue: '${(_hsv.saturation * 100).round()} percent',
              onChanged: (s) => _setHsv(_hsv.withSaturation(s)),
            ),
            _ChannelSlider(
              label: 'Brightness',
              value: _hsv.value,
              max: 1,
              colors: [
                _hsv.withValue(0).withAlpha(1).toColor(),
                _hsv.withValue(1).withAlpha(1).toColor(),
              ],
              semanticValue: '${(_hsv.value * 100).round()} percent',
              onChanged: (v) => _setHsv(_hsv.withValue(v)),
            ),
            if (_alpha)
              _ChannelSlider(
                label: 'Opacity',
                value: _hsv.alpha,
                max: 1,
                colors: [
                  _hsv.withAlpha(0).toColor(),
                  _hsv.withAlpha(1).toColor(),
                ],
                semanticValue: '${(_hsv.alpha * 100).round()} percent',
                onChanged: (a) => _setHsv(_hsv.withAlpha(a)),
              ),
            if (note != null) ...[
              const SizedBox(height: 4),
              Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
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

/// A colour as a small rounded square, with a checkerboard showing through
/// where it is translucent, so a tint reads as a tint rather than as a
/// paler colour.
class ColorSwatchBox extends StatelessWidget {
  const ColorSwatchBox({super.key, required this.color, this.size = 24});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(size / 6);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: scheme.outline),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: CustomPaint(
          painter: _CheckerPainter(
            light: scheme.surface,
            dark: scheme.onSurface.withValues(alpha: 0.18),
            translucent: color.a < 1,
          ),
          child: ColoredBox(color: color),
        ),
      ),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter({
    required this.light,
    required this.dark,
    required this.translucent,
  });

  final Color light;
  final Color dark;
  final bool translucent;

  static const double _cell = 6;

  @override
  void paint(Canvas canvas, Size size) {
    if (!translucent) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = light);
    final paint = Paint()..color = dark;
    for (var y = 0; y * _cell < size.height; y++) {
      for (var x = y.isEven ? 0 : 1; x * _cell < size.width; x += 2) {
        canvas.drawRect(
          Rect.fromLTWH(x * _cell, y * _cell, _cell, _cell),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) =>
      old.light != light || old.dark != dark || old.translucent != translucent;
}

/// One axis of the colour, on a track painted with the colours the axis runs
/// through at the other axes' current values.
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
