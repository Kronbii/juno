import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/insights/health.dart';
import 'package:juno/features/plan/goal_pace.dart';

final _t0 = DateTime.utc(2026);
var _n = 0;

Transaction tx(
  String day,
  int cents, {
  TxType type = TxType.expense,
  Scope scope = Scope.household,
  String tags = '',
}) => Transaction(
  id: 'h${_n++}',
  createdAt: _t0,
  updatedAt: _t0,
  dirty: false,
  type: type,
  scope: scope,
  amountCents: cents,
  accountId: 'chk',
  occurredOn: day,
  note: '',
  merchant: '',
  currency: 'USD',
  tags: tags,
);

Goal goal({int target = 120000, String? date}) => Goal(
  id: 'g',
  createdAt: _t0,
  updatedAt: _t0,
  dirty: false,
  name: 'Car',
  targetCents: target,
  targetDate: date,
  colorIndex: 0,
  archived: false,
);

GoalContribution put(String day, int cents) => GoalContribution(
  id: 'c${_n++}',
  createdAt: _t0,
  updatedAt: _t0,
  dirty: false,
  goalId: 'g',
  amountCents: cents,
  occurredOn: day,
  note: '',
);

Account acct(String id, AccountKind kind, {String currency = 'USD'}) => Account(
  id: id,
  createdAt: _t0,
  updatedAt: _t0,
  dirty: false,
  name: id,
  kind: kind,
  openingBalanceCents: 0,
  currency: currency,
  archived: false,
  sort: 0,
);

RecurringRule bill(int cents, Frequency f, {int interval = 1, String account = 'chk', TxType type = TxType.expense}) =>
    RecurringRule(
      id: 'r${_n++}',
      createdAt: _t0,
      updatedAt: _t0,
      dirty: false,
      type: type,
      scope: Scope.household,
      amountCents: cents,
      accountId: account,
      note: '',
      frequency: f,
      interval: interval,
      anchorDate: '2026-01-01',
      nextDue: '2026-11-01',
      active: true,
    );

