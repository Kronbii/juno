import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/plan/forecast.dart';

/// Plan → Cash flow: where spendable money is heading over the next 60 days.
class CashFlowTab extends ConsumerWidget {
  const CashFlowTab({super.key});

  static const days = 60;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    ref.watch(todayProvider); // redraw when the day changes
    final now = clock.now();
    final today = DateTime(now.year, now.month, now.day);
    final recent = ref.watch(
      txQueryProvider(TxQuery(from: Day.of(Day.shift(today, -90)), to: Day.of(today))),
    );
    final ahead = ref.watch(
      txQueryProvider(
        TxQuery(
          from: Day.of(Day.shift(today, 1)),
          to: Day.of(Day.shift(today, days)),
        ),
      ),
    );
    final balances = ref.watch(balancesProvider).value;
    if (recent.value == null || ahead.value == null || balances == null) return const SizedBox(height: 240);
    final cats = ref.watch(categoryMapProvider);
    final rules = ref.watch(recurringProvider).value ?? const <RecurringRule>[];
    final f = forecastCash(
      accounts: ref.watch(allAccountsProvider).value ?? const [],
      balances: balances,
      rules: rules,
      recent: recent.value!,
      ahead: ahead.value!,
      rates: ref.watch(ratesProvider),
      ruleLabels: {for (final r in rules) r.id: r.note.isNotEmpty ? r.note : cats[r.categoryId]?.name ?? 'Recurring'},
      now: now,
    );
    final (lowDay, low) = f.lowest;
    final below = f.firstBelowZero;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (below != null) ...[
          JCard(
            accent: JAccent.expense,
            alert: true,
            title: 'Heads up',
            child: Text(
              'At this pace, spendable money goes below zero around ${Day.short(Day.of(below))}. '
              'Lowest point ${Money.whole(low)} on ${Day.short(Day.of(lowDay))}.',
              style: JType.body.copyWith(fontSize: 14, color: c.ink),
            ),
          ),
          const SizedBox(height: JSpace.gap),
        ],
        JCard(
          title: 'Spendable money',
          trailing: const JPill('Next 60 days'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: JSpace.xl,
                runSpacing: JSpace.md,
                children: [
                  JMicroStat(value: Money.whole(f.start), label: 'Today'),
                  JMicroStat(
                    value: Money.whole(f.end),
                    label: 'In $days days',
                    valueColor: f.end < 0 ? c.expense : null,
                  ),
                  JMicroStat(
                    value: Money.whole(low),
                    label: 'Lowest · ${Day.short(Day.of(lowDay))}',
                    valueColor: low < 0 ? c.expense : null,
                  ),
                ],
              ),
              const SizedBox(height: JSpace.lg),
              ForecastLine(points: f.series),
              const SizedBox(height: JSpace.md),
              Text(
                'Cash, current accounts and cards, without savings. '
                '${f.paceDays > 0 ? 'Takes off your usual ${Money.whole(f.dailyPace)} a day of everyday spending '
                          '(average of the last ${f.paceDays} days, bills excluded), ' : ''}'
                'adds ${Money.whole(f.incomeAhead)} of income due and takes off ${Money.whole(f.billsAhead)} of '
                'bills.${f.complete ? '' : ' Some amounts are left out because an exchange rate is missing.'}',
                style: JType.body.copyWith(fontSize: 12.5, color: c.inkFaint),
              ),
            ],
          ),
        ),
        JSectionLabel(
          'Coming up',
          trailing: Text('${f.events.length}', style: JType.microLabel.copyWith(color: c.inkFaint)),
        ),
        if (f.events.isEmpty)
          Text(
            'Nothing scheduled. Add rent, salary and subscriptions under Recurring and they show here.',
            style: JType.body.copyWith(color: c.inkFaint),
          )
        else
          JGroup(
            children: [
              for (final e in f.events.take(20))
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: JSpace.card, vertical: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 64,
                        child: Text(
                          Day.short(e.day).toUpperCase(),
                          style: JType.microLabel.copyWith(color: c.inkFaint),
                        ),
                      ),
                      Icon(
                        e.ruleId == null ? Icons.event_outlined : categoryIcon('repeat'),
                        size: 16,
                        color: c.inkFaint,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          e.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: JType.rowTitle.copyWith(color: c.ink),
                        ),
                      ),
                      Text(
                        Money.signed(e.usd),
                        style: JType.rowMetric.copyWith(color: e.usd > 0 ? c.income : c.ink),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Daily projected balance. One line; a zero line appears when the range
/// crosses it, so "below zero" is visible at a glance.
class ForecastLine extends StatelessWidget {
  const ForecastLine({required this.points, super.key});

  final List<(DateTime, int)> points;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    if (points.length < 2) return const SizedBox(height: 180);
    final values = points.map((p) => p.$2).toList();
    final hi = values.reduce(math.max);
    final lo = values.reduce(math.min);
    final pad = math.max((hi - lo) * 0.15, 1000);
    final minY = (lo - pad).toDouble();
    final maxY = (hi + pad).toDouble();
    final crosses = minY < 0 && maxY > 0;
    final line = lo < 0 ? c.expense : seriesColor(c, 2);
    final last = points.length - 1;
    String label(int i) => i == 0 ? 'TODAY' : Day.short(Day.of(points[i].$1)).toUpperCase();
    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: last.toDouble(),
          minY: minY,
          maxY: maxY,
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: (maxY - minY) / 2,
            getDrawingHorizontalLine: (_) => FlLine(color: c.hairline, strokeWidth: 1),
          ),
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              if (crosses)
                HorizontalLine(y: 0, color: c.expense.withValues(alpha: 0.6), strokeWidth: 1, dashArray: [4, 4]),
            ],
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 60,
                interval: (maxY - minY) / 2,
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
                interval: 1,
                getTitlesWidget: (v, meta) {
                  final i = v.round();
                  // Start, middle and end only: daily labels would collide.
                  if (v != i || !(i == 0 || i == last ~/ 2 || i == last)) return const SizedBox.shrink();
                  return SideTitleWidget(
                    meta: meta,
                    fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                    child: Text(label(i), style: JType.microLabel.copyWith(color: c.inkFaint)),
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
                    '${Day.short(Day.of(points[s.x.round()].$1))} · ${Money.whole(s.y.round())}',
                    JType.chipLabel.copyWith(color: c.isDark ? c.ink : const Color(0xFFFBF5EA)),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [for (var i = 0; i < points.length; i++) FlSpot(i.toDouble(), points[i].$2.toDouble())],
              color: line,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [line.withValues(alpha: 0.16), line.withValues(alpha: 0)],
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
