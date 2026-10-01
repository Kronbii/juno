import 'dart:math' as math;

import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/plan/recurrence.dart';

/// On-device money advice. Pure functions over your data — no network, no
/// model — so every figure is explainable and testable.

// --------------------------------------------------------- safe to spend

class SpendPlan {
  const SpendPlan({
    required this.income,
    required this.incomeExpected,
    required this.spent,
    required this.committed,
    required this.daysLeft,
    required this.forecastSpend,
    this.complete = true,
  });

  /// False while a needed exchange rate is unknown; the plan is then not
  /// shown rather than shown wrong.
  final bool complete;

  /// Money in so far this month (USD cents).
  final int income;

  /// [income] plus recurring income still due this month.
  final int incomeExpected;
  final int spent;

  /// Recurring expenses still due between tomorrow and month end.
  final int committed;

  /// Days left including today.
  final int daysLeft;

  /// Month-end spend if today's pace of *unplanned* spending continues, plus
  /// the bills still due.
  final int forecastSpend;

  /// What's left to spend this month once committed bills are covered.
  int get leftToSpend => incomeExpected - spent - committed;

  /// [leftToSpend] spread over the days left. Negative when already over.
  int get perDay => daysLeft <= 0 ? leftToSpend : (leftToSpend / daysLeft).floor();

  /// Whether there's an income to plan against at all.
  bool get meaningful => complete && incomeExpected > 0;
}

