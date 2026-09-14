import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'copilot_api.dart';
import 'dashboard_theme.dart';

/// Small native bar/line renderer: no animation, gradients or chart dependency.
/// Values remain unchanged; null values create gaps. The response table exposes
/// exact values alongside this chart, including to assistive technology.
class CopilotChartView extends StatefulWidget {
  const CopilotChartView({super.key, required this.chart});
  final CopilotChart chart;

  @override
  State<CopilotChartView> createState() => _CopilotChartViewState();
}

class _CopilotChartViewState extends State<CopilotChartView> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chart = widget.chart;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(chart.title, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 12, runSpacing: 4, children: [
        for (var i = 0; i < chart.series.length; i++)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 12, height: 3, color: _ChartPainter.colors[i]),
            const SizedBox(width: 4),
            Text(chart.series[i].name,
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        if (chart.unit.isNotEmpty)
          Text('단위: ${chart.unit}',
              style: Theme.of(context).textTheme.bodySmall),
      ]),
      LayoutBuilder(builder: (context, constraints) {
        final width =
            math.max(constraints.maxWidth, 56.0 + chart.labels.length * 96.0);
        return Semantics(
          container: true,
          label: '${chart.type == 'bar' ? '막대' : '선'} 그래프: ${chart.title}. '
              '정확한 값은 아래 표에서 확인할 수 있습니다.',
          image: true,
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              child: CustomPaint(
                key: ValueKey('copilot-${chart.type}-chart'),
                size: Size(width, 220),
                painter: _ChartPainter(chart),
              ),
            ),
          ),
        );
      }),
    ]);
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.chart);
  final CopilotChart chart;
  static const colors = [
    Color(0xff303030),
    Color(0xff707070),
    Color(0xffa0a0a0),
    Color(0xffc0c0c0),
  ];

  void label(Canvas canvas, String text, Offset offset,
      {double width = 88, bool center = false}) {
    final painter = TextPainter(
      text: TextSpan(
          text: text,
          style: const TextStyle(color: DashboardTheme.muted, fontSize: 10)),
      textDirection: TextDirection.ltr,
      textAlign: center ? TextAlign.center : TextAlign.left,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: width);
    painter.paint(canvas,
        center ? Offset(offset.dx - painter.width / 2, offset.dy) : offset);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 48.0;
    const top = 28.0;
    const bottom = 174.0;
    final values = chart.series.expand((s) => s.values).whereType<double>();
    final maxValue = values.fold<double>(0, math.max);
    final scaleMax = maxValue == 0 ? 1.0 : maxValue * 1.15;
    final step = (size.width - left - 8) / chart.labels.length;
    double x(int index) => left + step * (index + .5);
    double y(double value) => bottom - value / scaleMax * (bottom - top);
    final grid = Paint()
      ..color = DashboardTheme.border
      ..strokeWidth = 1;
    for (var tick = 0; tick <= 2; tick++) {
      final value = maxValue * tick / 2;
      final dy = y(value);
      canvas.drawLine(Offset(left, dy), Offset(size.width - 8, dy), grid);
      label(canvas, value.toStringAsPrecision(3), Offset(0, dy - 6), width: 44);
    }
    for (var i = 0; i < chart.labels.length; i++) {
      label(canvas, chart.labels[i], Offset(x(i), bottom + 10), center: true);
    }
    for (var s = 0; s < chart.series.length; s++) {
      final paint = Paint()
        ..color = colors[s]
        ..strokeWidth = 1.5;
      Offset? previous;
      for (var i = 0; i < chart.labels.length; i++) {
        final value = chart.series[s].values[i];
        if (value == null) {
          previous = null;
          continue;
        }
        final point = Offset(x(i), y(value));
        if (chart.type == 'bar') {
          final barWidth = math.min(32.0, step * .6 / chart.series.length);
          final bx = point.dx + (s - (chart.series.length - 1) / 2) * barWidth;
          canvas.drawRect(
              Rect.fromLTRB(
                  bx - barWidth / 2, point.dy, bx + barWidth / 2 - 2, bottom),
              paint);
        } else {
          if (previous != null) canvas.drawLine(previous, point, paint);
          canvas.drawCircle(point, 2.5, paint);
          previous = point;
        }
        if (chart.series.length == 1) {
          label(canvas, value.toStringAsPrecision(3),
              Offset(point.dx, point.dy - 17),
              center: true);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter oldDelegate) => oldDelegate.chart != chart;
}
