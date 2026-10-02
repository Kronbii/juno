import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/plan/recurrence.dart';

enum Verdict { good, ok, weak }

/// Four plain measures of financial footing, from the last full months.
class MoneyHealth {
  const MoneyHealth({
    required this.months,
    required this.from,
    required this.to,
    required this.avgSpend,
    required this.avgIncome,
    required this.net,
    required this.monthlyBills,
    required this.cardDebt,
    required this.complete,
  });

  /// Full months with entries that the averages come from (0–3).
  final int months;

  /// First and last month used (first days).
  final DateTime from;
  final DateTime to;
  final int avgSpend;
  final int avgIncome;

  /// What you have today in USD: cash, current and savings accounts, minus
  /// card balances owed.
  final int net;

  /// Live recurring bills as a monthly amount (weekly × 52 / 12, …).
  final int monthlyBills;

  /// Owed on cards today (positive).
  final int cardDebt;

  /// False when an exchange rate was missing.
  final bool complete;

  bool get enough => months > 0 && avgSpend > 0;

  /// Months your money would cover at your usual spending.
  double? get runway => !enough ? null : math.max(0, net) / avgSpend;

  double? get savingsRate => months == 0 || avgIncome <= 0 ? null : (avgIncome - avgSpend) / avgIncome;

  /// Share of income that recurring bills take.
  double? get fixedShare => avgIncome <= 0 ? null : monthlyBills / avgIncome;

  Verdict? get runwayVerdict =>
      runway == null ? null : (runway! >= 6 ? Verdict.good : (runway! >= 3 ? Verdict.ok : Verdict.weak));

  Verdict? get savingsVerdict => savingsRate == null
      ? null
      : (savingsRate! >= 0.2 ? Verdict.good : (savingsRate! >= 0.05 ? Verdict.ok : Verdict.weak));

  Verdict? get fixedVerdict => fixedShare == null
      ? null
      : (fixedShare! <= 0.5 ? Verdict.good : (fixedShare! <= 0.7 ? Verdict.ok : Verdict.weak));

  Verdict get debtVerdict => cardDebt == 0 ? Verdict.good : (cardDebt <= avgIncome * 0.3 ? Verdict.ok : Verdict.weak);
}

/// [txs] should cover at least the [window] full months before [now]'s
/// month; anything else is ignored.
MoneyHealth moneyHealth({
  required List<Account> accounts,
  required Map<String, int> balances,
  required List<RecurringRule> rules,
  required List<Transaction> txs,
  required Map<String, double> rates,
  DateTime? now,
  int window = 3,
}) {
  final n = now ?? clock.now();
  final to = DateTime(n.year, n.month - 1);
  var from = DateTime(n.year, n.month - window);
  var complete = true;

  // Only months that have entries count, so a new user isn't averaged
  // against empty months.
  final spend = <String, int>{};
  final income = <String, int>{};
  final seen = <String>{};
  final fromStr = Day.firstOfMonth(from);
  final toStr = Day.lastOfMonth(to);
  for (final t in txs) {
    if (t.occurredOn.compareTo(fromStr) < 0 || t.occurredOn.compareTo(toStr) > 0) continue;
    final m = t.occurredOn.substring(0, 7);
    seen.add(m);
    if (t.type == TxType.expense) spend[m] = (spend[m] ?? 0) + t.usd;
    if (t.type == TxType.income) income[m] = (income[m] ?? 0) + t.usd;
  }
  final months = seen.length;
  if (seen.isNotEmpty) from = Day.parse('${(seen.toList()..sort()).first}-01');
  int avg(Map<String, int> m) => months == 0 ? 0 : (m.values.fold(0, (s, v) => s + v) / months).round();

  var net = 0;
  var debt = 0;
  for (final a in accounts.where((a) => !a.archived && a.deletedAt == null)) {
    final usd = Fx.tryToUsd(balances[a.id] ?? a.openingBalanceCents, a.currency, rates);
    if (usd == null) {
      complete = false;
      continue;
    }
    net += usd;
    if (a.kind == AccountKind.credit && usd < 0) debt -= usd;
  }

  final currency = {for (final a in accounts) a.id: a.currency};
  var bills = 0.0;
  for (final r in rules.where((r) => r.isLive && r.type == TxType.expense)) {
    final usd = Fx.tryToUsd(r.amountCents, currency[r.accountId] ?? baseCurrency, rates);
    if (usd == null) {
      complete = false;
      continue;
    }
    final perYear = switch (r.frequency) {
      Frequency.weekly => 52,
      Frequency.monthly => 12,
      Frequency.yearly => 1,
    };
    bills += usd * perYear / 12 / math.max(1, r.interval);
  }

  return MoneyHealth(
    months: months,
    from: from,
    to: to,
    avgSpend: avg(spend),
    avgIncome: avg(income),
    net: net,
    monthlyBills: bills.round(),
    cardDebt: debt,
    complete: complete,
  );
}