/// Plans the rest of the month. [monthTxs] is this month's entries (any
/// scope filter already applied), [rules] the recurring rules (same scope).
SpendPlan planMonth({
  required List<Transaction> monthTxs,
  required List<RecurringRule> rules,
  required Map<String, Account> accounts,
  required Map<String, double> rates,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final first = DateTime(today.year, today.month);
  final last = Day.lastOfMonth(first);
  final todayStr = Day.of(today);
  final daysInMonth = Day.daysInMonth(first);
  final daysLeft = daysInMonth - today.day + 1;

  var income = 0;
  var spent = 0;
  var recurringSpent = 0;
  for (final t in monthTxs) {
    if (t.type == TxType.income) income += t.usd;
    if (t.type == TxType.expense) {
      spent += t.usd;
      if (t.recurringId != null) recurringSpent += t.usd;
    }
  }

  // Occurrences of live rules still to come this month (after today; today's
  // are posted on launch).
  var committed = 0;
  var pendingIncome = 0;
  var ratesMissing = false;
  for (final r in rules.where((r) => r.isLive)) {
    final usdAmount = Fx.tryToUsd(r.amountCents, accounts[r.accountId]?.currency ?? baseCurrency, rates);
    if (usdAmount == null) {
      ratesMissing = true;
      continue;
    }
    var d = Day.parse(r.nextDue);
    final anchor = Day.parse(r.anchorDate);
    for (var i = 0; i < 62; i++) {
      final ds = Day.of(d);
      if (ds.compareTo(last) > 0) break;
      if (r.endDate != null && ds.compareTo(r.endDate!) > 0) break;
      if (ds.compareTo(todayStr) > 0) {
        if (r.type == TxType.expense) committed += usdAmount;
        if (r.type == TxType.income) pendingIncome += usdAmount;
      }
      d = nextOccurrence(anchor: anchor, from: d, frequency: r.frequency, interval: r.interval);
    }
  }

  final unplanned = spent - recurringSpent;
  final pace = today.day == 0 ? 0 : unplanned / today.day;
  final forecast = spent + committed + (pace * (daysLeft - 1)).round();

  return SpendPlan(
    income: income,
    incomeExpected: income + pendingIncome,
    spent: spent,
    committed: committed,
    daysLeft: daysLeft,
    forecastSpend: forecast,
    complete: !ratesMissing,
  );
}

// ---------------------------------------------------------- subscriptions

class SubscriptionSuggestion {
  const SubscriptionSuggestion({
    required this.label,
    required this.amountCents,
    required this.currency,
    required this.dayOfMonth,
    required this.months,
    required this.categoryId,
    required this.accountId,
    required this.scope,
    required this.lastDay,
  });

  final String label;

  /// Typical amount, in the entries' own currency.
  final int amountCents;
  final String currency;
  final int dayOfMonth;

  /// How many monthly payments were seen.
  final int months;
  final String? categoryId;
  final String accountId;
  final Scope scope;
  final String lastDay;
}

String _key(Transaction t) => (t.merchant.isNotEmpty ? t.merchant : t.note)
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// Finds payments that look like subscriptions but aren't recurring rules
/// yet: the same merchant, a similar amount (±8%), roughly monthly (25–35
/// days apart), seen in at least three different months, the latest within
/// the last 45 days.
List<SubscriptionSuggestion> detectSubscriptions(
  List<Transaction> txs,
  List<RecurringRule> rules, {
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final groups = <String, List<Transaction>>{};
  for (final t in txs) {
    if (t.type != TxType.expense || t.recurringId != null) continue;
    final k = _key(t);
    if (k.length < 3) continue;
    (groups[k] ??= []).add(t);
  }
  final covered = {
    for (final r in rules.where((r) => r.deletedAt == null))
      r.note.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim(),
  };

  final out = <SubscriptionSuggestion>[];
  for (final MapEntry(key: k, value: list) in groups.entries) {
    if (covered.contains(k)) continue;
    list.sort((a, b) => a.occurredOn.compareTo(b.occurredOn));
    // One per month: the run of payments, ignoring a second same-month buy.
    final byMonth = <String, Transaction>{};
    for (final t in list) {
      byMonth.putIfAbsent(t.occurredOn.substring(0, 7), () => t);
    }
    final seq = byMonth.values.toList();
    if (seq.length < 3) continue;
    final amounts = [for (final t in seq) t.amountCents]..sort();
    final median = amounts[amounts.length ~/ 2];
    if (median <= 0) continue;
    final similar = seq.where((t) => (t.amountCents - median).abs() <= median * 0.08).toList();
    if (similar.length < 3) continue;
    var monthly = true;
    for (var i = 1; i < similar.length; i++) {
      final gap = Day.parse(similar[i].occurredOn).difference(Day.parse(similar[i - 1].occurredOn)).inDays;
      if (gap < 25 || gap > 35) {
        monthly = false;
        break;
      }
    }
    if (!monthly) continue;
    final latest = similar.last;
    if (today.difference(Day.parse(latest.occurredOn)).inDays > 45) continue;
    final days = [for (final t in similar) Day.parse(t.occurredOn).day]..sort();
    out.add(
      SubscriptionSuggestion(
        label: latest.merchant.isNotEmpty ? latest.merchant : latest.note,
        amountCents: median,
        currency: latest.currency,
        dayOfMonth: days[days.length ~/ 2],
        months: similar.length,
        categoryId: latest.categoryId,
        accountId: latest.accountId,
        scope: latest.scope,
        lastDay: latest.occurredOn,
      ),
    );
  }
  out.sort((a, b) => b.amountCents.compareTo(a.amountCents));
  return out;
}

// --------------------------------------------------------------- anomalies

class SpendingAlert {
  const SpendingAlert(this.text, {this.categoryId, this.transactionId});

  final String text;
  final String? categoryId;
  final String? transactionId;
}

/// Unusual spending against your own history:
/// * a category whose month-to-date spend is ≥1.5× its average at the same
///   point of the last three months (and at least $30 more);
/// * a single entry ≥3× the category's median entry (5+ samples, ≥ $50).
List<SpendingAlert> detectAnomalies({
  required List<Transaction> history,
  required Map<String, String> categoryNames,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final month = DateTime(today.year, today.month);
  final mtdEnd = today.day;
  final out = <SpendingAlert>[];

  int mtd(String? cat, DateTime m) {
    final from = Day.firstOfMonth(m);
    final to = Day.of(DateTime(m.year, m.month, math.min(mtdEnd, Day.daysInMonth(m))));
    return history
        .where((t) => t.type == TxType.expense && t.categoryId == cat)
        .where((t) => t.occurredOn.compareTo(from) >= 0 && t.occurredOn.compareTo(to) <= 0)
        .fold(0, (s, t) => s + t.usd);
  }

  final cats = history.where((t) => t.type == TxType.expense && t.categoryId != null).map((t) => t.categoryId).toSet();
  for (final c in cats) {
    final now_ = mtd(c, month);
    final past = [for (var i = 1; i <= 3; i++) mtd(c, DateTime(month.year, month.month - i))];
    final withData = past.where((v) => v > 0).toList();
    if (withData.length < 2) continue;
    final avg = withData.reduce((a, b) => a + b) / withData.length;
    if (now_ >= avg * 1.5 && now_ - avg >= 3000) {
      final ratio = now_ / avg;
      out.add(
        SpendingAlert(
          '${categoryNames[c] ?? 'A category'} is at ${Money.whole(now_)} — '
          '${ratio.toStringAsFixed(1)}× your usual by day $mtdEnd.',
          categoryId: c,
        ),
      );
    }
  }

  final monthStart = Day.firstOfMonth(month);
  final byCat = <String?, List<int>>{};
  for (final t in history.where((t) => t.type == TxType.expense && t.occurredOn.compareTo(monthStart) < 0)) {
    (byCat[t.categoryId] ??= []).add(t.usd);
  }
  for (final t in history.where((t) => t.type == TxType.expense && t.occurredOn.compareTo(monthStart) >= 0)) {
    final samples = byCat[t.categoryId];
    if (samples == null || samples.length < 5) continue;
    final sorted = [...samples]..sort();
    final median = sorted[sorted.length ~/ 2];
    if (median > 0 && t.usd >= median * 3 && t.usd >= 5000) {
      final what = t.merchant.isNotEmpty
          ? t.merchant
          : t.note.isNotEmpty
          ? t.note
          : categoryNames[t.categoryId] ?? 'an entry';
      out.add(
        SpendingAlert(
          'Unusually large: ${Money.format(t.usd)} on $what (you usually spend ${Money.whole(median)}).',
          categoryId: t.categoryId,
          transactionId: t.id,
        ),
      );
    }
  }
  return out;
}

// ------------------------------------------------------- budget suggestions

class BudgetSuggestion {
  const BudgetSuggestion(this.categoryId, this.limitCents, this.averageCents);

  final String categoryId;
  final int limitCents;
  final int averageCents;
}

/// For categories you spend in regularly but haven't budgeted: a monthly
/// limit at your three-month average, rounded up to the next $10.
List<BudgetSuggestion> suggestBudgets({
  required List<Transaction> history,
  required List<Budget> budgets,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final budgeted = {for (final b in budgets.where((b) => b.deletedAt == null)) b.categoryId};
  final totals = <String, List<int>>{};
  for (var i = 1; i <= 3; i++) {
    final m = DateTime(today.year, today.month - i);
    final from = Day.firstOfMonth(m);
    final to = Day.lastOfMonth(m);
    final sums = <String, int>{};
    for (final t in history) {
      if (t.type != TxType.expense || t.categoryId == null) continue;
      if (t.occurredOn.compareTo(from) < 0 || t.occurredOn.compareTo(to) > 0) continue;
      sums[t.categoryId!] = (sums[t.categoryId!] ?? 0) + t.usd;
    }
    for (final e in sums.entries) {
      (totals[e.key] ??= []).add(e.value);
    }
  }
  final out = <BudgetSuggestion>[];
  for (final e in totals.entries) {
    if (budgeted.contains(e.key) || e.value.length < 2) continue;
    final avg = (e.value.reduce((a, b) => a + b) / 3).round();
    if (avg < 2000) continue;
    final limit = ((avg + 999) ~/ 1000) * 1000;
    out.add(BudgetSuggestion(e.key, limit, avg));
  }
  out.sort((a, b) => b.averageCents.compareTo(a.averageCents));
  return out;
}
