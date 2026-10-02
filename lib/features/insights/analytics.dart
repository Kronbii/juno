import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';

/// Totals for one period. Transfers move money between your own accounts, so
/// they are never income or spending.
class PeriodSummary {
  PeriodSummary({
    required this.income,
    required this.expense,
    required this.byScope,
    required this.byCategory,
    required this.count,
  });

  factory PeriodSummary.of(Iterable<Transaction> txs) {
    var income = 0;
    var expense = 0;
    var count = 0;
    final byScope = {for (final s in Scope.values) s: 0};
    final byCategory = <String?, int>{};
    for (final t in txs) {
      switch (t.type) {
        case TxType.income:
          income += t.usd;
          count++;
        case TxType.expense:
          expense += t.usd;
          byScope[t.scope] = byScope[t.scope]! + t.usd;
          byCategory[t.categoryId] = (byCategory[t.categoryId] ?? 0) + t.usd;
          count++;
        case TxType.transfer:
          break;
      }
    }
    return PeriodSummary(
      income: income,
      expense: expense,
      byScope: byScope,
      byCategory: byCategory,
      count: count,
    );
  }

  final int income;
  final int expense;
  final Map<Scope, int> byScope;

  /// Expense by category id (null = uncategorised).
  final Map<String?, int> byCategory;
  final int count;

  int get net => income - expense;

  /// Share of income kept, or null when there was no income.
  double? get savingsRate => income <= 0 ? null : net / income;

  /// Categories sorted by spend, descending.
  List<MapEntry<String?, int>> get rankedCategories =>
      byCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
}

/// Pace of spending within a month.
class MonthPace {
  MonthPace({required this.month, required this.expense, DateTime? today}) : _today = today ?? DateTime.now();

  final DateTime month;
  final int expense;
  final DateTime _today;

  bool get isCurrent => _today.year == month.year && _today.month == month.month;

  int get daysInMonth => Day.daysInMonth(month);

  /// Days elapsed including today (whole month for past months).
  int get daysElapsed {
    if (isCurrent) return _today.day;
    final future = DateTime(month.year, month.month).isAfter(_today);
    return future ? 0 : daysInMonth;
  }

  int get avgDaily => daysElapsed == 0 ? 0 : (expense / daysElapsed).round();

  /// Straight-line month-end estimate. Only meaningful for the current month.
  int get projected => isCurrent ? avgDaily * daysInMonth : expense;
}

/// One bar group in the trend chart.
class MonthPoint {
  const MonthPoint({
    required this.month,
    required this.income,
    required this.expense,
    required this.personal,
    required this.household,
  });

  final DateTime month;
  final int income;
  final int expense;
  final int personal;
  final int household;
}

/// Buckets transactions into the [months] calendar months ending at [last].
List<MonthPoint> monthlySeries(Iterable<Transaction> txs, DateTime last, int months) {
  final keys = [
    for (var i = months - 1; i >= 0; i--) DateTime(last.year, last.month - i),
  ];
  String k(DateTime m) => '${m.year}-${m.month.toString().padLeft(2, '0')}';
  final buckets = {for (final m in keys) k(m): <Transaction>[]};
  for (final t in txs) {
    buckets[t.occurredOn.substring(0, 7)]?.add(t);
  }
  return [
    for (final m in keys)
      () {
        final s = PeriodSummary.of(buckets[k(m)]!);
        return MonthPoint(
          month: m,
          income: s.income,
          expense: s.expense,
          personal: s.byScope[Scope.personal]!,
          household: s.byScope[Scope.household]!,
        );
      }(),
  ];
}

enum InsightTone { good, bad, neutral }

/// A plain-language observation for the Insights feed.
class Insight {
  const Insight(this.text, this.tone, {this.categoryId});

  final String text;
  final InsightTone tone;
  final String? categoryId;
}

