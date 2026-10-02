import 'package:clock/clock.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/plan/recurrence.dart';

/// Something scheduled in the forecast window.
class ForecastEvent {
  const ForecastEvent({required this.day, required this.label, required this.usd, required this.ruleId});

  /// `YYYY-MM-DD`.
  final String day;
  final String label;

  /// Signed: positive money in, negative money out.
  final int usd;

  /// The rule it comes from; null for an entry already logged for a later
  /// date.
  final String? ruleId;
}

/// Where spendable money is heading over the next [days] days.
class CashForecast {
  const CashForecast({
    required this.start,
    required this.series,
    required this.events,
    required this.dailyPace,
    required this.paceDays,
    required this.complete,
  });

  /// History needed before everyday spending is projected: with two days of
  /// entries, one rent payment would forecast going broke in a week.
  static const minPaceDays = 14;

  /// Too little history yet to project everyday spending ([minPaceDays]).
  bool get learning => paceDays < minPaceDays;

  /// Spendable money today (USD cents).
  final int start;

  /// One point per day: today, then each day ahead.
  final List<(DateTime, int)> series;

  /// Recurring income and bills, and entries already dated ahead, in the
  /// window, in date order.
  final List<ForecastEvent> events;

  /// Usual unplanned spending per day, taken off every day ahead.
  final int dailyPace;

  /// How many days of history the pace came from.
  final int paceDays;

  /// False when an exchange rate was missing: some money is left out.
  final bool complete;

  int get end => series.last.$2;

  (DateTime, int) get lowest => series.reduce((a, b) => b.$2 < a.$2 ? b : a);

  /// The first day the balance goes below zero, if it does.
  DateTime? get firstBelowZero => series.where((p) => p.$2 < 0).firstOrNull?.$1;

  int get incomeAhead => events.where((e) => e.usd > 0).fold(0, (s, e) => s + e.usd);
  int get billsAhead => events.where((e) => e.usd < 0).fold(0, (s, e) => s - e.usd);
}

/// Accounts counted as spendable: everything live except savings, which is
/// money set aside rather than money to live on. Cards count (as debt).
bool isSpendable(Account a) => !a.archived && a.deletedAt == null && a.kind != AccountKind.savings;

