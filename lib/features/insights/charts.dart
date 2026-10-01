import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/insights/analytics.dart';

/// One slice/row of a breakdown.
class Slice {
  const Slice({required this.label, required this.value, required this.color, this.id});

  final String label;
  final int value;
  final Color color;
  final String? id;
}

/// Donut with the total in the hole. Thin ring, 2px surface gaps between
/// slices; identity is carried by the ranked legend beside it (never colour
/// alone), so the donut itself stays unlabeled.
class Donut extends StatefulWidget {
  const Donut({required this.slices, required this.centerLabel, this.size = 168, super.key});

  final List<Slice> slices;
  final String centerLabel;
  final double size;

  @override
  State<Donut> createState() => _DonutState();
}

class _DonutState extends State<Donut> {
  int? _touched;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final total = widget.slices.fold(0, (s, x) => s + x.value);
    final touched = _touched == null || _touched! >= widget.slices.length ? null : widget.slices[_touched!];
    return SizedBox.square(
      dimension: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PieChart(
            PieChartData(
              startDegreeOffset: -90,
              sectionsSpace: 2,
              centerSpaceRadius: widget.size / 2 - 18,
              pieTouchData: PieTouchData(
                touchCallback: (e, r) => setState(() {
                  _touched = e.isInterestedForInteractions ? r?.touchedSection?.touchedSectionIndex : null;
                  if (_touched == -1) _touched = null;
                }),
              ),
              sections: [
                if (total == 0)
                  PieChartSectionData(value: 1, color: c.hairline, radius: 14, showTitle: false)
                else
                  for (var i = 0; i < widget.slices.length; i++)
                    PieChartSectionData(
                      value: widget.slices[i].value.toDouble(),
                      color: widget.slices[i].color,
                      radius: i == _touched ? 18 : 14,
                      showTitle: false,
                    ),
              ],
            ),
            duration: JMotion.reduced(context) ? Duration.zero : JMotion.medium,
            curve: JMotion.ease,
          ),
          Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  (touched?.label ?? widget.centerLabel).toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: JType.microLabel.copyWith(color: c.inkFaint),
                ),
                const SizedBox(height: 6),
                FittedBox(
                  child: Text(
                    Money.whole(touched?.value ?? total),
                    style: JType.panelMetric.copyWith(fontSize: 22, color: c.ink),
                  ),
                ),
                if (touched != null && total > 0)
                  Text(
                    '${(touched.value / total * 100).round()}%',
                    style: JType.chipLabel.copyWith(color: c.inkMuted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ranked list with a thin magnitude bar per row, value and share as text.
class RankedBars extends StatelessWidget {
  const RankedBars({required this.slices, this.onTap, super.key});

  final List<Slice> slices;
  final void Function(Slice)? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final max = slices.fold(0, (m, s) => math.max(m, s.value));
    final total = slices.fold(0, (m, s) => m + s.value);
    return Column(
      children: [
        for (final s in slices)
          InkWell(
            onTap: onTap == null ? null : () => onTap!(s),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      JDot(s.color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: JType.bodyStrong.copyWith(color: c.ink),
                        ),
                      ),
                      Text(
                        total == 0 ? '' : '${(s.value / total * 100).round()}%',
                        style: JType.chipLabel.copyWith(color: c.inkFaint),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 84,
                        child: Text(
                          Money.whole(s.value),
                          textAlign: TextAlign.right,
                          style: JType.rowMetric.copyWith(fontSize: 13, color: c.ink),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: JProgress(value: max == 0 ? 0 : s.value / max, color: s.color),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Legend row for multi-series charts.
class ChartLegend extends StatelessWidget {
  const ChartLegend({required this.items, super.key});

  final List<(String, Color)> items;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return Wrap(
      spacing: JSpace.lg,
      runSpacing: JSpace.xs,
      children: [
        for (final (label, color) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 6),
              Text(label.toUpperCase(), style: JType.microLabel.copyWith(color: c.inkMuted)),
            ],
          ),
      ],
    );
  }
}

double _niceMax(int maxCents) {
  if (maxCents <= 0) return 10000;
  final v = maxCents / 100;
  final mag = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  final n = v / mag;
  final step = n <= 1
      ? 1
      : n <= 2
      ? 2
      : n <= 5
      ? 5
      : 10;
  return step * mag * 100;
}

BarTouchData _barTouch(JColors c, String Function(int group, int rod) text) => BarTouchData(
  touchTooltipData: BarTouchTooltipData(
    getTooltipColor: (_) => c.isDark ? c.raised : c.navBar,
    tooltipBorderRadius: BorderRadius.circular(8),
    tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    fitInsideHorizontally: true,
    fitInsideVertically: true,
    getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
      text(gi, ri),
      JType.chipLabel.copyWith(color: c.isDark ? c.ink : const Color(0xFFFBF5EA)),
    ),
  ),
);

FlTitlesData _titles(JColors c, List<MonthPoint> pts, double maxY) => FlTitlesData(
  topTitles: const AxisTitles(),
  rightTitles: const AxisTitles(),
  leftTitles: AxisTitles(
    sideTitles: SideTitles(
      showTitles: true,
      reservedSize: 44,
      interval: maxY / 2,
      getTitlesWidget: (v, meta) => SideTitleWidget(
        meta: meta,
        child: Text(Money.compact(v.round()), style: JType.microLabel.copyWith(color: c.inkFaint)),
      ),
    ),
  ),
  bottomTitles: AxisTitles(
    sideTitles: SideTitles(
      showTitles: true,
      reservedSize: 24,
      getTitlesWidget: (v, meta) => SideTitleWidget(
        meta: meta,
        child: Text(
          Day.monthShort(pts[v.toInt()].month).toUpperCase(),
          style: JType.microLabel.copyWith(color: c.inkFaint),
        ),
      ),
    ),
  ),
);

FlGridData _grid(JColors c, double maxY) => FlGridData(
  drawVerticalLine: false,
  horizontalInterval: maxY / 2,
  getDrawingHorizontalLine: (_) => FlLine(color: c.hairline, strokeWidth: 1),
);

/// Income vs spending per month, grouped bars on one axis.
class IncomeExpenseBars extends StatelessWidget {
  const IncomeExpenseBars({required this.points, super.key});

  final List<MonthPoint> points;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final maxY = _niceMax(points.fold(0, (m, p) => math.max(m, math.max(p.income, p.expense))));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Green/red fails deutan separation (ΔE 3.2 dark), so the chart uses the
        // validated categorical pair; the legend names each series.
        ChartLegend(items: [('Income', seriesColor(c, 0)), ('Spent', seriesColor(c, 1))]),
        const SizedBox(height: JSpace.lg),
        SizedBox(
          height: 180,
          child: BarChart(
            BarChartData(
              maxY: maxY,
              alignment: BarChartAlignment.spaceAround,
              borderData: FlBorderData(show: false),
              gridData: _grid(c, maxY),
              titlesData: _titles(c, points, maxY),
              barTouchData: _barTouch(c, (g, r) {
                final p = points[g];
                return '${Day.monthShort(p.month)} · ${r == 0 ? 'in' : 'out'} ${Money.format(r == 0 ? p.income : p.expense)}';
              }),
              barGroups: [
                for (var i = 0; i < points.length; i++)
                  BarChartGroupData(
                    x: i,
                    barsSpace: 2,
                    barRods: [
                      BarChartRodData(
                        toY: points[i].income.toDouble(),
                        color: seriesColor(c, 0),
                        width: 10,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                      ),
                      BarChartRodData(
                        toY: points[i].expense.toDouble(),
                        color: seriesColor(c, 1),
                        width: 10,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                      ),
                    ],
                  ),
              ],
            ),
            duration: JMotion.reduced(context) ? Duration.zero : JMotion.medium,
          ),
        ),
      ],
    );
  }
}

/// Personal + household spending per month, stacked with a 2px gap.
class ScopeStackBars extends StatelessWidget {
  const ScopeStackBars({required this.points, super.key});

