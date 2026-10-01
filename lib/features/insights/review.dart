import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/insights/analytics.dart';

/// A period's story in numbers, computed from raw rows so it can be tested
/// and turned into text.
class Review {
  const Review({
    required this.label,
    required this.previousLabel,
    required this.now,
    required this.before,
    required this.categoryMoves,
    required this.budgetsMet,
    required this.budgetsMissed,
    required this.goalCents,
    required this.biggest,
  });

  final String label;
  final String previousLabel;
  final PeriodSummary now;
  final PeriodSummary before;

  /// (category id, this period, previous period), largest moves first.
  final List<(String?, int, int)> categoryMoves;
  final int budgetsMet;
  final int budgetsMissed;

  /// Net money into goals during the period.
  final int goalCents;
  final Transaction? biggest;

  int get spentDelta => now.expense - before.expense;

  String toText(Map<String, String> categoryNames) {
    String pct(double v) => '${(v * 100).round()}%';
    final b = StringBuffer()
      ..writeln('Juno — $label')
      ..writeln(
        'Spent ${Money.whole(now.expense)}'
        '${before.expense > 0 ? ' (${spentDelta >= 0 ? '+' : '−'}${Money.whole(spentDelta.abs())} vs $previousLabel)' : ''}',
      )
      ..writeln('Income ${Money.whole(now.income)} · kept ${now.savingsRate == null ? '—' : pct(now.savingsRate!)}')
      ..writeln(
        'Personal ${Money.whole(now.byScope[Scope.personal]!)} · Household ${Money.whole(now.byScope[Scope.household]!)}',
      );
    if (categoryMoves.isNotEmpty) {
      b.writeln('Biggest moves:');
      for (final (id, a, p) in categoryMoves.take(3)) {
        final d = a - p;
        b.writeln(
          '  ${categoryNames[id] ?? 'Uncategorised'} ${Money.whole(a)} (${d >= 0 ? '+' : '−'}${Money.whole(d.abs())})',
        );
      }
    }
    if (budgetsMet + budgetsMissed > 0) b.writeln('Budgets: $budgetsMet kept, $budgetsMissed over');
    if (goalCents != 0) b.writeln('Into goals: ${Money.whole(goalCents)}');
    if (biggest != null) {
      final what = biggest!.note.isNotEmpty ? biggest!.note : categoryNames[biggest!.categoryId] ?? 'an entry';
      b.writeln('Biggest: ${Money.whole(biggest!.usd)} on $what');
    }
    return b.toString().trimRight();
  }
}

/// Builds a review for [from]..[to] against the equally long period before.
Review buildReview({
  required String label,
  required String previousLabel,
  required List<Transaction> current,
  required List<Transaction> previous,
  required List<Budget> budgets,
  required List<GoalContribution> contributions,
  required List<DateTime> months,
}) {
  final now = PeriodSummary.of(current);
  final before = PeriodSummary.of(previous);
  final ids = {...now.byCategory.keys, ...before.byCategory.keys};
  final moves = [
    for (final id in ids) (id, now.byCategory[id] ?? 0, before.byCategory[id] ?? 0),
  ]..sort((a, b) => (b.$2 - b.$3).abs().compareTo((a.$2 - a.$3).abs()));

  // Budgets are monthly: judge each budget in each month of the period.
  var met = 0;
  var missed = 0;
  for (final m in months) {
    final monthTx = current.where((t) => t.occurredOn.startsWith(Day.firstOfMonth(m).substring(0, 7))).toList();
    for (final s in budgetStatuses(budgets, monthTx)) {
      if (s.over) {
        missed++;
      } else {
        met++;
      }
    }
  }
  final expenses = current.where((t) => t.type == TxType.expense).toList()..sort((a, b) => b.usd.compareTo(a.usd));
  return Review(
    label: label,
    previousLabel: previousLabel,
    now: now,
    before: before,
    categoryMoves: moves.where((m) => m.$2 != m.$3).toList(),
    budgetsMet: met,
    budgetsMissed: missed,
    goalCents: contributions.fold(0, (a, c) => a + c.amountCents),
    biggest: expenses.firstOrNull,
  );
}
