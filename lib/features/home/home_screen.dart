import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/activity/tx_row.dart';
import 'package:juno/features/add/entry_sheet.dart';
import 'package:juno/features/home/weekly_read.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/plan/budget_widgets.dart';
import 'package:juno/features/plan/recurrence.dart';
import 'package:juno/features/smart/advisor.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(todayProvider); // redraw when the day changes
    final now = clock.now();
    final month = DateTime(now.year, now.month);
    final wide = MediaQuery.sizeOf(context).width >= JSize.wideBreakpoint;

    final main = [
      const JReveal(child: _HeroTile()),
      const SizedBox(height: JSpace.gap),
      const JReveal(index: 1, child: _SafeToSpendTile()),
      JReveal(index: 1, child: _ScopeSplitTile(month: month)),
    ];
    final side = [
      const JReveal(index: 2, child: WeeklyCard()),
      const SizedBox(height: JSpace.gap),
      JReveal(index: 2, child: _BudgetsCard(month: month)),
      const SizedBox(height: JSpace.gap),
      const JReveal(index: 3, child: _UpcomingCard()),
    ];

    return JScreen(
      eyebrow: '01 — Overview · ${Day.monthYear(month)}',
      title: _greeting(now),
      actions: [
        JIconButton(
          icon: Icons.auto_awesome_outlined,
          tooltip: 'Ask Juno',
          onPressed: () => context.push('/assistant'),
        ),
      ],
      header: const ScopeLens(),
      slivers: [
        if (wide)
          SliverToBoxAdapter(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      ...main,
                      const SizedBox(height: JSpace.gap),
                      const _RecentCard(),
                    ],
                  ),
                ),
                const SizedBox(width: JSpace.gap),
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      ...side,
                      const SizedBox(height: JSpace.gap),
                      const _AccountsCard(),
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          SliverList.list(
            children: [
              ...main,
              const SizedBox(height: JSpace.gap),
              ...side,
              const SizedBox(height: JSpace.gap),
              const JReveal(index: 4, child: _RecentCard()),
              const SizedBox(height: JSpace.gap),
              const _AccountsCard(),
            ],
          ),
      ],
    );
  }

  static String _greeting(DateTime now) {
    final h = now.hour;
    final part = h < 5
        ? 'Late night'
        : h < 12
        ? 'Good morning'
        : h < 18
        ? 'Good afternoon'
        : 'Good evening';
    return '$part, *here’s* the month';
  }
}

/// All / Personal / Household — the lens every screen reads.
class ScopeLens extends ConsumerWidget {
  const ScopeLens({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(scopeFilterProvider);
    final options = <Scope?>[null, Scope.personal, Scope.household];
    return JChipBar(
      labels: const ['All', 'Personal', 'Household'],
      accents: const [JAccent.brand, JAccent.brand, JAccent.household],
      selectedIndex: options.indexOf(scope),
      onSelected: (i) => ref.read(scopeFilterProvider.notifier).set(options[i]),
    );
  }
}

class _HeroTile extends ConsumerWidget {
  const _HeroTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    ref.watch(todayProvider); // redraw when the day changes
    final now = clock.now();
    final month = DateTime(now.year, now.month);
    final txs = ref.watch(monthTxProvider(month)).value ?? const <Transaction>[];
    final s = PeriodSummary.of(txs);
    final pace = MonthPace(month: month, expense: s.expense, projection: ref.watch(monthPlanProvider).forecastSpend);
    final scope = ref.watch(scopeFilterProvider);
    final rate = s.savingsRate;

