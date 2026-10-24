import 'package:flutter/material.dart';

import 'followup_models.dart';

/// Small dependency-free line chart of patient-reported values. Dashed lines mark the expected range
/// (clinic-only); points outside it are amber. Not a verification of anything.
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.points, required this.unit, this.normalMin, this.normalMax, this.height = 120});
  final List<TrendPoint> points;
  final String unit;
  final double? normalMin;
  final double? normalMax;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final outside = points.where((p) => p.outside).length;
    return Semantics(
      label: 'Trend of ${points.length} patient-reported values${outside > 0 ? ', $outside $followupFlagText' : ''}',
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: TrendPainter(points: points, normalMin: normalMin, normalMax: normalMax, line: cs.primary, flagged: Colors.amber.shade700, guide: cs.outline, label: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

class TrendPainter extends CustomPainter {
  TrendPainter({required this.points, this.normalMin, this.normalMax, required this.line, required this.flagged, required this.guide, required this.label});
  final List<TrendPoint> points;
  final double? normalMin;
  final double? normalMax;
  final Color line;
  final Color flagged;
  final Color guide;
  final Color label;

  /// Pixel position of each point inside [size] (exposed for tests).
  List<Offset> layout(Size size) {
    if (points.isEmpty) return const [];
    const padL = 36.0, padR = 10.0, padT = 10.0, padB = 10.0;
    final (lo, hi) = _range();
    final t0 = points.first.measuredAt.millisecondsSinceEpoch;
    final span = points.last.measuredAt.millisecondsSinceEpoch - t0;
    final w = size.width - padL - padR, h = size.height - padT - padB;
    double x(int i) => points.length == 1 || span == 0
        ? padL + (points.length == 1 ? w / 2 : i * w / (points.length - 1))
        : padL + (points[i].measuredAt.millisecondsSinceEpoch - t0) / span * w;
    double y(double v) => hi == lo ? padT + h / 2 : padT + h - (v - lo) / (hi - lo) * h;
    return [for (var i = 0; i < points.length; i++) Offset(x(i), y(points[i].value))];
  }

  (double, double) _range() {
    final vs = [for (final p in points) p.value, ?normalMin, ?normalMax];
    var lo = vs.reduce((a, b) => a < b ? a : b), hi = vs.reduce((a, b) => a > b ? a : b);
    final pad = (hi - lo) * 0.1;
    return (lo - pad, hi + pad);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final (lo, hi) = _range();
    final offs = layout(size);
    const padT = 10.0, padB = 10.0;
    double y(double v) => hi == lo ? size.height / 2 : padT + (size.height - padT - padB) - (v - lo) / (hi - lo) * (size.height - padT - padB);

    void guideLine(double v) {
      final yy = y(v);
      final p = Paint()..color = guide..strokeWidth = 1;
      for (double x = 36; x < size.width - 10; x += 8) {
        canvas.drawLine(Offset(x, yy), Offset(x + 4, yy), p);
      }
      final tp = TextPainter(text: TextSpan(text: _short(v), style: TextStyle(color: label, fontSize: 10)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(0, yy - tp.height / 2));
    }

    if (normalMin != null) guideLine(normalMin!);
    if (normalMax != null) guideLine(normalMax!);

    final path = Path()..moveTo(offs.first.dx, offs.first.dy);
    for (final o in offs.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, Paint()..color = line..style = PaintingStyle.stroke..strokeWidth = 2);
    for (var i = 0; i < offs.length; i++) {
      canvas.drawCircle(offs[i], 4, Paint()..color = points[i].outside ? flagged : line);
    }
  }

  static String _short(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  @override
  bool shouldRepaint(TrendPainter old) => old.points != points || old.normalMin != normalMin || old.normalMax != normalMax || old.line != line;
}