  final List<MonthPoint> points;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final maxY = _niceMax(points.fold(0, (m, p) => math.max(m, p.personal + p.household)));
    // The 2px gap is drawn by leaving a sliver of the stack unfilled.
    final gap = maxY * 0.012;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChartLegend(items: [('Personal', c.brand), ('Household', c.household)]),
        const SizedBox(height: JSpace.lg),
        SizedBox(
          height: 180,
          child: BarChart(
            BarChartData(
              maxY: maxY,
              alignment: BarChartAlignment.spaceAround,
              borderData: FlBorderData(show: false),
              gridData: _grid(c, maxY),
              titlesData: _titles(c, points, maxY),
              barTouchData: _barTouch(c, (g, _) {
                final p = points[g];
                return '${Day.monthShort(p.month)}\nPersonal ${Money.whole(p.personal)}\nHousehold ${Money.whole(p.household)}';
              }),
              barGroups: [
                for (var i = 0; i < points.length; i++)
                  () {
                    final p = points[i].personal.toDouble();
                    final h = points[i].household.toDouble();
                    final both = p > 0 && h > 0;
                    return BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: p + h + (both ? gap : 0),
                          width: 18,
                          color: Colors.transparent,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                          rodStackItems: [
                            BarChartRodStackItem(0, p, c.brand),
                            BarChartRodStackItem(p + (both ? gap : 0), p + h + (both ? gap : 0), c.household),
                          ],
                        ),
                      ],
                    );
                  }(),
              ],
            ),
            duration: JMotion.reduced(context) ? Duration.zero : JMotion.medium,
          ),
        ),
      ],
    );
  }
}

