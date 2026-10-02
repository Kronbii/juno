import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/plan/budget_widgets.dart';
import 'package:juno/features/plan/cash_flow_tab.dart';
import 'package:juno/features/plan/editors.dart';
import 'package:juno/features/plan/goal_pace.dart';
import 'package:juno/features/plan/recurrence.dart';

enum PlanTab { budgets, goals, recurring, cashFlow }

class PlanScreen extends ConsumerStatefulWidget {
  const PlanScreen({super.key});

  @override
  ConsumerState<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends ConsumerState<PlanScreen> {
  PlanTab _tab = PlanTab.budgets;

  @override
  Widget build(BuildContext context) {
    final (label, onAdd) = switch (_tab) {
      PlanTab.budgets => ('New budget', () => editBudget(context)),
      PlanTab.goals => ('New goal', () => editGoal(context)),
      PlanTab.recurring || PlanTab.cashFlow => ('New recurring', () => editRecurring(context)),
    };
    return JScreen(
      eyebrow: '04 — Plan',
      title: 'Spend on *purpose*',
      actions: [JIconButton(icon: Icons.add_rounded, tooltip: label, onPressed: onAdd)],
      header: JSegmentBar<PlanTab>(
        segments: const {
          PlanTab.budgets: 'Budgets',
          PlanTab.goals: 'Goals',
          PlanTab.recurring: 'Recurring',
          PlanTab.cashFlow: 'Cash flow',
        },
        selected: _tab,
        accentOf: (t) => switch (t) {
          PlanTab.budgets => JAccent.warn,
          PlanTab.goals => JAccent.income,
          PlanTab.recurring => JAccent.household,
          PlanTab.cashFlow => JAccent.brand,
        },
        onChanged: (t) => setState(() => _tab = t),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: AnimatedSwitcher(
            duration: JMotion.reduced(context) ? Duration.zero : JMotion.medium,
            switchInCurve: JMotion.ease,
            child: KeyedSubtree(
              key: ValueKey(_tab),
              child: switch (_tab) {
                PlanTab.budgets => const _BudgetsTab(),
                PlanTab.goals => const _GoalsTab(),
                PlanTab.recurring => const _RecurringTab(),
                PlanTab.cashFlow => const CashFlowTab(),
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _BudgetsTab extends ConsumerWidget {
  const _BudgetsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    ref.watch(todayProvider); // redraw when the day changes
    final now = clock.now();
    final month = DateTime(now.year, now.month);
    final budgets = ref.watch(budgetsProvider).value ?? const <Budget>[];
    final txs = ref.watch(monthTxAllScopesProvider(month)).value ?? const <Transaction>[];
    final statuses = budgetStatuses(budgets, txs);
    final pace = MonthPace(month: month, expense: 0);

    if (statuses.isEmpty) {
      return JEmpty(
        icon: Icons.donut_large_outlined,
        title: 'No budgets yet',
        message: 'Cap a category (Dining), a scope (Household), or everything. Juno warns at 80%.',
        action: JButton(
          label: 'New budget',
          icon: Icons.add_rounded,
          dense: true,
          onPressed: () => editBudget(context),
        ),
      );
    }

    final over = statuses.where((s) => s.over).length;
    final near = statuses.where((s) => s.near).length;
    // Budgets overlap (a category inside "all spending"), so the headline
    // counts budgets by state rather than adding their limits.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: JMicroStat(value: '${statuses.length}', label: 'Budgets'),
            ),
            Expanded(
              child: JMicroStat(value: '$over', label: 'Over', valueColor: over > 0 ? c.expense : null),
            ),
            Expanded(
              // Today counts, as on Home's safe-to-spend card (0 on the last
              // day read as if the month were already over).
              child: JMicroStat(value: '${pace.daysInMonth - now.day + 1}', label: 'Days left'),
            ),
            Expanded(
              child: JMicroStat(value: '$near', label: 'Close', valueColor: near > 0 ? c.warn : null),
            ),
          ],
        ),
        const SizedBox(height: JSpace.xl),
        JCard(
          title: Day.monthYear(month),
          child: Column(
            children: [
              for (final s in statuses) ...[
                BudgetLine(
                  status: s,
                  onTap: () => editBudget(context, budget: s.budget),
                ),
                if (s != statuses.last) ...[
                  const SizedBox(height: JSpace.md),
                  Divider(color: c.hairline),
                  const SizedBox(height: JSpace.md),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _GoalsTab extends ConsumerWidget {
  const _GoalsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(goalsProvider).value ?? const <Goal>[];
    final saved = ref.watch(goalSavedProvider).value ?? const <String, int>{};
    if (goals.isEmpty) {
      return JEmpty(
        icon: Icons.flag_outlined,
        title: 'Nothing to save for yet',
        message: 'An emergency fund, a trip, a new laptop — give it a number and a date.',
        action: JButton(label: 'New goal', icon: Icons.add_rounded, dense: true, onPressed: () => editGoal(context)),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth > 900
            ? 3
            : box.maxWidth > 560
            ? 2
            : 1;
        final w = (box.maxWidth - (cols - 1) * JSpace.gap) / cols;
        return Wrap(
          spacing: JSpace.gap,
          runSpacing: JSpace.gap,
          children: [
            for (final g in goals)
              SizedBox(
                width: w,
                child: GoalCard(goal: g, saved: saved[g.id] ?? 0),
              ),
          ],
        );
      },
    );
  }
}

class GoalCard extends ConsumerWidget {
  const GoalCard({required this.goal, required this.saved, super.key});

  final Goal goal;
  final int saved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final color = seriesColor(c, goal.colorIndex);
    final ratio = goal.targetCents == 0 ? 0.0 : saved / goal.targetCents;
    return JCard(
      onTap: () => context.push('/plan/goal/${goal.id}'),
      child: Row(
        children: [
          GoalRing(ratio: ratio, color: color),
          const SizedBox(width: JSpace.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  goal.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: JType.rowTitle.copyWith(color: c.ink),
                ),
                const SizedBox(height: 4),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: Money.whole(saved),
                        style: JType.rowMetric.copyWith(color: c.ink),
                      ),
                      TextSpan(
                        text: ' of ${Money.whole(goal.targetCents)}',
                        style: JType.rowMetric.copyWith(color: c.inkFaint),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                GoalPaceLine(goal: goal, saved: saved),
              ],
            ),
          ),
          JIconButton(
            icon: Icons.add_rounded,
            tooltip: 'Add money',
            size: 38,
            onPressed: () => contribute(context, ref, goal),
          ),
        ],
      ),
    );
  }
}

/// A thin progress ring with the percentage in mono.
/// "On track · $200/mo, there by March 2027" — or behind, with what's
/// needed. Status is in the words; the colour only repeats it.
class GoalPaceLine extends ConsumerWidget {
  const GoalPaceLine({required this.goal, required this.saved, super.key});

  final Goal goal;
  final int saved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final pace = goalPace(
      goal: goal,
      saved: saved,
      contributions: ref.watch(goalContributionsProvider(goal.id)).value ?? const [],
    );
    return Text(
      pace.line,
      style: JType.body.copyWith(
        fontSize: 12,
        color: switch (pace.status) {
          GoalStatus.reached || GoalStatus.onTrack => c.income,
          GoalStatus.behind => c.warn,
          GoalStatus.noPace => c.inkFaint,
        },
      ),
    );
  }
}

class GoalRing extends StatelessWidget {
  const GoalRing({required this.ratio, required this.color, this.size = 56, super.key});

  final double ratio;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return SizedBox.square(
      dimension: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: ratio.clamp(0, 1)),
        duration: JMotion.reduced(context) ? Duration.zero : JMotion.reveal,
        curve: JMotion.ease,
        builder: (_, t, _) => Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: t,
                strokeWidth: 3,
                strokeCap: StrokeCap.round,
                color: color,
                backgroundColor: c.hairline,
              ),
            ),
            Text(
              '${(ratio * 100).clamp(0, 999).round()}%',
              style: JType.chipLabel.copyWith(fontSize: 11, color: c.ink),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecurringTab extends ConsumerWidget {
  const _RecurringTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final rules = ref.watch(recurringProvider).value ?? const <RecurringRule>[];
    final cats = ref.watch(categoryMapProvider);
    final accounts = ref.watch(accountMapProvider);
    if (rules.isEmpty) {
      return JEmpty(
        icon: Icons.autorenew_rounded,
        title: 'No recurring entries',
        message: 'Rent, salary, subscriptions — set them once and Juno logs them on the day.',
        action: JButton(
          label: 'New recurring',
          icon: Icons.add_rounded,
          dense: true,
          onPressed: () => editRecurring(context),
        ),
      );
    }
    String every(RecurringRule r) {
      final unit = switch (r.frequency) {
        Frequency.weekly => 'week',
        Frequency.monthly => 'month',
        Frequency.yearly => 'year',
      };
      return r.interval == 1 ? 'Every $unit' : 'Every ${r.interval} ${unit}s';
    }

    return JGroup(
      children: [
        for (final r in rules)
          InkWell(
            onTap: () => editRecurring(context, rule: r),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: JSpace.card, vertical: 14),
              child: JFigureRow(
                leading: [
                  Icon(
                    categoryIcon(cats[r.categoryId]?.icon ?? 'repeat'),
                    size: 19,
                    color: r.active ? c.inkMuted : c.inkFaint,
                  ),
                  const SizedBox(width: 14),
                ],
                main: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.note.isNotEmpty ? r.note : cats[r.categoryId]?.name ?? 'Recurring',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: JType.rowTitle.copyWith(color: r.active ? c.ink : c.inkFaint),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        JDot(r.scope == Scope.household ? c.household : c.brand, size: 6),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            !r.active
                                ? 'Paused'
                                : accounts[r.accountId]?.archived ?? false
                                ? 'Paused · account archived'
                                : r.isLive
                                ? '${every(r)} · next ${Day.relative(r.nextDue)}'
                                : 'Ended ${Day.short(r.endDate!)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: JType.body.copyWith(fontSize: 12, color: c.inkFaint),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                figure: Text(
                  '${r.type == TxType.income ? '+' : '−'}${Fx.format(r.amountCents, accounts[r.accountId]?.currency ?? baseCurrency)}',
                  style: JType.rowMetric.copyWith(color: r.type == TxType.income ? c.income : c.ink),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