void main() {
  group('people', () {
    test('person tags: names in, tags out, and back', () {
      expect(EntryTags.personTag('Uncle Sami'), '@uncle-sami');
      expect(EntryTags.personTag('@Mom'), '@mom');
      expect(EntryTags.personTag('  '), '');
      expect(EntryTags.personName('@uncle-sami'), 'Uncle Sami');
      expect(EntryTags.isPerson('@mom'), isTrue);
      expect(EntryTags.isPerson('@'), isFalse);
      expect(EntryTags.isPerson('mom'), isFalse);
      expect(EntryTags.label('@mom'), 'for Mom');
      expect(EntryTags.label('trip'), '#trip');
      expect(EntryTags.parse(EntryTags.store(['@mom', 'gift', '@Mom'])), ['@mom', 'gift']);
    });

    test('spending by person: shared entries split to the cent, totals add up', () {
      final r = spendByPerson([
        tx('2026-09-03', 22000, tags: ',@karim,'),
        tx('2026-09-19', 4801, tags: ',@karim,@lea,'), // 2401 + 2400
        tx('2026-09-08', 6500, tags: ',@mom,gift,'),
        tx('2026-09-10', 9000), // household, nobody
        tx('2026-09-11', 500, scope: Scope.personal), // personal, nobody: not household
        tx('2026-09-12', 300000, type: TxType.income, tags: ',@mom,'), // income ignored
      ]);
      expect(r.people, [('@karim', 22000 + 2401), ('@mom', 6500), ('@lea', 2400)]);
      expect(r.unassigned, 9000);
      expect(r.people.fold(0, (s, p) => s + p.$2), 22000 + 4801 + 6500);
    });
  });

  group('goal pace', () {
    final now = DateTime(2026, 10, 15);

    test('on track: last three months average, arrival month', () {
      final p = goalPace(
        goal: goal(date: '2027-06-30'),
        saved: 40000,
        contributions: [put('2026-07-20', 20000), put('2026-08-20', 20000), put('2026-05-01', 99999)],
        now: now,
      );
      // 15 Jul … 15 Oct: two deposits of $200 over 3 months.
      expect(p.perMonth, 13333);
      expect(p.left, 80000);
      expect(p.needPerMonth, 10000); // $800 over 8 months to June
      expect(p.eta, DateTime(2027, 4)); // ceil(800 / 133.33) = 6 months
      expect(p.status, GoalStatus.onTrack);
      expect(p.line, startsWith(r'On track · $133/mo'));
    });

    test('behind when the pace misses the date, and says what is needed', () {
      final p = goalPace(
        goal: goal(date: '2026-12-31'),
        saved: 40000,
        contributions: [put('2026-09-15', 10000)],
        now: now,
      );
      expect(p.status, GoalStatus.behind);
      expect(p.needPerMonth, 40000);
      expect(p.line, contains(r'needs $400/mo'));
    });

    test('withdrawals count against the pace; nothing going in has no arrival date', () {
      final p = goalPace(
        goal: goal(date: '2027-01-31'),
        saved: 0,
        contributions: [put('2026-09-01', 30000), put('2026-09-20', -30000)],
        now: now,
      );
      expect(p.perMonth, 0);
      expect(p.eta, isNull);
      expect(p.status, GoalStatus.behind);
      expect(p.line, contains('nothing going in lately'));
    });

    test('a brand-new goal averages over the time it has existed, at least a month', () {
      final p = goalPace(goal: goal(), saved: 5000, contributions: [put('2026-10-14', 5000)], now: now);
      expect(p.perMonth, 5000);
      expect(p.status, GoalStatus.onTrack);
      expect(p.eta, DateTime(2028, 9)); // $1,150 left at $50/mo = 23 months
    });

    test(r'monthly deposits: two $500 a month apart is $500/mo, not $1,000', () {
      final g = goal(target: 600000);
      final two = goalPace(
        goal: g,
        saved: 100000,
        contributions: [put('2026-09-01', 50000), put('2026-10-01', 50000)],
        now: DateTime(2026, 10),
      );
      expect(two.perMonth, 50000);
      final four = goalPace(
        goal: g,
        saved: 200000,
        contributions: [
          for (final m in ['07', '08', '09', '10']) put('2026-$m-01', 50000),
        ],
        now: DateTime(2026, 10),
      );
      expect(four.perMonth, 50000, reason: 'the last three months, this one included');
      // Early in the month, before this month's deposit: last three full months.
      final early = goalPace(
        goal: g,
        saved: 150000,
        contributions: [
          for (final m in ['07', '08', '09']) put('2026-$m-15', 50000),
        ],
        now: DateTime(2026, 10, 2),
      );
      expect(early.perMonth, 50000);
    });

    test('reached, and no history without a date', () {
      expect(goalPace(goal: goal(), saved: 120000, contributions: const [], now: now).status, GoalStatus.reached);
      final none = goalPace(goal: goal(), saved: 0, contributions: const [], now: now);
      expect(none.status, GoalStatus.noPace);
      expect(none.line, r'$1,200 to go');
    });
  });

  group('money health', () {
    final now = DateTime(2026, 10, 15);
    final accounts = [
      acct('chk', AccountKind.checking),
      acct('save', AccountKind.savings),
      acct('card', AccountKind.credit),
      acct('lbp', AccountKind.cash, currency: 'LBP'),
    ];
    const rates = {'USD': 1.0, 'LBP': 89500.0};
    final balances = {'chk': 300000, 'save': 600000, 'card': -50000, 'lbp': 89500000};

    MoneyHealth run(List<Transaction> txs, {List<RecurringRule> rules = const [], Map<String, double> r = rates}) =>
        moneyHealth(accounts: accounts, balances: balances, rules: rules, txs: txs, rates: r, now: now);

    final threeMonths = [
      for (final m in ['07', '08', '09']) ...[
        tx('2026-$m-01', 500000, type: TxType.income),
        tx('2026-$m-05', 300000),
        tx('2026-$m-06', 4000, type: TxType.transfer),
      ],
      tx('2026-10-02', 999999), // this month: ignored
      tx('2026-06-30', 999999), // before the window: ignored
    ];

    test('runway, savings rate and card debt from the last three full months', () {
      final h = run(threeMonths);
      expect(h.months, 3);
      expect((h.from, h.to), (DateTime(2026, 7), DateTime(2026, 9)));
      expect(h.avgSpend, 300000);
      expect(h.avgIncome, 500000);
      // $3,000 + $6,000 − $500 + LBP 895,000 ($10).
      expect(h.net, 300000 + 600000 - 50000 + 1000);
      expect(h.runway, closeTo(851000 / 300000, 1e-9));
      expect(h.runwayVerdict, Verdict.weak);
      expect(h.savingsRate, closeTo(0.4, 1e-9));
      expect(h.savingsVerdict, Verdict.good);
      expect(h.cardDebt, 50000);
      expect(h.debtVerdict, Verdict.ok);
      expect(h.complete, isTrue);
    });

    test('fixed bills as a monthly amount, whatever their rhythm', () {
      final h = run(
        threeMonths,
        rules: [
          bill(145000, Frequency.monthly),
          bill(1200, Frequency.weekly), // 1200 × 52 / 12 = 5200
          bill(120000, Frequency.yearly), // 10000
          bill(60000, Frequency.monthly, interval: 3), // 20000
          bill(520000, Frequency.monthly, type: TxType.income), // not a bill
        ],
      );
      expect(h.monthlyBills, 145000 + 5200 + 10000 + 20000);
      expect(h.fixedShare, closeTo(180200 / 500000, 1e-9));
      expect(h.fixedVerdict, Verdict.good);
    });

    test('a newer user averages over the months they have, not empty ones', () {
      final h = run([tx('2026-09-01', 400000, type: TxType.income), tx('2026-09-03', 200000)]);
      expect(h.months, 1);
      expect(h.from, DateTime(2026, 9));
      expect(h.avgSpend, 200000);
    });

    test('spending more than you earn, and no history at all', () {
      final h = run([tx('2026-09-01', 100000, type: TxType.income), tx('2026-09-03', 150000)]);
      expect(h.savingsRate, closeTo(-0.5, 1e-9));
      expect(h.savingsVerdict, Verdict.weak);
      final empty = run(const []);
      expect(empty.enough, isFalse);
      expect(empty.runway, isNull);
      expect(empty.savingsRate, isNull);
    });

    test('a month you started logging late in doesn’t count as a cheap month', () {
      // First entries on 28–29 September; on 2 October that's all there is.
      final txs = [tx('2026-09-28', 4000), tx('2026-09-29', 5000), tx('2026-09-28', 300000, type: TxType.income)];
      final h = moneyHealth(
        accounts: accounts,
        balances: balances,
        rules: const [],
        txs: txs,
        rates: rates,
        now: DateTime(2026, 10, 2),
        firstEntry: '2026-09-28',
      );
      expect(h.enough, isFalse, reason: 'not "55.6 months covered — Strong"');
      // Started on the 3rd: a full month.
      final full = moneyHealth(
        accounts: accounts,
        balances: balances,
        rules: const [],
        txs: [tx('2026-09-03', 4000)],
        rates: rates,
        now: DateTime(2026, 10, 2),
        firstEntry: '2026-09-03',
      );
      expect(full.months, 1);
    });

    test('a missing rate leaves that account out and says so', () {
      final h = run(threeMonths, r: {'USD': 1.0});
      expect(h.complete, isFalse);
      expect(h.net, 300000 + 600000 - 50000);
    });
  });
}