/// Net worth month by month — one series, so no legend; the card title names
/// it. 2px line, a soft area to anchor it, crosshair tooltip on touch.
class NetWorthLine extends StatelessWidget {
  const NetWorthLine({required this.points, super.key});

  final List<(DateTime, int)> points;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    if (points.isEmpty) return const SizedBox(height: 180);
    final values = points.map((p) => p.$2).toList();
    final hi = values.reduce(math.max);
    final lo = values.reduce(math.min);
    final pad = math.max((hi - lo) * 0.15, 1000);
    final minY = (lo - pad).toDouble();
    final maxY = (hi + pad).toDouble();
    final line = seriesColor(c, 2);
    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: (maxY - minY) / 2,
            getDrawingHorizontalLine: (_) => FlLine(color: c.hairline, strokeWidth: 1),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 60,
                interval: (maxY - minY) / 2,
                // Only the bounds: an off-zero range makes interval ticks
                // land beside the max label and collide.
                getTitlesWidget: (v, meta) => v != meta.min && v != meta.max
                    ? const SizedBox.shrink()
                    : SideTitleWidget(
                        meta: meta,
                        child: Text(Money.compact(v.round()), style: JType.microLabel.copyWith(color: c.inkFaint)),
                      ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: points.length > 8 ? 2 : 1,
                getTitlesWidget: (v, meta) {
                  final i = v.round();
                  if (i < 0 || i >= points.length || v != i) return const SizedBox.shrink();
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      Day.monthShort(points[i].$1).toUpperCase(),
                      style: JType.microLabel.copyWith(color: c.inkFaint),
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            getTouchedSpotIndicator: (bar, idx) => [
              for (final _ in idx)
                TouchedSpotIndicatorData(
                  FlLine(color: c.hairlineStrong, strokeWidth: 1),
                  FlDotData(
                    getDotPainter: (spot, _, _, _) =>
                        FlDotCirclePainter(radius: 4, color: line, strokeWidth: 2, strokeColor: c.surface),
                  ),
                ),
            ],
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => c.isDark ? c.raised : c.navBar,
              tooltipBorderRadius: BorderRadius.circular(8),
              fitInsideHorizontally: true,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    '${Day.monthShort(points[s.x.round()].$1)} · ${Money.whole(s.y.round())}',
                    JType.chipLabel.copyWith(color: c.isDark ? c.ink : const Color(0xFFFBF5EA)),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [for (var i = 0; i < points.length; i++) FlSpot(i.toDouble(), points[i].$2.toDouble())],
              color: line,
              isCurved: true,
              curveSmoothness: 0.2,
              preventCurveOverShooting: true,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [line.withValues(alpha: 0.18), line.withValues(alpha: 0)],
                ),
              ),
            ),
          ],
        ),
        duration: JMotion.reduced(context) ? Duration.zero : JMotion.medium,
      ),
    );
  }
}
