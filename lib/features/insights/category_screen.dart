import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/activity/tx_row.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/plan/budget_widgets.dart';
import 'package:juno/features/plan/editors.dart';

/// One category, end to end: this month vs usual, six-month trend, its
/// budget, where the money goes, and every entry.
class CategoryScreen extends ConsumerWidget {
  const CategoryScreen({required this.categoryId, super.key});

  final String categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final cat = ref.watch(categoryMapProvider)[categoryId];
    final month = ref.watch(selectedMonthProvider);
    final lens = ref.watch(scopeFilterProvider);
    final history =
        ref
            .watch(
              txQueryProvider(
                TxQuery(
                  categoryIds: {categoryId},
                  scope: lens,
                  from: Day.firstOfMonth(DateTime(month.year, month.month - 11)),
                  to: Day.lastOfMonth(month),
                ),
              ),
            )
            .value ??
        const <Transaction>[];
    if (cat == null) {
      return JScreen(
        title: 'Category',
        actions: [
          JIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
        slivers: const [],
      );
    }
    final color = seriesColor(c, cat.colorIndex);
    final series = monthlySeries(history, month, 6);
    final thisMonth = history.where((t) => t.occurredOn.startsWith(Day.firstOfMonth(month).substring(0, 7))).toList();
    final spent = PeriodSummary.of(thisMonth).expense;
    final prior = series.take(5).map((p) => p.expense).where((v) => v > 0).toList();
    final usual = prior.isEmpty ? 0 : (prior.reduce((a, b) => a + b) / prior.length).round();
    final count = thisMonth.where((t) => t.type == TxType.expense).length;
    final budgets = (ref.watch(budgetsProvider).value ?? const <Budget>[])
        .where((b) => b.categoryId == categoryId)
        .toList();
    final statuses = budgetStatuses(budgets, ref.watch(monthTxAllScopesProvider(month)).value ?? const []);
    final places = topMerchants(thisMonth);

    final usualText = usual == 0
        ? 'No earlier months to compare yet.'
        : spent > usual
        ? '${Money.whole(spent - usual)} more than your usual ${Money.whole(usual)}'
        : '${Money.whole(usual - spent)} under your usual ${Money.whole(usual)}';

    return JScreen(
      eyebrow: 'Category · ${Day.monthYear(month)}',
      title: '*${cat.name}*',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              JCard(
                padding: const EdgeInsets.all(JSpace.tile),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: c.tint(color),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: color.withValues(alpha: 0.35)),
                      ),
                      child: Icon(categoryIcon(cat.icon), color: color),
                    ),
                    const SizedBox(width: JSpace.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FittedBox(
                            child: Text(Money.format(spent), style: JType.panelMetric.copyWith(color: c.ink)),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$count entr${count == 1 ? 'y' : 'ies'} · $usualText',
                            style: JType.body.copyWith(
                              color: usual > 0 && spent > usual * 1.2 ? c.expense : c.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: JSpace.gap),
              JCard(
                title: 'Six months',
                child: _SingleSeriesBars(points: series, color: color),
              ),
              const SizedBox(height: JSpace.gap),
              JCard(
                title: 'Budget',
                trailing: statuses.isEmpty
                    ? JButton(
                        label: 'Set one',
                        kind: JButtonKind.ghost,
                        dense: true,
                        onPressed: () => editBudget(context),
                      )
                    : null,
                child: statuses.isEmpty
                    ? Text(
                        usual > 0
                            ? 'No budget yet. Your usual is ${Money.whole(usual)} a month.'
                            : 'No budget for ${cat.name} yet.',
                        style: JType.body.copyWith(color: c.inkMuted),
                      )
                    : Column(
                        children: [
                          for (final s in statuses)
                            BudgetLine(
                              status: s,
                              onTap: () => editBudget(context, budget: s.budget),
                            ),
                        ],
                      ),
              ),
              if (places.isNotEmpty) ...[
                const SizedBox(height: JSpace.gap),
                JCard(
                  title: 'Where',
                  child: Column(
                    children: [
                      for (final m in places)
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
                ),
              ],
              JSectionLabel('Entries in ${Day.month(month)}'),
              if (thisMonth.isEmpty)
                Text('None this month.', style: JType.body.copyWith(color: c.inkMuted))
              else
                SlidableAutoCloseBehavior(
                  child: Column(children: [for (final t in thisMonth) TxRow(tx: t, showDate: true)]),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One category's monthly spend: a single series, so no legend.
class _SingleSeriesBars extends StatelessWidget {
  const _SingleSeriesBars({required this.points, required this.color});

  final List<MonthPoint> points;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final max = points.fold(0, (m, p) => p.expense > m ? p.expense : m);
    return SizedBox(
      height: 120,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final p in points)
            Expanded(
              child: Tooltip(
                message: '${Day.monthShort(p.month)} · ${Money.format(p.expense)}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      p.expense == 0 ? '' : Money.compact(p.expense),
                      style: JType.microLabel.copyWith(color: c.inkFaint, letterSpacing: 0.2),
                    ),
                    const SizedBox(height: 4),
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: max == 0 ? 0 : p.expense / max),
                      duration: JMotion.reduced(context) ? Duration.zero : JMotion.reveal,
                      curve: JMotion.ease,
                      builder: (_, t, _) => Container(
                        width: 18,
                        height: 2 + 70 * t,
                        decoration: BoxDecoration(
                          color: p.expense == 0 ? c.hairline : color,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(Day.monthShort(p.month).toUpperCase(), style: JType.microLabel.copyWith(color: c.inkFaint)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
