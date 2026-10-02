import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/activity/tx_row.dart';
import 'package:juno/features/home/home_screen.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/insights/charts.dart';
import 'package:juno/features/insights/health_card.dart';
import 'package:juno/features/insights/suggestions_card.dart';
import 'package:juno/features/smart/advisor.dart';

/// Insights' suggestions — unusual spending, likely subscriptions, budget
/// ideas — computed once per change in the data, not on every redraw, and
/// from the last six months (all they look at), not all history.
final insightIdeasProvider =
    Provider<
      ({List<SpendingAlert> alerts, List<SubscriptionSuggestion> subscriptions, List<BudgetSuggestion> budgets})
    >((
      ref,
    ) {
      final today = ref.watch(todayProvider);
      final lens = ref.watch(scopeFilterProvider);
      final history =
          ref
              .watch(
                txQueryProvider(
                  TxQuery(
                    from: Day.firstOfMonth(DateTime(today.year, today.month - 6)),
                    to: Day.of(today),
                    scope: lens,
                  ),
                ),
              )
              .value ??
          const <Transaction>[];
      final cats = ref.watch(categoryMapProvider);
      return (
        alerts: detectAnomalies(history: history, categoryNames: {for (final k in cats.values) k.id: k.name}),
        subscriptions: detectSubscriptions(history, ref.watch(recurringProvider).value ?? const <RecurringRule>[]),
        budgets: suggestBudgets(history: history, budgets: ref.watch(budgetsProvider).value ?? const []),
      );
    });

