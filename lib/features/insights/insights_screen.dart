import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/activity/tx_row.dart';
import 'package:juno/features/home/home_screen.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/insights/charts.dart';

class InsightsScreen extends ConsumerWidget {
  const InsightsScreen({super.key});

  /// Donut and list show this many categories; the rest fold into "Other"
  /// (never a ninth generated hue).
  static const _topN = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final month = ref.watch(selectedMonthProvider);
    final prev = DateTime(month.year, month.month - 1);
    final txs = ref.watch(monthTxProvider(month)).value ?? const <Transaction>[];
    final prevTxs = ref.watch(monthTxProvider(prev)).value ?? const <Transaction>[];
    final trail = ref.watch(trailingTxProvider((month, 6))).value ?? const <Transaction>[];
    final cats = ref.watch(categoryMapProvider);
    final rules = ref.watch(recurringProvider).value ?? const <RecurringRule>[];
    final accts = ref.watch(accountMapProvider);
    final rates = ref.watch(ratesProvider);
    final wide = MediaQuery.sizeOf(context).width >= JSize.wideBreakpoint;

    final s = PeriodSummary.of(txs);
    final pace = MonthPace(month: month, expense: s.expense);
    // Mid-month, compare like with like: the first N days of this month
    // against the first N days of last month, not against all of it.
    final toDate = pace.isCurrent ? Day.of(DateTime(prev.year, prev.month, pace.daysElapsed)) : null;
    final ps = PeriodSummary.of(toDate == null ? prevTxs : prevTxs.where((t) => t.occurredOn.compareTo(toDate) <= 0));
    // A day or two of data makes every comparison shout; wait for a few.
    final comparable = !pace.isCurrent || pace.daysElapsed >= 3;
    final insights = compareInsights(
      current: s,
      previous: comparable ? ps : PeriodSummary.of(const []),
      names: {for (final k in cats.values) k.id: k.name},
      prevLabel: pace.isCurrent ? 'this point in ${Day.month(prev)}' : Day.month(prev),
    );
    final series = monthlySeries(trail, month, 6);

    final ranked = s.rankedCategories;
    final slices = <Slice>[
      for (final e in ranked.take(_topN))
        Slice(
          id: e.key,
          label: cats[e.key]?.name ?? 'Uncategorised',
          value: e.value,
          color: cats[e.key] == null ? otherColor(c) : seriesColor(c, cats[e.key]!.colorIndex),
        ),
      if (ranked.length > _topN)
        Slice(
          label: 'Other',
          value: ranked.skip(_topN).fold(0, (a, e) => a + e.value),
          color: otherColor(c),
        ),
    ];

    final subsMonthly = rules
        .where((r) => r.active && r.type == TxType.expense)
        .fold<double>(
          0,
          (sum, r) =>
              sum + Fx.toUsd(_monthlyEquivalent(r).round(), accts[r.accountId]?.currency ?? baseCurrency, rates),
        )
        .round();

    final kpis = Row(
      children: [
        Expanded(
          child: JMicroStat(value: Money.whole(s.expense), label: 'Spent'),
        ),
        Expanded(
          child: JMicroStat(value: Money.whole(s.income), label: 'Income', valueColor: c.income),
        ),
        Expanded(
          child: JMicroStat(value: Money.whole(pace.avgDaily), label: 'Per day'),
        ),
        if (pace.isCurrent)
          Expanded(
            child: JMicroStat(value: Money.whole(pace.projected), label: 'Projected'),
          ),
      ],
    );

