import 'package:flutter/material.dart';

import '../l10n/app_language.dart';

/// Result of the visual color picker. Two terminal outcomes are kept
/// distinguishable, mirroring the former `_FolderColorChoice` /
/// `_CustomColorChoice` contract: an explicit color, or the explicit
/// "no color" choice. A `null` [Future] result means the dialog was cancelled.
sealed class VisualColorResult {
  const VisualColorResult();
}

/// The user picked a concrete color (always full alpha).
class VisualColorValue extends VisualColorResult {
  const VisualColorValue(this.color);
  final Color color;
}

/// The user picked "no color" (clear the stored preference).
class VisualColorClear extends VisualColorResult {
  const VisualColorClear();
}

/// Opens the shared visual RGB picker used by folders and notes.
///
/// [initial] pre-selects the current color; `null` starts in the "no color"
/// state. [title] labels the dialog. Resolves to a [VisualColorResult] when
/// the user applies a choice, or `null` when the dialog is cancelled.
Future<VisualColorResult?> showVisualColorPicker(
  BuildContext context, {
  Color? initial,
  String? title,
}) {
  return showDialog<VisualColorResult>(
    context: context,
    builder: (_) => _VisualColorPickerDialog(initial: initial, title: title),
  );
}

class _VisualColorPickerDialog extends StatefulWidget {
  const _VisualColorPickerDialog({this.initial, this.title});
  final Color? initial;
  final String? title;

  @override
  State<_VisualColorPickerDialog> createState() =>
      _VisualColorPickerDialogState();
}

class _VisualColorPickerDialogState extends State<_VisualColorPickerDialog> {
  static const double _svWidth = 240;
  static const double _svHeight = 160;
  static const double _hueWidth = 240;
  static const double _hueHeight = 24;

  late double _hue;
  late double _saturation;
  late double _value;
  late bool _none;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial == null) {
      _none = true;
      _hue = 0;
      _saturation = 1;
      _value = 1;
    } else {
      final hsv = HSVColor.fromColor(initial);
      _none = false;
      _hue = hsv.hue;
      _saturation = hsv.saturation;
      _value = hsv.value;
    }
  }

  Color get _color => HSVColor.fromAHSV(1, _hue, _saturation, _value).toColor();

  String get _hex {
    final rgb = _color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  void _selectSv(Offset local) {
    final x = (local.dx / _svWidth).clamp(0.0, 1.0);
    final y = (local.dy / _svHeight).clamp(0.0, 1.0);
    setState(() {
      _none = false;
      _saturation = x;
      _value = 1 - y;
    });
  }

  void _selectHue(Offset local) {
    final x = (local.dx / _hueWidth).clamp(0.0, 1.0);
    setState(() {
      _none = false;
      _hue = x * 360;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title ?? tr('Kolor', 'Color')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SvSquare(
            hue: _hue,
            saturation: _saturation,
            value: _value,
            onSelect: _selectSv,
          ),
          const SizedBox(height: 14),
          _HueSlider(hue: _hue, onSelect: _selectHue),
          const SizedBox(height: 16),
          Row(
            children: [
              _Preview(color: _none ? null : _color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _none ? tr('Brak koloru', 'No color') : _hex,
                  key: const Key('color-picker-hex'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontFamily: 'RobotoMono',
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('color-picker-none'),
          onPressed: () => setState(() => _none = true),
          child: Text(tr('Brak koloru', 'No color')),
        ),
        TextButton(
          key: const Key('color-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Anuluj', 'Cancel')),
        ),
        FilledButton(
          key: const Key('color-picker-apply'),
          onPressed: () => Navigator.pop(
            context,
            _none ? const VisualColorClear() : VisualColorValue(_color),
          ),
          child: Text(tr('Zapisz', 'Save')),
        ),
      ],
    );
  }
}

/// Saturation/value field: the full hue palette, with a white-to-hue ramp on
/// the horizontal (saturation) axis and a transparent-to-black ramp on the
/// vertical (value) axis. Clicking or dragging picks the color at that point.
class _SvSquare extends StatelessWidget {
  const _SvSquare({
    required this.hue,
    required this.saturation,
    required this.value,
    required this.onSelect,
  });

  final double hue;
  final double saturation;
  final double value;
  final ValueChanged<Offset> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _VisualColorPickerDialogState._svWidth,
      height: _VisualColorPickerDialogState._svHeight,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => onSelect(event.localPosition),
        onPointerMove: (event) => onSelect(event.localPosition),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                key: const Key('color-picker-sv'),
                painter: _SvPainter(hue: hue),
              ),
            ),
            Positioned(
              left: saturation * _VisualColorPickerDialogState._svWidth - 8,
              top: (1 - value) * _VisualColorPickerDialogState._svHeight - 8,
              child: IgnorePointer(
                child: Container(
                  key: const Key('color-picker-cursor'),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: HSVColor.fromAHSV(
                      1,
                      hue,
                      saturation,
                      value,
                    ).toColor(),
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 2),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SvPainter extends CustomPainter {
  _SvPainter({required this.hue});
  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hueColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    canvas.drawRect(rect, Paint()..color = hueColor);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Colors.white, Colors.transparent],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SvPainter oldDelegate) => oldDelegate.hue != hue;
}

/// Full 0-360° hue ramp; clicking or dragging anywhere selects the hue at that
/// horizontal position.
class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hue, required this.onSelect});

  final double hue;
  final ValueChanged<Offset> onSelect;

  @override
  Widget build(BuildContext context) {
    const width = _VisualColorPickerDialogState._hueWidth;
    const height = _VisualColorPickerDialogState._hueHeight;
    return SizedBox(
      width: width,
      height: height,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => onSelect(event.localPosition),
        onPointerMove: (event) => onSelect(event.localPosition),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                key: const Key('color-picker-hue'),
                painter: _HuePainter(),
              ),
            ),
            Positioned(
              left: hue / 360 * width - 6,
              top: -3,
              child: IgnorePointer(
                child: Container(
                  width: 12,
                  height: height + 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HuePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Color(0xffff0000),
            Color(0xffffff00),
            Color(0xff00ff00),
            Color(0xff00ffff),
            Color(0xff0000ff),
            Color(0xffff00ff),
            Color(0xffff0000),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_HuePainter oldDelegate) => false;
}

/// Selected color swatch, or a "no color" glyph when [color] is null.
class _Preview extends StatelessWidget {
  const _Preview({this.color});
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('color-picker-preview'),
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color ?? Colors.transparent,
        border: Border.all(
          color: color == null ? Colors.white38 : Colors.white70,
          width: 2,
        ),
      ),
      child: color == null
          ? const Icon(Icons.block, size: 18, color: Colors.white70)
          : null,
    );
  }
}
