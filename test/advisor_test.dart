import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/features/smart/advisor.dart';

var _n = 0;
Transaction tx(
  String day,
  int cents, {
  TxType type = TxType.expense,
  String? cat,
  String merchant = '',
  String note = '',
  String? recurringId,
  String currency = 'USD',
  int? base,
}) => Transaction(
  id: 't${_n++}',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  type: type,
  scope: Scope.personal,
  amountCents: cents,
  accountId: seedId('acct:checking'),
  categoryId: cat,
  occurredOn: day,
  note: note,
  merchant: merchant,
  currency: currency,
  baseCents: base,
  tags: '',
  recurringId: recurringId,
);

RecurringRule rule(String id, TxType type, int cents, String next, {String? end, bool active = true}) => RecurringRule(
  id: id,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  type: type,
  scope: Scope.personal,
  amountCents: cents,
  accountId: seedId('acct:checking'),
  note: id,
  frequency: Frequency.monthly,
  interval: 1,
  anchorDate: next,
  nextDue: next,
  endDate: end,
  active: active,
);

void main() {
  group('planMonth', () {
    final now = DateTime(2026, 10, 10); // 22 days left including today
    test('safe-to-spend subtracts bills still due and spreads the rest', () {
      final plan = planMonth(
        monthTxs: [
          tx('2026-10-01', 520000, type: TxType.income),
          tx('2026-10-02', 145000, recurringId: 'rent'),
          tx('2026-10-05', 20000),
          tx('2026-10-09', 10000),
        ],
        rules: [
          rule('rent', TxType.expense, 145000, '2026-11-02'), // next month: not committed
          rule('netflix', TxType.expense, 1599, '2026-10-14'),
          rule('gym', TxType.expense, 6000, '2026-10-21'),
          rule('ended', TxType.expense, 99999, '2026-10-20', end: '2026-09-30'),
          rule('paused', TxType.expense, 99999, '2026-10-20', active: false),
          rule('bonus', TxType.income, 50000, '2026-10-25'),
        ],
        accounts: const {},
        rates: const {'USD': 1},
        now: now,
      );
      expect(plan.daysLeft, 22);
      expect(plan.spent, 175000);
      expect(plan.committed, 7599);
      expect(plan.incomeExpected, 570000);
      expect(plan.leftToSpend, 570000 - 175000 - 7599);
      expect(plan.perDay, ((570000 - 175000 - 7599) / 22).floor());
      // Unplanned pace: (175000 − 145000) / 10 days = 3000/day for 21 more days.
      expect(plan.forecastSpend, 175000 + 7599 + 3000 * 21);
    });

    test('a weekly bill counts every remaining occurrence this month', () {
      final weekly = RecurringRule(
        id: 'w',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        dirty: false,
        type: TxType.expense,
        scope: Scope.personal,
        amountCents: 1000,
        accountId: 'a',
        note: 'w',
        frequency: Frequency.weekly,
        interval: 1,
        anchorDate: '2026-10-10',
        nextDue: '2026-10-10',
        active: true,
      );
      final plan = planMonth(monthTxs: const [], rules: [weekly], accounts: const {}, rates: const {}, now: now);
      // 17, 24, 31 (the 10th is today, already posted).
      expect(plan.committed, 3000);
    });
  });

  group('detectSubscriptions', () {
    test('finds a monthly same-amount merchant and skips noise', () {
      final txs = [
        tx('2026-07-12', 1599, merchant: 'NETFLIX.COM'),
        tx('2026-08-12', 1599, merchant: 'Netflix.com'),
        tx('2026-09-11', 1599, merchant: 'netflix.com'),
        // groceries: different amounts
        tx('2026-07-03', 5400, merchant: 'Spinneys'),
        tx('2026-08-03', 9100, merchant: 'Spinneys'),
        tx('2026-09-02', 3300, merchant: 'Spinneys'),
        // weekly coffee: not monthly
        for (var i = 0; i < 8; i++) tx('2026-09-${(i * 3 + 1).toString().padLeft(2, '0')}', 450, merchant: 'Kalei'),
      ];
      final s = detectSubscriptions(txs, const [], now: DateTime(2026, 10));
      expect(s.map((x) => x.label), ['netflix.com']);
      expect(s.single.amountCents, 1599);
      expect(s.single.months, 3);
      expect(s.single.dayOfMonth, 12);
    });

    test('already a recurring rule → not suggested; stale → not suggested', () {
      final txs = [
        tx('2026-04-12', 999, merchant: 'Spotify'),
        tx('2026-05-12', 999, merchant: 'Spotify'),
        tx('2026-06-12', 999, merchant: 'Spotify'),
      ];
      expect(detectSubscriptions(txs, const [], now: DateTime(2026, 10)), isEmpty); // last seen > 45 days
      final recent = [
        for (final t in txs)
          tx(
            t.occurredOn.replaceFirst('-0', '-0').replaceRange(5, 7, '0${int.parse(t.occurredOn.substring(5, 7)) + 3}'),
            999,
            merchant: 'Spotify',
          ),
      ];
      expect(
        detectSubscriptions(recent, [rule('Spotify', TxType.expense, 999, '2026-10-12')], now: DateTime(2026, 10)),
        isEmpty,
      );
    });
  });

  group('detectAnomalies', () {
    test('category running hot vs its usual pace', () {
      final h = [
        for (final m in ['07', '08', '09']) tx('2026-$m-05', 5000, cat: 'dining'),
        tx('2026-10-03', 9000, cat: 'dining'),
        tx('2026-10-05', 4000, cat: 'dining'),
      ];
      final a = detectAnomalies(history: h, categoryNames: {'dining': 'Dining'}, now: DateTime(2026, 10, 6));
      expect(a.single.text, contains(r'Dining is at $130'));
      expect(a.single.text, contains('2.6×'));
    });

    test('a single unusually large entry', () {
      final h = [
        for (var i = 1; i <= 6; i++) tx('2026-09-${i.toString().padLeft(2, '0')}', 2000, cat: 'transport'),
        tx('2026-10-02', 9000, cat: 'transport', merchant: 'Airport taxi'),
      ];
      final a = detectAnomalies(history: h, categoryNames: {'transport': 'Transport'}, now: DateTime(2026, 10, 3));
      expect(a.map((x) => x.text), contains(contains('Airport taxi')));
    });

    test('quiet months produce no alerts', () {
      final h = [
        for (final m in ['07', '08', '09', '10']) tx('2026-$m-05', 5000, cat: 'dining'),
      ];
      expect(detectAnomalies(history: h, categoryNames: const {}, now: DateTime(2026, 10, 6)), isEmpty);
    });
  });

  test(r'budget suggestions round the 3-month average up to $10', () {
    final h = [
      tx('2026-07-10', 21000, cat: 'dining'),
      tx('2026-08-10', 25500, cat: 'dining'),
      tx('2026-09-10', 23000, cat: 'dining'),
      tx('2026-09-10', 1500, cat: 'tiny'), // under $20 average: ignored
    ];
    final s = suggestBudgets(history: h, budgets: const [], now: DateTime(2026, 10, 2));
    expect(s.single.categoryId, 'dining');
    expect(s.single.averageCents, 23167);
    expect(s.single.limitCents, 24000);
  });
}