    return JCard(
      accent: scope == Scope.household ? JAccent.household : JAccent.brand,
      padding: const EdgeInsets.all(JSpace.tile),
      title: scope == null ? 'Spent this month' : 'Spent this month · ${scope.label}',
      trailing: JPill('Day ${pace.daysElapsed}/${pace.daysInMonth}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: CountUpMoney(
              s.expense,
              style: JType.heroMetric.copyWith(fontSize: 52, color: c.ink),
            ),
          ),
          const SizedBox(height: JSpace.sm),
          Text(
            s.expense == 0
                ? 'Nothing logged yet this month.'
                : [
                    '${Money.format(pace.avgDaily)} a day',
                    if (pace.projected case final p?) 'on pace for ${Money.whole(p)}',
                  ].join(' · '),
            style: JType.body.copyWith(color: c.inkMuted),
          ),
          const SizedBox(height: JSpace.xl),
          Divider(color: c.hairline),
          const SizedBox(height: JSpace.lg),
          Row(
            children: [
              Expanded(
                child: JMicroStat(value: Money.whole(s.income), label: 'Income', valueColor: c.income),
              ),
              Expanded(
                child: JMicroStat(
                  value: s.net < 0 ? '−${Money.whole(-s.net)}' : Money.whole(s.net),
                  label: 'Net',
                  valueColor: s.net < 0 ? c.expense : c.ink,
                ),
              ),
              Expanded(
                child: JMicroStat(
                  value: rate == null ? '—' : '${(rate * 100).round()}%',
                  label: 'Kept',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Personal vs household this month — always across both scopes, since the
/// comparison is the point. Tapping a side focuses the app on that scope.
/// Safe to spend today: income still to come minus bills still due, spread
/// over the days left. Hidden until there's an income to plan against.
class _SafeToSpendTile extends ConsumerWidget {
  const _SafeToSpendTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final plan = ref.watch(monthPlanProvider);
    if (!plan.meaningful) return const SizedBox.shrink();
    final over = plan.leftToSpend < 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: JSpace.gap),
      child: JCard(
        accent: over ? JAccent.expense : JAccent.income,
        alert: over,
        title: 'Safe to spend today',
        trailing: JPill(plan.daysLeft == 1 ? 'Last day' : '${plan.daysLeft} days left'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              over ? Money.whole(0) : Money.whole(plan.perDay),
              style: JType.panelMetric.copyWith(color: over ? c.expense : c.ink),
            ),
            const SizedBox(height: 6),
            Text(
              over
                  ? '${Money.whole(-plan.leftToSpend)} over this month once ${Money.whole(plan.committed)} of bills are paid.'
                  : [
                      '${Money.whole(plan.leftToSpend)} left after ${Money.whole(plan.committed)} of bills still due',
                      if (plan.forecastSpend case final f?) 'on pace to spend ${Money.whole(f)} by month end',
                    ].join(' · '),
              style: JType.body.copyWith(color: over ? c.ink : c.inkMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScopeSplitTile extends ConsumerWidget {
  const _ScopeSplitTile({required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final txs = ref.watch(monthTxAllScopesProvider(month)).value ?? const <Transaction>[];
    final s = PeriodSummary.of(txs);
    final p = s.byScope[Scope.personal]!;
    final h = s.byScope[Scope.household]!;
    final total = p + h;
    final lens = ref.watch(scopeFilterProvider);

    Widget side(Scope scope, int cents, Color color, CrossAxisAlignment align) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => ref.read(scopeFilterProvider.notifier).set(lens == scope ? null : scope),
        child: Column(
          crossAxisAlignment: align,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                JDot(color),
                const SizedBox(width: 6),
                Text(scope.label.toUpperCase(), style: JType.microLabel.copyWith(color: c.inkMuted)),
              ],
            ),
            const SizedBox(height: JSpace.sm),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(Money.whole(cents), style: JType.panelMetric.copyWith(color: c.ink)),
            ),
            const SizedBox(height: 2),
            Text(
              total == 0 ? '—' : '${(cents / total * 100).round()}% of spend',
              style: JType.body.copyWith(fontSize: 12, color: c.inkFaint),
            ),
          ],
        ),
      ),
    );

    return JCard(
      title: 'Personal vs household',
      child: Column(
        children: [
          Row(
            children: [
              side(Scope.personal, p, c.brand, CrossAxisAlignment.start),
              side(Scope.household, h, c.household, CrossAxisAlignment.end),
            ],
          ),
          const SizedBox(height: JSpace.lg),
          _SplitBar(a: p, b: h, aColor: c.brand, bColor: c.household),
        ],
      ),
    );
  }
}

class _SplitBar extends StatelessWidget {
  const _SplitBar({required this.a, required this.b, required this.aColor, required this.bColor});

  final int a;
  final int b;
  final Color aColor;
  final Color bColor;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final total = a + b;
    return SizedBox(
      height: 8,
      child: total == 0
          ? Container(
              decoration: BoxDecoration(color: c.hairline, borderRadius: BorderRadius.circular(4)),
            )
          : TweenAnimationBuilder<double>(
              tween: Tween(end: a / total),
              duration: JMotion.reduced(context) ? Duration.zero : JMotion.reveal,
              curve: JMotion.ease,
              builder: (_, t, _) => Row(
                children: [
                  if (t > 0)
                    Expanded(
                      flex: (t * 1000).round().clamp(1, 1000),
                      child: Container(
                        decoration: BoxDecoration(color: aColor, borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  // 2px surface gap between fills (dataviz spacer rule).
                  if (t > 0 && t < 1) const SizedBox(width: 2),
                  if (t < 1)
                    Expanded(
                      flex: ((1 - t) * 1000).round().clamp(1, 1000),
                      child: Container(
                        decoration: BoxDecoration(color: bColor, borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _BudgetsCard extends ConsumerWidget {
  const _BudgetsCard({required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budgets = ref.watch(budgetsProvider).value ?? const <Budget>[];
    final txs = ref.watch(monthTxAllScopesProvider(month)).value ?? const <Transaction>[];
    final statuses = budgetStatuses(budgets, txs);
    return JCard(
      title: 'Budgets',
      onTap: () => context.go('/plan'),
      child: statuses.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: JSpace.sm),
              child: Text(
                'Set a monthly limit for a category or scope to see how close you are.',
                style: JType.body.copyWith(color: context.jc.inkMuted),
              ),
            )
          : Column(
              children: [
                for (final s in statuses.take(3)) ...[
                  BudgetLine(status: s),
                  if (s != statuses.take(3).last) const SizedBox(height: JSpace.lg),
                ],
              ],
            ),
    );
  }
}

class _UpcomingCard extends ConsumerWidget {
  const _UpcomingCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final rules = ref.watch(postingRulesProvider);
    final cats = ref.watch(categoryMapProvider);
    final horizon = Day.of(Day.shift(ref.watch(todayProvider), 7));
    final lens = ref.watch(scopeFilterProvider);
    final soon = rules
        .where((r) => r.isLive && (lens == null || r.scope == lens) && r.nextDue.compareTo(horizon) <= 0)
        .toList();

    return JCard(
      title: 'Next 7 days',
      onTap: () => context.go('/plan'),
      child: soon.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: JSpace.sm),
              child: Text('No recurring entries due.', style: JType.body.copyWith(color: c.inkMuted)),
            )
          : Column(
              children: [
                for (final r in soon.take(4))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 64,
                          child: Text(
                            Day.short(r.nextDue).toUpperCase(),
                            style: JType.microLabel.copyWith(color: c.inkFaint),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            r.note.isNotEmpty ? r.note : cats[r.categoryId]?.name ?? 'Recurring',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: JType.bodyStrong.copyWith(color: c.ink),
                          ),
                        ),
                        Text(
                          '${r.type == TxType.income ? '+' : '−'}${Fx.format(r.amountCents, ref.watch(accountMapProvider)[r.accountId]?.currency ?? baseCurrency)}',
                          style: JType.rowMetric.copyWith(
                            fontSize: 13,
                            color: r.type == TxType.income ? c.income : c.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _RecentCard extends ConsumerWidget {
  const _RecentCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(scopeFilterProvider);
    final txs = ref.watch(txQueryProvider(TxQuery(scope: scope, limit: 8))).value;
    return JCard(
      title: 'Recent',
      onTap: () => context.go('/activity'),
      padding: const EdgeInsets.fromLTRB(JSpace.card, JSpace.card, JSpace.card, JSpace.sm),
      child: txs == null
          ? const SizedBox(height: 80)
          : txs.isEmpty
          ? Padding(
              padding: const EdgeInsets.only(bottom: JSpace.sm),
              child: JEmpty(
                icon: Icons.receipt_long_outlined,
                title: 'No entries yet',
                message: 'Log your first expense — it takes three taps.',
                action: JButton(
                  label: 'New entry',
                  icon: Icons.add_rounded,
                  dense: true,
                  onPressed: () => showEntrySheet(context),
                ),
              ),
            )
          : SlidableAutoCloseBehavior(
              child: Column(children: [for (final t in txs) TxRow(tx: t, showDate: true)]),
            ),
    );
  }
}

class _AccountsCard extends ConsumerWidget {
  const _AccountsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final balances = ref.watch(balancesProvider).value ?? const <String, int>{};
    final rates = ref.watch(ratesProvider);
    // Net worth counts archived accounts too — money doesn't stop existing
    // when an account is hidden — matching the Insights net-worth chart.
    final everyAccount = ref.watch(allAccountsProvider).value ?? accounts;
    final parts = [
      for (final a in everyAccount) Fx.tryToUsd(balances[a.id] ?? a.openingBalanceCents, a.currency, rates),
    ];
    // Unknown until every account's rate is loaded: never a wrong total.
    final total = parts.contains(null) ? null : parts.fold<int>(0, (s, v) => s + v!);
    // The rows add up to the total: an archived account still holding money
    // is listed (marked) rather than hidden inside net worth.
    final shown = [
      for (final a in everyAccount)
        if (!a.archived || (balances[a.id] ?? a.openingBalanceCents) != 0) a,
    ];
    return JCard(
      title: 'Accounts',
      onTap: () => context.go('/settings/accounts'),
      child: Column(
        children: [
          for (final a in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      a.archived ? '${a.name} (archived)' : a.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: JType.bodyStrong.copyWith(color: a.archived ? c.inkMuted : c.ink, fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: JSpace.sm),
                  // LBP balances run to 13+ characters: shrink, never push
                  // the name off the row.
                  Flexible(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          Fx.format(balances[a.id] ?? a.openingBalanceCents, a.currency),
                          style: JType.rowMetric.copyWith(
                            color: (balances[a.id] ?? 0) < 0 ? c.expense : c.inkMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: JSpace.sm),
          Divider(color: c.hairline),
          const SizedBox(height: JSpace.sm),
          Row(
            children: [
              Expanded(
                child: Text('NET WORTH', style: JType.microLabel.copyWith(color: c.inkFaint)),
              ),
              Text(total == null ? '—' : Money.format(total), style: JType.cardMetric.copyWith(color: c.ink)),
            ],
          ),
        ],
      ),
    );
  }
}