/// Compares this period with the previous one and produces readable lines.
/// [names] maps category id → display name; [prevLabel] is e.g. "September".
List<Insight> compareInsights({
  required PeriodSummary current,
  required PeriodSummary previous,
  required Map<String, String> names,
  required String prevLabel,
  MonthPace? pace,
  int minDeltaCents = 2000,
  bool scopeShare = true,
}) {
  final out = <Insight>[];

  if (previous.expense > 0 && current.expense > 0) {
    final projecting = pace != null && pace.isCurrent;
    final basis = projecting ? pace.projected : current.expense;
    final d = (basis - previous.expense) / previous.expense;
    if (d.abs() >= 0.05) {
      final how = d > 0 ? '${_pct(d)} more' : '${_pct(-d)} less';
      out.add(
        Insight(
          projecting ? 'You are on pace to spend $how than $prevLabel.' : 'You spent $how than $prevLabel.',
          d > 0 ? InsightTone.bad : InsightTone.good,
        ),
      );
    }
  }

  final cats = {...current.byCategory.keys, ...previous.byCategory.keys}.whereType<String>();
  final deltas = <(String, int, int)>[
    for (final id in cats) (id, current.byCategory[id] ?? 0, previous.byCategory[id] ?? 0),
  ]..sort((a, b) => (b.$2 - b.$3).abs().compareTo((a.$2 - a.$3).abs()));

  for (final (id, now, before) in deltas.take(4)) {
    final diff = now - before;
    if (diff.abs() < minDeltaCents) continue;
    final name = names[id] ?? 'Uncategorised';
    if (before == 0) {
      out.add(Insight('New this month: ${Money.whole(now)} on $name.', InsightTone.neutral, categoryId: id));
    } else {
      final d = diff / before;
      out.add(
        Insight(
          '$name ${d > 0 ? 'up' : 'down'} ${_pct(d.abs())} vs $prevLabel (${Money.signed(diff)}).',
          d > 0 ? InsightTone.bad : InsightTone.good,
          categoryId: id,
        ),
      );
    }
  }

  final rate = current.savingsRate;
  if (rate != null) {
    out.add(
      Insight(
        rate >= 0
            ? 'You kept ${_pct(rate)} of your income so far.'
            : 'Spending is ${Money.whole(-current.net)} ahead of income.',
        rate >= 0.2
            ? InsightTone.good
            : rate < 0
            ? InsightTone.bad
            : InsightTone.neutral,
      ),
    );
  }

  final h = current.byScope[Scope.household]!;
  if (scopeShare && current.expense > 0 && h > 0) {
    out.add(
      Insight(
        'Household is ${_pct(h / current.expense)} of all spending.',
        InsightTone.neutral,
      ),
    );
  }
  return out;
}

String _pct(double v) => '${(v * 100).round()}%';

class MerchantTotal {
  const MerchantTotal(this.name, this.total, this.count);

  final String name;
  final int total;
  final int count;
}

/// Spending grouped by merchant (falling back to note), top [n].
List<MerchantTotal> topMerchants(Iterable<Transaction> txs, {int n = 5}) {
  final totals = <String, (String, int, int)>{};
  for (final t in txs) {
    if (t.type != TxType.expense) continue;
    final label = (t.merchant.isNotEmpty ? t.merchant : t.note).trim();
    if (label.isEmpty) continue;
    final key = label.toLowerCase();
    final cur = totals[key];
    totals[key] = (cur?.$1 ?? label, (cur?.$2 ?? 0) + t.usd, (cur?.$3 ?? 0) + 1);
  }
  final list = [for (final v in totals.values) MerchantTotal(v.$1, v.$2, v.$3)]
    ..sort((a, b) => b.total.compareTo(a.total));
  return list.take(n).toList();
}

/// Budget usage for a month.
class BudgetStatus {
  const BudgetStatus(this.budget, this.spent);

  final Budget budget;
  final int spent;

  double get ratio => budget.limitCents <= 0 ? 0 : spent / budget.limitCents;
  int get remaining => budget.limitCents - spent;
  bool get over => spent > budget.limitCents;
  bool get near => !over && ratio >= 0.8;
}