    final breakdown = JCard(
      title: 'Where it went',
      child: s.expense == 0
          ? Text('No spending recorded for ${Day.month(month)}.', style: JType.body.copyWith(color: c.inkMuted))
          : LayoutBuilder(
              builder: (context, box) {
                final side = box.maxWidth > 520;
                final donut = Donut(slices: slices, centerLabel: 'Spent');
                final list = RankedBars(slices: slices);
                return side
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          donut,
                          const SizedBox(width: JSpace.xl),
                          Expanded(child: list),
                        ],
                      )
                    : Column(
                        children: [
                          Center(child: donut),
                          const SizedBox(height: JSpace.lg),
                          list,
                        ],
                      );
              },
            ),
    );

    final feed = JCard(
      title: 'What changed',
      child: insights.isEmpty
          ? Text(
              'Log a few weeks of entries and patterns will show up here.',
              style: JType.body.copyWith(color: c.inkMuted),
            )
          : Column(
              children: [
                for (final i in insights)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Tone is carried by the icon shape, not colour alone.
                        Icon(
                          switch (i.tone) {
                            InsightTone.good => Icons.south_east_rounded,
                            InsightTone.bad => Icons.north_east_rounded,
                            InsightTone.neutral => Icons.circle_outlined,
                          },
                          size: i.tone == InsightTone.neutral ? 10 : 15,
                          color: switch (i.tone) {
                            InsightTone.good => c.income,
                            InsightTone.bad => c.expense,
                            InsightTone.neutral => c.inkFaint,
                          },
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(i.text, style: JType.body.copyWith(fontSize: 14, color: c.ink)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );

    final trend = JCard(
      title: 'Six months · in vs out',
      child: IncomeExpenseBars(points: series),
    );
    final scopeTrend = JCard(
      title: 'Six months · personal vs household',
      child: ScopeStackBars(points: series),
    );

    final merchants = topMerchants(txs);
    final biggest = [...txs.where((t) => t.type == TxType.expense)]..sort((a, b) => b.usd.compareTo(a.usd));

    final lists = JCard(
      title: 'Top places',
      child: merchants.isEmpty
          ? Text(
              'Add notes or import with descriptions to see where you spend most.',
              style: JType.body.copyWith(color: c.inkMuted),
            )
          : Column(
              children: [
                for (final m in merchants)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            m.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: JType.bodyStrong.copyWith(color: c.ink, fontSize: 14),
                          ),
                        ),
                        Text('${m.count}×  ', style: JType.chipLabel.copyWith(color: c.inkFaint)),
                        Text(Money.whole(m.total), style: JType.rowMetric.copyWith(color: c.ink)),
                      ],
                    ),
                  ),
              ],
            ),
    );

    final big = JCard(
      title: 'Biggest entries',
      child: biggest.isEmpty
          ? Text('Nothing yet.', style: JType.body.copyWith(color: c.inkMuted))
          : SlidableAutoCloseBehavior(
              child: Column(children: [for (final t in biggest.take(5)) TxRow(tx: t, showDate: true)]),
            ),
    );

    final subs = JMetricTile(
      accent: JAccent.warn,
      label: 'Recurring costs',
      value: Money.whole(subsMonthly),
      unit: '/ month',
      compact: true,
      caption: subsMonthly == 0
          ? 'Add subscriptions and bills in Plan → Recurring.'
          : '${Money.whole(subsMonthly * 12)} a year across ${rules.where((r) => r.active && r.type == TxType.expense).length} rules',
    );

    final worth = netWorthSeries(
      accounts: ref.watch(allAccountsProvider).value ?? const <Account>[],
      txs: ref.watch(allTxProvider).value ?? const <Transaction>[],
      perUsd: rates,
      last: month,
    );
    final worthNow = worth.isEmpty ? 0 : worth.last.$2;
    final worthDelta = worth.length < 2 ? 0 : worthNow - worth[worth.length - 2].$2;
    final netWorth = JCard(
      title: 'Net worth · 12 months',
      trailing: Text(
        '${Money.whole(worthNow)}  ${worthDelta >= 0 ? '+' : '\u2212'}${Money.whole(worthDelta.abs())} vs last month',
        style: JType.chipLabel.copyWith(color: worthDelta >= 0 ? c.income : c.expense),
      ),
      child: NetWorthLine(points: worth),
    );

    // An entry with two tags counts toward both, so tag totals can exceed
    // the month's spend.
    final byTag = <String, int>{};
    for (final t in txs.where((t) => t.type == TxType.expense)) {
      for (final tag in t.tagList) {
        byTag[tag] = (byTag[tag] ?? 0) + t.usd;
      }
    }
    final tagSlices = (byTag.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .take(8)
        .map((e) => Slice(label: '#${e.key}', value: e.value, color: c.inkMuted))
        .toList();
    final tagsCard = JCard(
      title: 'By tag',
      child: tagSlices.isEmpty
          ? Text(
              'Tag entries (trip, gift, work…) to see spending that cuts across categories.',
              style: JType.body.copyWith(color: c.inkMuted),
            )
          : RankedBars(slices: tagSlices),
    );

    Widget gap() => const SizedBox(height: JSpace.gap);

    return JScreen(
      eyebrow: '03 — Insights',
      title: 'Where it *went*',
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ScopeLens(),
          const SizedBox(height: JSpace.lg),
          _MonthPicker(month: month),
          const SizedBox(height: JSpace.lg),
          kpis,
        ],
      ),
      slivers: [
        SliverToBoxAdapter(
          child: wide
              ? Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: breakdown),
                        const SizedBox(width: JSpace.gap),
                        Expanded(flex: 2, child: Column(children: [feed, gap(), subs])),
                      ],
                    ),
                    gap(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: trend),
                        const SizedBox(width: JSpace.gap),
                        Expanded(child: scopeTrend),
                      ],
                    ),
                    gap(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: netWorth),
                        const SizedBox(width: JSpace.gap),
                        Expanded(flex: 2, child: tagsCard),
                      ],
                    ),
                    gap(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: lists),
                        const SizedBox(width: JSpace.gap),
                        Expanded(child: big),
                      ],
                    ),
                  ],
                )
              : Column(
                  children: [
                    feed,
                    gap(),
                    breakdown,
                    gap(),
                    trend,
                    gap(),
                    scopeTrend,
                    gap(),
                    subs,
                    gap(),
                    netWorth,
                    gap(),
                    tagsCard,
                    gap(),
                    lists,
                    gap(),
                    big,
                  ],
                ),
        ),
      ],
    );
  }

  static double _monthlyEquivalent(RecurringRule r) => switch (r.frequency) {
    Frequency.weekly => r.amountCents * 52 / 12 / r.interval,
    Frequency.monthly => r.amountCents / r.interval,
    Frequency.yearly => r.amountCents / 12 / r.interval,
  };
}

class _MonthPicker extends ConsumerWidget {
  const _MonthPicker({required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final now = DateTime.now();
    final isCurrent = month.year == now.year && month.month == now.month;
    final n = ref.read(selectedMonthProvider.notifier);
    return Row(
      children: [
        JIconButton(
          icon: Icons.chevron_left_rounded,
          tooltip: 'Previous month',
          size: 38,
          onPressed: () => n.shift(-1),
        ),
        Expanded(
          child: Center(
            child: Text(Day.monthYear(month), style: JType.panelTitle.copyWith(color: c.ink)),
          ),
        ),
        JIconButton(
          icon: Icons.chevron_right_rounded,
          tooltip: 'Next month',
          size: 38,
          onPressed: isCurrent ? null : () => n.shift(1),
          color: isCurrent ? c.hairlineStrong : null,
        ),
      ],
    );
  }
}