/// The net-worth line ending at [month], computed once per data change.
final netWorthProvider = Provider.family<List<(DateTime, int)>, DateTime>(
  (ref, month) => netWorthSeries(
    accounts: ref.watch(allAccountsProvider).value ?? const <Account>[],
    txs: ref.watch(allTxProvider).value ?? const <Transaction>[],
    perUsd: ref.watch(ratesProvider),
    last: month,
  ),
);

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
    final posting = ref.watch(postingRulesProvider);
    final lens = ref.watch(scopeFilterProvider);
    final accts = ref.watch(accountMapProvider);
    final rates = ref.watch(ratesProvider);
    final wide = MediaQuery.sizeOf(context).width >= JSize.wideBreakpoint;

    final s = PeriodSummary.of(txs);
    final firstEntry = ref.watch(firstEntryDayProvider).value;
    final current = DateTime(clock.now().year, clock.now().month);
    final pace = MonthPace(
      month: month,
      expense: s.expense,
      projection: month == current ? ref.watch(monthPlanProvider).forecastSpend : null,
    );
    // Mid-month, compare like with like: the first N days of this month
    // against the first N days of last month, not against all of it.
    final toDate = pace.isCurrent ? Day.of(DateTime(prev.year, prev.month, pace.daysElapsed)) : null;
    final ps = PeriodSummary.of(toDate == null ? prevTxs : prevTxs.where((t) => t.occurredOn.compareTo(toDate) <= 0));
    // A day or two of data makes every comparison shout; wait for a few.
    // Nor against a month you'd barely started logging in.
    final comparable = (!pace.isCurrent || pace.daysElapsed >= 3) && monthCovered(prev, firstEntry);
    final insights = compareInsights(
      current: s,
      previous: comparable ? ps : PeriodSummary.of(const []),
      names: {for (final k in cats.values) k.id: k.name},
      prevLabel: pace.isCurrent ? 'this point in ${Day.month(prev)}' : Day.month(prev),
      // Under a scope lens every entry is that scope; a share would be 100%.
      scopeShare: lens == null,
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

    final subsMonthly = posting
        .where((r) => r.type == TxType.expense && (lens == null || r.scope == lens))
        .fold<double>(
          0,
          (sum, r) =>
              sum +
              (Fx.tryToUsd(_monthlyEquivalent(r).round(), accts[r.accountId]?.currency ?? baseCurrency, rates) ?? 0),
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
            child: JMicroStat(value: pace.projected == null ? '—' : Money.whole(pace.projected!), label: 'Projected'),
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
                final list = RankedBars(
                  slices: slices,
                  onTap: (sl) {
                    if (sl.id != null) context.push('/insights/category/${sl.id}');
                  },
                );
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

    final ideas = ref.watch(insightIdeasProvider);
    final isCurrentMonth = pace.isCurrent;
    if (isCurrentMonth) {
      for (final a in ideas.alerts) {
        insights.insert(0, Insight(a.text, InsightTone.bad, categoryId: a.categoryId));
      }
    }
    final subsFound = isCurrentMonth ? ideas.subscriptions : const <SubscriptionSuggestion>[];
    final budgetIdeas = isCurrentMonth ? ideas.budgets : const <BudgetSuggestion>[];
    final suggestions = (subsFound.isEmpty && budgetIdeas.isEmpty)
        ? null
        : SuggestionsCard(subscriptions: subsFound.take(2).toList(), budgets: budgetIdeas.take(2).toList());

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

    final byDay = <String, int>{};
    for (final t in txs.where((t) => t.type == TxType.expense)) {
      byDay[t.occurredOn] = (byDay[t.occurredOn] ?? 0) + t.usd;
    }
    final calendar = JCard(
      title: 'Day by day',
      child: SpendCalendar(
        month: month,
        byDay: byDay,
        onDay: (day) => showDaySheet(context, day),
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
          : '${Money.whole(subsMonthly * 12)} a year across ${posting.where((r) => r.type == TxType.expense && (lens == null || r.scope == lens)).length} rules',
    );

    final worth = ref.watch(netWorthProvider(month));
    final worthNow = worth.isEmpty ? 0 : worth.last.$2;
    final worthDelta = worth.length < 2 ? 0 : worthNow - worth[worth.length - 2].$2;
    final netWorth = JCard(
      title: 'Net worth · 12 months',
      trailing: Text(
        worth.isEmpty
            ? '—'
            : '${Money.whole(worthNow)}  ${worthDelta >= 0 ? '+' : '\u2212'}${Money.whole(worthDelta.abs())} vs last month',
        style: JType.chipLabel.copyWith(color: worthDelta >= 0 ? c.income : c.expense),
      ),
      child: NetWorthLine(points: worth),
    );

    // An entry with two tags counts toward both, so tag totals can exceed
    // the month's spend.
    final byTag = <String, int>{};
    for (final t in txs.where((t) => t.type == TxType.expense)) {
      for (final tag in t.tagList.where((x) => !EntryTags.isPerson(x))) {
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

    final forWhom = spendByPerson(txs);
    final peopleCard = forWhom.people.isEmpty
        ? null
        : JCard(
            title: 'For whom',
            accent: JAccent.household,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RankedBars(
                  slices: [
                    for (final (tag, cents) in forWhom.people)
                      Slice(label: EntryTags.personName(tag), value: cents, color: c.household),
                    if (forWhom.unassigned > 0)
                      Slice(label: 'Whole household', value: forWhom.unassigned, color: c.inkFaint),
                  ],
                ),
                const SizedBox(height: JSpace.sm),
                Text(
                  'From entries marked “For” someone. An entry for two people is split between them.',
                  style: JType.body.copyWith(fontSize: 12, color: c.inkFaint),
                ),
              ],
            ),
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
          const SizedBox(height: JSpace.md),
          Align(
            alignment: Alignment.centerLeft,
            child: JButton(
              label: 'Month in review',
              icon: Icons.auto_stories_outlined,
              kind: JButtonKind.secondary,
              dense: true,
              onPressed: () => context.push('/insights/review'),
            ),
          ),
          const SizedBox(height: JSpace.lg),
          kpis,
        ],
      ),
      slivers: [
        SliverToBoxAdapter(
          child: wide
              // Two independent columns: each stacks its own cards, so a tall
              // card (Suggestions) never leaves a hole beside a short one.
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        children: [breakdown, gap(), calendar, gap(), trend, gap(), netWorth, gap(), lists],
                      ),
                    ),
                    const SizedBox(width: JSpace.gap),
                    Expanded(
                      flex: 2,
                      child: Column(
                        children: [
                          const MoneyHealthCard(),
                          gap(),
                          feed,
                          if (suggestions != null) ...[gap(), suggestions],
                          gap(),
                          subs,
                          gap(),
                          scopeTrend,
                          if (peopleCard != null) ...[gap(), peopleCard],
                          gap(),
                          tagsCard,
                          gap(),
                          big,
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    feed,
                    if (suggestions != null) ...[gap(), suggestions],
                    gap(),
                    const MoneyHealthCard(),
                    gap(),
                    calendar,
                    gap(),
                    breakdown,
                    gap(),
                    trend,
                    gap(),
                    scopeTrend,
                    if (peopleCard != null) ...[gap(), peopleCard],
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
    ref.watch(todayProvider); // redraw when the day changes
    final now = clock.now();
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

/// A day's entries in a sheet (from the calendar).
Future<void> showDaySheet(BuildContext context, String day) => showJSheet<void>(
  context,
  title: '*${Day.relative(day)}*',
  child: Consumer(
    builder: (context, ref, _) {
      final txs = ref.watch(txQueryProvider(TxQuery(from: day, to: day, scope: ref.watch(scopeFilterProvider)))).value;
      if (txs == null) return const SizedBox(height: 80);
      if (txs.isEmpty) {
        return Text('Nothing logged.', style: JType.body.copyWith(color: context.jc.inkMuted));
      }
      return SlidableAutoCloseBehavior(
        child: Column(children: [for (final t in txs) TxRow(tx: t)]),
      );
    },
  ),
);