/// Spend against each budget for the given month's transactions.
List<BudgetStatus> budgetStatuses(List<Budget> budgets, Iterable<Transaction> monthTxs) {
  final expenses = monthTxs.where((t) => t.type == TxType.expense).toList();
  return [
    for (final b in budgets)
      BudgetStatus(
        b,
        expenses
            .where((t) => b.categoryId == null || t.categoryId == b.categoryId)
            .where((t) => b.scope == null || t.scope == b.scope)
            .fold(0, (s, t) => s + t.usd),
      ),
  ]..sort((a, b) => b.ratio.compareTo(a.ratio));
}

/// Net worth at the end of each of the [months] months ending at [last],
/// in USD. Balances are rebuilt from opening balances plus every entry up to
/// that day; non-USD accounts convert at today's rate (history of rates is
/// not kept, so this shows what your holdings would be worth now).
List<(DateTime, int)> netWorthSeries({
  required List<Account> accounts,
  required List<Transaction> txs,
  required Map<String, double> perUsd,
  required DateTime last,
  int months = 12,
}) {
  final byAccount = {for (final a in accounts) a.id: a};
  final ends = [
    for (var i = months - 1; i >= 0; i--) DateTime(last.year, last.month - i),
  ];
  final sorted = [...txs]..sort((a, b) => a.occurredOn.compareTo(b.occurredOn));
  final bal = {for (final a in accounts) a.id: a.openingBalanceCents};
  final out = <(DateTime, int)>[];
  var i = 0;
  final today = Day.today();
  for (final m in ends) {
    // A month's point is its last day — or today for the current month, so
    // it matches the balances shown on Home (which exclude future entries).
    final monthEnd = Day.lastOfMonth(m);
    final end = monthEnd.compareTo(today) > 0 ? today : monthEnd;
    while (i < sorted.length && sorted[i].occurredOn.compareTo(end) <= 0) {
      final t = sorted[i++];
      switch (t.type) {
        case TxType.income:
          if (bal.containsKey(t.accountId)) bal[t.accountId] = bal[t.accountId]! + t.amountCents;
        case TxType.expense:
          if (bal.containsKey(t.accountId)) bal[t.accountId] = bal[t.accountId]! - t.amountCents;
        case TxType.transfer:
          if (bal.containsKey(t.accountId)) bal[t.accountId] = bal[t.accountId]! - t.amountCents;
          final to = t.toAccountId;
          if (to != null && bal.containsKey(to)) bal[to] = bal[to]! + (t.toAmountCents ?? t.amountCents);
      }
    }
    var total = 0;
    for (final e in bal.entries) {
      final a = byAccount[e.key]!;
      final usd = Fx.tryToUsd(e.value, a.currency, perUsd);
      // A rate not loaded yet: no series rather than a wrong one.
      if (usd == null) return const [];
      total += usd;
    }
    out.add((m, total));
  }
  return out;
}

/// Household spending by family member (`@person` tags). An entry for two
/// people is split evenly between them, so the rows add up to the total;
/// household spending tagged with nobody is returned as [unassigned].
({List<(String tag, int cents)> people, int unassigned}) spendByPerson(Iterable<Transaction> txs) {
  final by = <String, int>{};
  var unassigned = 0;
  for (final t in txs) {
    if (t.type != TxType.expense) continue;
    final people = t.tagList.where(EntryTags.isPerson).toList();
    if (people.isEmpty) {
      if (t.scope == Scope.household) unassigned += t.usd;
      continue;
    }
    // Split in whole cents; the first people take any remainder.
    final share = t.usd ~/ people.length;
    var rest = t.usd - share * people.length;
    for (final p in people) {
      by[p] = (by[p] ?? 0) + share + (rest-- > 0 ? 1 : 0);
    }
  }
  final list = [for (final e in by.entries) (e.key, e.value)]..sort((a, b) => b.$2.compareTo(a.$2));
  return (people: list, unassigned: unassigned);
}