/// Forecasts spendable money for [days] days after today.
///
/// * starts from today's balances of spendable accounts, in USD;
/// * adds each live recurring income and takes off each live recurring bill
///   on its due date (transfers between your own accounts are left out);
/// * counts entries you've already logged for a later date (they aren't in
///   today's balance yet);
/// * takes off your usual *unplanned* spending every day — the average over
///   [recent] (normally the last 90 days), counting only expenses that
///   didn't come from a recurring rule, so bills aren't counted twice.
CashForecast forecastCash({
  required List<Account> accounts,
  required Map<String, int> balances,
  required List<RecurringRule> rules,
  required List<Transaction> recent,
  required Map<String, double> rates,
  required Map<String, String> ruleLabels,
  List<Transaction> ahead = const [],
  DateTime? now,
  int days = 60,
  int paceWindow = 90,
}) {
  final n = now ?? clock.now();
  final today = DateTime(n.year, n.month, n.day);
  final todayStr = Day.of(today);
  final lastDay = Day.of(DateTime(today.year, today.month, today.day + days));
  var complete = true;

  var start = 0;
  final spendable = {for (final a in accounts.where(isSpendable)) a.id: a};
  for (final a in spendable.values) {
    final usd = Fx.tryToUsd(balances[a.id] ?? a.openingBalanceCents, a.currency, rates);
    if (usd == null) {
      complete = false;
    } else {
      start += usd;
    }
  }

  // Unplanned spending pace over the window before today (today itself is
  // still in progress, so it would drag the average down).
  final paceFrom = Day.of(DateTime(today.year, today.month, today.day - paceWindow));
  final firstEntry = recent.isEmpty
      ? null
      : recent.map((t) => t.occurredOn).reduce((a, b) => a.compareTo(b) < 0 ? a : b);
  // A newer user has less history: average over the days actually covered.
  final from = firstEntry != null && firstEntry.compareTo(paceFrom) > 0 ? firstEntry : paceFrom;
  final paceDays = firstEntry == null ? 0 : Day.between(Day.parse(from), today);
  // Bills you logged by hand before making them recurring: the schedule
  // takes them off now, so they mustn't also count as everyday spending.
  final bills = [
    for (final r in rules.where((r) => r.isLive && r.type == TxType.expense))
      (
        r.categoryId,
        r.note.trim().toLowerCase(),
        Fx.tryToUsd(r.amountCents, accountCurrency(accounts, r.accountId), rates),
      ),
  ];
  bool isBill(Transaction t) => bills.any((b) {
    final (cat, note, usd) = b;
    final sameName =
        note.isNotEmpty && (t.note.trim().toLowerCase() == note || t.merchant.trim().toLowerCase() == note);
    return sameName || cat != null && cat == t.categoryId && usd != null && (t.usd - usd).abs() <= usd * 0.15;
  });
  var unplanned = 0;
  for (final t in recent) {
    if (t.type != TxType.expense || t.recurringId != null) continue;
    if (t.occurredOn.compareTo(from) < 0 || t.occurredOn.compareTo(todayStr) >= 0) continue;
    if (!spendable.containsKey(t.accountId) || isBill(t)) continue;
    unplanned += t.usd;
  }
  final pace = paceDays < CashForecast.minPaceDays ? 0 : (unplanned / paceDays).round();

  final events = <ForecastEvent>[];
  for (final r in rules.where((r) => r.isLive && r.type != TxType.transfer && spendable.containsKey(r.accountId))) {
    final usd = Fx.tryToUsd(r.amountCents, spendable[r.accountId]!.currency, rates);
    if (usd == null) {
      complete = false;
      continue;
    }
    final anchor = Day.parse(r.anchorDate);
    var d = Day.parse(r.nextDue);
    for (var i = 0; i < 400; i++) {
      final ds = Day.of(d);
      if (ds.compareTo(lastDay) > 0) break;
      if (r.endDate != null && ds.compareTo(r.endDate!) > 0) break;
      // Today's are posted on launch, so they're already in the balance.
      if (ds.compareTo(todayStr) > 0) {
        events.add(
          ForecastEvent(
            day: ds,
            label: ruleLabels[r.id] ?? 'Recurring',
            usd: r.type == TxType.income ? usd : -usd,
            ruleId: r.id,
          ),
        );
      }
      d = nextOccurrence(anchor: anchor, from: d, frequency: r.frequency, interval: r.interval);
    }
  }
  for (final t in ahead) {
    if (t.type == TxType.transfer || !spendable.containsKey(t.accountId)) continue;
    if (t.occurredOn.compareTo(todayStr) <= 0 || t.occurredOn.compareTo(lastDay) > 0) continue;
    events.add(
      ForecastEvent(
        day: t.occurredOn,
        label: t.merchant.isNotEmpty ? t.merchant : (t.note.isNotEmpty ? t.note : 'Entry'),
        usd: t.type == TxType.income ? t.usd : -t.usd,
        ruleId: null,
      ),
    );
  }
  events.sort((a, b) => a.day.compareTo(b.day));

  final byDay = <String, int>{};
  for (final e in events) {
    byDay[e.day] = (byDay[e.day] ?? 0) + e.usd;
  }
  final series = <(DateTime, int)>[(today, start)];
  var balance = start;
  for (var i = 1; i <= days; i++) {
    final d = DateTime(today.year, today.month, today.day + i);
    balance += (byDay[Day.of(d)] ?? 0) - pace;
    series.add((d, balance));
  }
  return CashForecast(
    start: start,
    series: series,
    events: events,
    dailyPace: pace,
    paceDays: paceDays,
    complete: complete,
  );
}

String accountCurrency(List<Account> accounts, String id) =>
    accounts.where((a) => a.id == id).firstOrNull?.currency ?? baseCurrency;
