import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/features/plan/forecast.dart';
import 'package:juno/features/settings/balance_check.dart';

Account acct(String id, AccountKind kind, {String currency = 'USD', int opening = 0, bool archived = false}) => Account(
  id: id,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  name: id,
  kind: kind,
  openingBalanceCents: opening,
  currency: currency,
  archived: archived,
  sort: 0,
);

var _n = 0;
Transaction tx(
  String day,
  int cents, {
  TxType type = TxType.expense,
  String account = 'chk',
  String? recurringId,
  String note = '',
  String? category,
}) => Transaction(
  id: 'f${_n++}',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  type: type,
  scope: Scope.personal,
  amountCents: cents,
  accountId: account,
  occurredOn: day,
  note: note,
  categoryId: category,
  merchant: 'Shop',
  currency: 'USD',
  tags: '',
  recurringId: recurringId,
);

RecurringRule rule(
  String id,
  TxType type,
  int cents,
  String next, {
  String account = 'chk',
  Frequency frequency = Frequency.monthly,
  String? end,
  bool active = true,
  String? category,
}) => RecurringRule(
  id: id,
  categoryId: category,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  type: type,
  scope: Scope.personal,
  amountCents: cents,
  accountId: account,
  note: id,
  frequency: frequency,
  interval: 1,
  anchorDate: next,
  nextDue: next,
  endDate: end,
  active: active,
);

