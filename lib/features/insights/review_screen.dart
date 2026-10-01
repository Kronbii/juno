import 'package:drift/drift.dart' show BooleanExpressionOperators, ComparableExpr;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/insights/review.dart';

final _contribProvider = StreamProvider.family<List<GoalContribution>, (String, String)>((ref, range) {
  final db = ref.watch(databaseProvider);
  return (db.select(
    db.goalContributions,
  )..where((c) => c.deletedAt.isNull() & c.occurredOn.isBetweenValues(range.$1, range.$2))).watch();
});

enum _Span { month, year }

class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  _Span _span = _Span.month;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final m = ref.watch(selectedMonthProvider);
    final lens = ref.watch(scopeFilterProvider);
    final yearly = _span == _Span.year;
    final from = yearly ? '${m.year}-01-01' : Day.firstOfMonth(m);
    final to = yearly ? '${m.year}-12-31' : Day.lastOfMonth(m);
    final prevFrom = yearly ? '${m.year - 1}-01-01' : Day.firstOfMonth(DateTime(m.year, m.month - 1));
    // A period still running is compared with the same point of the one
    // before ("this point in September"), never with all of it.
    final today = DateTime.now();
    final ongoing = Day.today().compareTo(from) >= 0 && Day.today().compareTo(to) <= 0;
    final String prevTo;
    if (!ongoing) {
      prevTo = yearly ? '${m.year - 1}-12-31' : Day.lastOfMonth(DateTime(m.year, m.month - 1));
    } else if (yearly) {
      prevTo = Day.of(DateTime(today.year - 1, today.month, today.day));
    } else {
      final pm = DateTime(m.year, m.month - 1);
      prevTo = Day.of(DateTime(pm.year, pm.month, today.day.clamp(1, Day.daysInMonth(pm))));
    }
    final current = ref.watch(txQueryProvider(TxQuery(from: from, to: to, scope: lens))).value;
    final previous = ref.watch(txQueryProvider(TxQuery(from: prevFrom, to: prevTo, scope: lens))).value;
    final budgets = ref.watch(budgetsProvider).value ?? const <Budget>[];
    final contribs = ref.watch(_contribProvider((from, to))).value ?? const <GoalContribution>[];
    final names = {for (final k in ref.watch(categoryMapProvider).values) k.id: k.name};

    final label = yearly ? '${m.year}' : Day.monthYear(m);
    final prevName = yearly ? '${m.year - 1}' : Day.month(DateTime(m.year, m.month - 1));
    final prevLabel = ongoing ? 'this point in $prevName' : prevName;
    final review = current == null || previous == null
        ? null
        : buildReview(
            label: label,
            previousLabel: prevLabel,
            current: current,
            previous: previous,
            budgets: budgets,
            contributions: contribs,
            months: yearly ? [for (var i = 1; i <= (ongoing ? today.month : 12); i++) DateTime(m.year, i)] : [m],
          );

    Widget stat(String l, String v, {Color? color}) => Expanded(
      child: JMicroStat(value: v, label: l, valueColor: color),
    );

    return JScreen(
      eyebrow: 'Review',
      title: yearly ? 'Your *year*' : 'Your *month*',
      subtitle: label,
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
        if (review != null)
          JIconButton(
            icon: Icons.copy_rounded,
            tooltip: 'Copy summary',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: review.toText(names)));
              showToast('Summary copied');
            },
          ),
      ],
      header: JSegmentBar<_Span>(
        segments: const {_Span.month: 'Month', _Span.year: 'Year'},
        selected: _span,
        onChanged: (s) => setState(() => _span = s),
      ),
      slivers: [
        if (review == null)
          const SliverToBoxAdapter(child: SizedBox(height: 120))
        else
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                JCard(
                  accent: review.spentDelta > 0 ? JAccent.expense : JAccent.income,
                  padding: const EdgeInsets.all(JSpace.tile),
                  title: 'Spent',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(Money.whole(review.now.expense), style: JType.heroMetric.copyWith(color: c.ink)),
                      const SizedBox(height: 6),
                      Text(
                        review.before.expense == 0
                            ? 'Nothing to compare with $prevLabel.'
                            : '${review.spentDelta >= 0 ? '${Money.whole(review.spentDelta)} more' : '${Money.whole(-review.spentDelta)} less'} than $prevLabel',
                        style: JType.body.copyWith(color: review.spentDelta > 0 ? c.expense : c.income),
                      ),
                      const SizedBox(height: JSpace.lg),
                      Row(
                        children: [
                          stat('Income', Money.whole(review.now.income), color: c.income),
                          stat(
                            'Kept',
                            review.now.savingsRate == null ? '—' : '${(review.now.savingsRate! * 100).round()}%',
                          ),
                          stat('Personal', Money.whole(review.now.byScope[Scope.personal]!)),
                          stat('Household', Money.whole(review.now.byScope[Scope.household]!)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: JSpace.gap),
                JCard(
                  title: 'Biggest moves vs $prevLabel',
                  child: review.categoryMoves.isEmpty
                      ? Text('No changes worth noting.', style: JType.body.copyWith(color: c.inkMuted))
                      : Column(
                          children: [
                            for (final (id, a, p) in review.categoryMoves.take(5))
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Row(
                                  children: [
                                    Icon(
                                      a >= p ? Icons.north_east_rounded : Icons.south_east_rounded,
                                      size: 15,
                                      color: a >= p ? c.expense : c.income,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        names[id] ?? 'Uncategorised',
                                        style: JType.bodyStrong.copyWith(color: c.ink, fontSize: 14),
                                      ),
                                    ),
                                    Text(Money.whole(a), style: JType.rowMetric.copyWith(color: c.ink)),
                                    SizedBox(
                                      width: 92,
                                      child: Text(
                                        '${a >= p ? '+' : '−'}${Money.whole((a - p).abs())}',
                                        textAlign: TextAlign.right,
                                        style: JType.chipLabel.copyWith(color: c.inkFaint),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: JSpace.gap),
                Row(
                  children: [
                    Expanded(
                      child: JMetricTile(
                        accent: review.budgetsMissed > 0 ? JAccent.warn : JAccent.income,
                        label: ongoing ? 'Budgets on track' : 'Budgets kept',
                        value: '${review.budgetsMet}/${review.budgetsMet + review.budgetsMissed}',
                        compact: true,
                      ),
                    ),
                    const SizedBox(width: JSpace.gap),
                    Expanded(
                      child: JMetricTile(
                        accent: JAccent.income,
                        label: 'Into goals',
                        value: Money.whole(review.goalCents),
                        compact: true,
                      ),
                    ),
                  ],
                ),
                if (review.biggest != null) ...[
                  const SizedBox(height: JSpace.gap),
                  JCard(
                    title: 'Biggest single entry',
                    child: Text(
                      '${Fx.format(review.biggest!.amountCents, review.biggest!.currency)} · '
                      '${review.biggest!.note.isNotEmpty ? review.biggest!.note : names[review.biggest!.categoryId] ?? 'Uncategorised'} · '
                      '${Day.relative(review.biggest!.occurredOn)}',
                      style: JType.bodyStrong.copyWith(color: c.ink, fontSize: 14),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
