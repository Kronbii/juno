import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/plan/recurrence.dart';
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
      // No full month of history: this month's everyday pace, (175000 −
      // 145000) / 10 days = 3000/day, for the 21 days after today.
      expect(plan.forecastSpend, 175000 + 7599 + 3000 * 21);
    });

    test('month-end estimate: the usual rest of the month, or nothing too early to tell', () {
      final rent = [tx('2026-10-01', 120000)];
      // Day 1 with no history: no estimate (it would be 31 × the rent).
      expect(
        planMonth(
          monthTxs: rent,
          rules: const [],
          accounts: const {},
          rates: const {},
          now: DateTime(2026, 10),
        ).forecastSpend,
        isNull,
      );
      // With history: spent + what usually follows the 1st.
      final plan = planMonth(
        monthTxs: rent,
        rules: const [],
        accounts: const {},
        rates: const {},
        now: DateTime(2026, 10),
        usualRest: 60000,
      );
      expect(plan.forecastSpend, 180000);
      // Bills still due count when they exceed the usual rest.
      final billed = planMonth(
        monthTxs: rent,
        rules: [rule('school', TxType.expense, 90000, '2026-10-20')],
        accounts: const {},
        rates: const {},
        now: DateTime(2026, 10),
        usualRest: 60000,
      );
      expect(billed.forecastSpend, 120000 + 90000);
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

  test('widget presets: two most frequent USD categories at their median', () {
    Category c(String id, String name) => Category(
      id: id,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      dirty: false,
      name: name,
      icon: 'dots',
      colorIndex: 0,
      kind: CategoryKind.expense,
      defaultScope: Scope.personal,
      sort: 0,
      archived: false,
    );
    final cats = {'coffee': c('coffee', 'Coffee'), 'groc': c('groc', 'Groceries'), 'rare': c('rare', 'Rare')};
    final recent = [
      for (final v in [380, 420, 450, 400, 900]) tx('2026-09-10', v, cat: 'coffee'),
      for (final v in [3500, 4200, 6100]) tx('2026-09-10', v, cat: 'groc'),
      for (final v in [100, 100]) tx('2026-09-10', v, cat: 'rare'), // too few
      for (var i = 0; i < 6; i++) tx('2026-09-10', 4000000, cat: 'groc', currency: 'LBP', base: 4470), // not USD
    ];
    final p = quickPresets(recent, cats);
    expect(p.map((x) => x.label), [r'Coffee $4', r'Groceries $42']);
  });

  test('editing a bill: a new frequency or interval re-anchors it; other edits keep the anchor', () {
    final monthly = rule('ins', TxType.expense, 48000, '2026-10-31').copyWith(anchorDate: '2026-01-31');
    // Switched to yearly with next on 31 Oct: anchored there, so 31 Oct 2027 follows, not 31 Jan.
    final a = anchorAfterEdit(monthly, start: '2026-10-31', frequency: Frequency.yearly, interval: 1);
    expect(a, '2026-10-31');
    expect(
      Day.of(nextOccurrence(anchor: Day.parse(a), from: DateTime(2026, 10, 31), frequency: Frequency.yearly)),
      '2027-10-31',
    );
    // Same rhythm, same next date (say, a new amount): the 31st anchor stays,
    // so February's clamp still returns to the 31st in March.
    expect(anchorAfterEdit(monthly, start: '2026-10-31', frequency: Frequency.monthly, interval: 1), '2026-01-31');
    expect(anchorAfterEdit(monthly, start: '2026-10-31', frequency: Frequency.monthly, interval: 2), '2026-10-31');
    expect(anchorAfterEdit(null, start: '2026-10-12', frequency: Frequency.weekly, interval: 1), '2026-10-12');
  });

  test('budget suggestions average over the months you used Juno', () {
    // A new user: only September has entries (dining $300).
    final s = suggestBudgets(
      history: [
        tx('2026-09-05', 15000, cat: 'd'),
        tx('2026-09-20', 15000, cat: 'd'),
      ],
      budgets: const [],
      now: DateTime(2026, 10, 10),
    );
    expect(s, isEmpty, reason: 'one month is not "regular"');
    final two = suggestBudgets(
      history: [
        tx('2026-08-05', 30000, cat: 'd'),
        tx('2026-09-05', 30000, cat: 'd'),
      ],
      budgets: const [],
      now: DateTime(2026, 10, 10),
    );
    expect(two.single.averageCents, 30000, reason: r'$300 a month, not $200 (divided by 3)');
  });
}