void main() {
  final now = DateTime(2026, 10, 10, 15);
  final accounts = [
    acct('chk', AccountKind.checking),
    acct('cash-lbp', AccountKind.cash, currency: 'LBP'),
    acct('card', AccountKind.credit),
    acct('save', AccountKind.savings),
    acct('old', AccountKind.checking, archived: true),
  ];
  final balances = {'chk': 200000, 'cash-lbp': 89500000, 'card': -30000, 'save': 999999, 'old': 77777};
  const rates = {'USD': 1.0, 'LBP': 89500.0};

  CashForecast run({
    List<RecurringRule> rules = const [],
    List<Transaction> recent = const [],
    List<Transaction> ahead = const [],
    Map<String, double> r = rates,
    int days = 60,
  }) => forecastCash(
    accounts: accounts,
    balances: balances,
    rules: rules,
    recent: recent,
    ahead: ahead,
    rates: r,
    ruleLabels: {for (final x in rules) x.id: x.id},
    now: now,
    days: days,
  );

  test('starts from spendable accounts only: savings and archived left out, LBP converted, cards as debt', () {
    final f = run();
    // $2,000 + LBP 895,000 ($10) − $300 card.
    expect(f.start, 200000 + 1000 - 30000);
    expect(f.series.length, 61);
    expect(f.end, f.start, reason: 'nothing scheduled, no history: flat');
    expect(f.complete, isTrue);
  });

  test('bills and income land on their due dates; today, paused, ended, savings and transfers are skipped', () {
    final f = run(
      rules: [
        rule('rent', TxType.expense, 145000, '2026-11-02'),
        rule('salary', TxType.income, 520000, '2026-11-01'),
        rule('today', TxType.expense, 5000, '2026-10-10'), // posted on launch already
        rule('paused', TxType.expense, 9999, '2026-10-20', active: false),
        rule('ended', TxType.expense, 9999, '2026-10-20', end: '2026-10-15'),
        rule('to-savings', TxType.transfer, 50000, '2026-10-20'),
        rule('on-savings', TxType.expense, 7777, '2026-10-20', account: 'save'),
        rule('weekly', TxType.expense, 1000, '2026-10-12', frequency: Frequency.weekly),
      ],
    );
    final ids = f.events.map((e) => e.ruleId).toSet();
    expect(ids, {'rent', 'salary', 'today', 'weekly'});
    expect(f.events.where((e) => e.ruleId == 'today').map((e) => e.day), ['2026-11-10']);
    expect(f.events.where((e) => e.ruleId == 'rent').map((e) => e.day), ['2026-11-02', '2026-12-02']);
    // Weekly from 12 Oct to 9 Dec: 12, 19, 26 Oct, 2, 9, 16, 23, 30 Nov, 7 Dec.
    expect(f.events.where((e) => e.ruleId == 'weekly').length, 9);
    final dayOf = {for (var i = 0; i < f.series.length; i++) f.series[i].$1: i};
    expect(f.series[dayOf[DateTime(2026, 11)]!].$2 - f.series[dayOf[DateTime(2026, 10, 31)]!].$2, 520000);
    expect(f.incomeAhead, 520000 * 2);
    expect(f.events.map((e) => e.day).toList(), [...f.events.map((e) => e.day)]..sort());
  });

  test('daily pace: unplanned spending over the last 90 days, bills and today excluded', () {
    final f = run(
      recent: [
        tx('2026-07-12', 90000), // inside the 90 days (12 Jul … 9 Oct)
        tx('2026-07-11', 50000), // outside the window
        tx('2026-09-01', 145000, recurringId: 'rent'), // a bill: comes from the schedule instead
        tx('2026-10-10', 30000), // today, still in progress
        tx('2026-09-15', 40000, type: TxType.income),
        tx('2026-09-15', 20000, account: 'save'), // savings isn't spendable
      ],
    );
    // History starts 11 Jul (first entry), clipped to the window: 90 days.
    expect(f.paceDays, 90);
    expect(f.dailyPace, 1000);
    expect(f.series[1].$2, f.start - 1000);
    expect(f.end, f.start - 60 * 1000);
  });

  test('a newer user: the pace waits for two weeks, then uses the days actually covered', () {
    // Ten days of history (rent and a coffee): not enough to project.
    final early = run(recent: [tx('2026-09-30', 120000), tx('2026-10-05', 500)]);
    expect((early.paceDays, early.dailyPace, early.learning), (10, 0, true));
    expect(early.firstBelowZero, isNull, reason: 'no "you’ll be broke in a week" from one rent payment');
    final f = run(recent: [tx('2026-09-20', 10000), tx('2026-10-05', 10000)]);
    expect((f.paceDays, f.dailyPace, f.learning), (20, 1000, false));
  });

  test('bills logged by hand before they were made recurring aren’t counted twice', () {
    final rent = rule('rent', TxType.expense, 145000, '2026-11-02', category: 'cat-rent');
    final f = run(
      rules: [rent],
      recent: [
        tx('2026-07-12', 9000), // everyday
        tx('2026-08-02', 145000, note: 'Rent'), // logged by hand, named like the rule
        tx('2026-09-02', 150000, category: 'cat-rent'), // same category, within 15%
      ],
    );
    expect(f.dailyPace, 100, reason: r'only the $90 of everyday spending, over 90 days');
  });

  test('lowest point and first day below zero', () {
    final f = run(
      rules: [rule('rent', TxType.expense, 250000, '2026-10-20'), rule('salary', TxType.income, 300000, '2026-11-01')],
    );
    expect(f.lowest, (DateTime(2026, 10, 20), 171000 - 250000));
    expect(f.firstBelowZero, DateTime(2026, 10, 20));
    expect(run().firstBelowZero, isNull);
  });

  test('entries already logged for a later date count, once', () {
    final f = run(ahead: [tx('2026-10-25', 40000), tx('2026-10-10', 999), tx('2027-01-01', 999)]);
    expect(f.events.map((e) => (e.day, e.usd, e.ruleId)), [('2026-10-25', -40000, null)]);
  });

  test('a missing exchange rate is flagged, never counted as dollars', () {
    final f = run(
      r: {'USD': 1.0},
      rules: [rule('lbp-bill', TxType.expense, 100000000, '2026-10-20', account: 'cash-lbp')],
    );
    expect(f.complete, isFalse);
    expect(f.start, 200000 - 30000);
    expect(f.events, isEmpty);
  });

  group('balance check', () {
    late AppDatabase db;
    late Ledger ledger;
    setUp(() async {
      db = AppDatabase.memory(NativeDatabase.memory());
      ledger = Ledger(db);
      await db.customSelect('SELECT 1').get();
    });
    tearDown(() => db.close());

    Future<Account> account(String id) => (db.select(db.accounts)..where((a) => a.id.equals(id))).getSingle();
    Future<int> balance(String id) async => (await ledger.watchBalances().first)[id]!;

    test('logging the difference: an expense today, tagged, and the balance now matches', () async {
      final cash = await account(seedId('acct:cash'));
      await ledger.addTransaction(
        TransactionsCompanion.insert(
          type: TxType.income,
          scope: Scope.personal,
          amountCents: 10000,
          accountId: cash.id,
          occurredOn: '2026-10-01',
        ),
      );
      final diff = await applyBalanceCheck(
        ledger,
        cash,
        actual: 6550,
        current: await balance(cash.id),
        fix: BalanceFix.entry,
        now: DateTime(2026, 10, 2),
      );
      expect(diff, -3450);
      expect(await balance(cash.id), 6550);
      final rows = await (db.select(db.transactions)..where((t) => t.note.equals('Balance check'))).get();
      expect(rows.single.type, TxType.expense);
      expect(rows.single.amountCents, 3450);
      expect(rows.single.occurredOn, '2026-10-02');
      expect(EntryTags.parse(rows.single.tags), [adjustmentTag]);
    });

    test('more than expected logs money in', () async {
      final cash = await account(seedId('acct:cash'));
      await applyBalanceCheck(ledger, cash, actual: 2500, current: 0, fix: BalanceFix.entry);
      expect(await balance(cash.id), 2500);
      expect((await db.select(db.transactions).getSingle()).type, TxType.income);
    });

    test('correcting the start moves the opening balance and logs nothing', () async {
      final chk = await account(seedId('acct:checking'));
      await applyBalanceCheck(ledger, chk, actual: -1234, current: 0, fix: BalanceFix.opening);
      expect((await account(chk.id)).openingBalanceCents, -1234);
      expect(await balance(chk.id), -1234);
      expect(await db.select(db.transactions).get(), isEmpty);
    });

    test('LBP: the difference is in pounds and priced to dollars like any entry', () async {
      final id = await ledger.upsertAccount(
        AccountsCompanion.insert(
          name: 'Cash LBP',
          kind: AccountKind.cash,
          currency: const Value('LBP'),
          openingBalanceCents: const Value(500000000),
        ),
      );
      final lbp = await account(id);
      await applyBalanceCheck(ledger, lbp, actual: 410500000, current: 500000000, fix: BalanceFix.entry);
      final t = await db.select(db.transactions).getSingle();
      expect((t.currency, t.amountCents, t.baseCents), ('LBP', 89500000, 1000));
    });

    test('a match changes nothing', () async {
      final chk = await account(seedId('acct:checking'));
      expect(await applyBalanceCheck(ledger, chk, actual: 0, current: 0, fix: BalanceFix.entry), 0);
      expect(await db.select(db.transactions).get(), isEmpty);
    });
  });
}
