// A year of real use, with the clock moving: the things that only show up
// after weeks — the app left open across midnight and month ends, recurring
// bills catching up, a rate change, archived categories, month and year
// turns, clock changes — checked against money invariants and by rendering
// every screen at checkpoints.
//
// ignore_for_file: cascade_invocations, the simulated life is filled in step by step between awaits
import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/add/entry_sheet.dart';
import 'package:juno/features/plan/recurrence.dart';
import 'package:juno/features/settings/balance_check.dart';

import 'support/harness.dart';

/// What the simulated user did, for the invariants.
class Life {
  final rateOn = <String, double>{}; // day -> LBP rate in force
  late String lbp;
  late String card;
  late String rent;
  late String salary;
  late String gym;
  late String generator;
  late String insurance;
}

/// Lives from 1 Jan 2026 up to and including [until], as the app would:
/// opening it every day posts due recurring entries, then the day's entries.
Future<Life> live(AppDatabase db, DateTime until) async {
  final life = Life();
  final ledger = Ledger(db);
  final rnd = Random(2026);
  await db.customSelect('SELECT 1').get();
  life.lbp = await ledger.upsertAccount(
    AccountsCompanion.insert(
      name: 'Cash LBP',
      kind: AccountKind.cash,
      currency: const Value('LBP'),
      openingBalanceCents: const Value(900000000),
    ),
  );
  life.card = await ledger.upsertAccount(AccountsCompanion.insert(name: 'Visa', kind: AccountKind.credit));
  final chk = seedId('acct:checking');
  final cash = seedId('acct:cash');
  await (db.update(db.accounts)..where((a) => a.id.equals(chk))).write(
    const AccountsCompanion(openingBalanceCents: Value(300000)),
  );
  Future<String> ruleOf(
    String note,
    TxType type,
    int cents,
    String anchor,
    Frequency f, {
    String? account,
    Scope scope = Scope.personal,
    String? cat,
  }) async {
    final id = newId();
    await db
        .into(db.recurringRules)
        .insert(
          RecurringRulesCompanion.insert(
            id: Value(id),
            type: type,
            scope: scope,
            amountCents: cents,
            accountId: account ?? chk,
            categoryId: Value(cat == null ? null : seedId('cat:$cat')),
            note: Value(note),
            frequency: f,
            anchorDate: anchor,
            nextDue: anchor,
          ),
        );
    return id;
  }

  life.salary = await ruleOf('Salary', TxType.income, 520000, '2026-01-01', Frequency.monthly, cat: 'Salary');
  life.rent = await ruleOf(
    'Rent',
    TxType.expense,
    145000,
    '2026-01-02',
    Frequency.monthly,
    scope: Scope.household,
    cat: 'Rent',
  );
  life.gym = await ruleOf('Gym', TxType.expense, 1500, '2026-01-05', Frequency.weekly, cat: 'Fitness');
  life.generator = await ruleOf(
    'Generator',
    TxType.expense,
    180000000,
    '2026-01-15',
    Frequency.monthly,
    account: life.lbp,
    scope: Scope.household,
  );
  life.insurance = await ruleOf('Insurance', TxType.expense, 48000, '2026-01-31', Frequency.monthly);

  var rate = 89500.0;
  for (var d = DateTime(2026); !d.isAfter(until); d = Day.shift(d, 1)) {
    final day = Day.of(d);
    final noon = DateTime(d.year, d.month, d.day, 12);
    if (day == '2026-05-01') {
      rate = 90000;
      await ledger.setRate('LBP', rate);
    }
    life.rateOn[day] = rate;
    // Gym paused for two months, then resumed from the next due date.
    if (day == '2026-04-01') {
      await (db.update(db.recurringRules)..where((r) => r.id.equals(life.gym))).write(
        const RecurringRulesCompanion(active: Value(false)),
      );
    }
    if (day == '2026-06-01') {
      final g = await (db.select(db.recurringRules)..where((r) => r.id.equals(life.gym))).getSingle();
      var next = Day.parse(g.nextDue);
      while (Day.of(next).compareTo(day) < 0) {
        next = nextOccurrence(anchor: Day.parse(g.anchorDate), from: next, frequency: g.frequency);
      }
      await (db.update(db.recurringRules)..where((r) => r.id.equals(life.gym))).write(
        RecurringRulesCompanion(active: const Value(true), nextDue: Value(Day.of(next))),
      );
    }
    if (day == '2026-07-01') {
      await (db.update(db.categories)..where((c) => c.id.equals(seedId('cat:Fitness')))).write(
        const CategoriesCompanion(archived: Value(true)),
      );
    }
    // Opening the app (the user skips some days entirely).
    if (rnd.nextDouble() < 0.85) await materializeRecurring(db, now: noon);

    Future<void> spend(int cents, String cat, {String? account, Scope scope = Scope.personal, String tags = ''}) =>
        ledger.addTransaction(
          TransactionsCompanion.insert(
            type: TxType.expense,
            scope: scope,
            amountCents: cents,
            accountId: account ?? cash,
            categoryId: Value(seedId('cat:$cat')),
            occurredOn: day,
            tags: Value(tags),
          ),
        );
    if (rnd.nextDouble() < 0.6) await spend(350 + rnd.nextInt(300), 'Coffee');
    if (d.day % 4 == 0) await spend(4000 + rnd.nextInt(6000), 'Groceries', account: chk, scope: Scope.household);
    if (rnd.nextDouble() < 0.2) await spend((rnd.nextInt(6) + 2) * 5000000, 'Transport', account: life.lbp);
    if (d.day == 9) await spend(22000, 'Education', account: chk, scope: Scope.household, tags: ',@karim,');
    if (day == '2026-03-18') await spend(189900, 'Shopping', account: life.card);
    // Dollars changed into pounds at the start of each month.
    if (d.day == 3) {
      await ledger.addTransaction(
        TransactionsCompanion.insert(
          type: TxType.transfer,
          scope: Scope.personal,
          amountCents: 25000,
          accountId: chk,
          toAccountId: Value(life.lbp),
          occurredOn: day,
        ),
      );
    }
    // A monthly cash count: logs what slipped through.
    if (d.day == 28) {
      final acct = await (db.select(db.accounts)..where((a) => a.id.equals(cash))).getSingle();
      final bal = (await ledger.watchBalances().first)[cash]!;
      await withClock(
        Clock.fixed(noon),
        () => applyBalanceCheck(ledger, acct, actual: bal - 1250, current: bal, fix: BalanceFix.entry),
      );
    }
  }
  // The last day is "today": opening the app posts its bills.
  await materializeRecurring(db, now: DateTime(until.year, until.month, until.day, 12));
  return life;
}

/// Money invariants after [until] days of [life].
Future<void> checkInvariants(AppDatabase db, Life life, DateTime until) async {
  final ledger = Ledger(db);
  final today = Day.of(until);
  // Balances equal a replay of every live row.
  final accounts = await db.select(db.accounts).get();
  final want = {for (final a in accounts) a.id: a.openingBalanceCents};
  for (final t in await (db.select(db.transactions)..where((t) => t.deletedAt.isNull())).get()) {
    if (t.occurredOn.compareTo(today) > 0) continue;
    switch (t.type) {
      case TxType.income:
        want[t.accountId] = want[t.accountId]! + t.amountCents;
      case TxType.expense:
        want[t.accountId] = want[t.accountId]! - t.amountCents;
      case TxType.transfer:
        want[t.accountId] = want[t.accountId]! - t.amountCents;
        want[t.toAccountId!] = want[t.toAccountId!]! + (t.toAmountCents ?? t.amountCents);
    }
  }
  expect(
    await withClock(Clock.fixed(DateTime(until.year, until.month, until.day, 12)), () => ledger.watchBalances().first),
    want,
  );

  // Every recurring bill posted exactly once per due date, never ahead.
  final dupes = await db
      .customSelect(
        'SELECT recurring_id, occurred_on, COUNT(*) AS n FROM transactions '
        'WHERE recurring_id IS NOT NULL AND deleted_at IS NULL GROUP BY recurring_id, occurred_on HAVING n > 1',
      )
      .get();
  expect(dupes, isEmpty, reason: 'a bill posted twice');
  final future = await db
      .customSelect("SELECT COUNT(*) AS n FROM transactions WHERE recurring_id IS NOT NULL AND occurred_on > '$today'")
      .getSingle();
  expect(future.read<int>('n'), 0, reason: 'a bill posted before it was due');
  Future<List<String>> posted(String rule) async => [
    for (final r
        in await db
            .customSelect(
              "SELECT occurred_on FROM transactions WHERE recurring_id = '$rule' AND deleted_at IS NULL ORDER BY occurred_on",
            )
            .get())
      r.read<String>('occurred_on'),
  ];
  // Rent on the 2nd and salary on the 1st of every month so far.
  final months = [for (var m = DateTime(2026); !m.isAfter(until); m = DateTime(m.year, m.month + 1)) m];
  expect(await posted(life.salary), [for (final m in months) Day.of(m)]);
  expect(await posted(life.rent), [
    for (final m in months)
      if (!DateTime(m.year, m.month, 2).isAfter(until)) Day.of(DateTime(m.year, m.month, 2)),
  ]);
  // Anchored on the 31st: the last day of short months, back to the 31st.
  expect(await posted(life.insurance), [
    for (final m in months)
      if (!Day.parse(Day.lastOfMonth(m)).isAfter(until)) Day.lastOfMonth(m),
  ]);
  // The paused gym bill never back-fills April–May.
  final gym = await posted(life.gym);
  expect(gym.where((d) => d.compareTo('2026-04-01') >= 0 && d.compareTo('2026-06-01') < 0), isEmpty);
  if (gym.isNotEmpty) {
    expect(gym.map((d) => Day.parse(d).weekday).toSet(), {DateTime.monday}, reason: 'weekly keeps its weekday');
  }

  // LBP entries priced at the rate in force on the day they were written.
  for (final t in await (db.select(
    db.transactions,
  )..where((t) => t.currency.equals('LBP') & t.deletedAt.isNull())).get()) {
    final rate = life.rateOn[t.occurredOn]!;
    expect(t.baseCents, (t.amountCents / rate).round(), reason: 'LBP ${t.occurredOn} ${t.note}');
  }
}

void main() {
  setUpAll(loadFonts);

  final checkpoints = [
    DateTime(2026, 1, 1, 9), // a new user, nothing before
    DateTime(2026, 1, 3, 9), // day 3: rent already paid
    DateTime(2026, 3, 1, 9),
    DateTime(2026, 3, 29, 9), // Lebanon's clocks go forward at midnight
    DateTime(2026, 5, 1, 9), // the rate changes today
    DateTime(2026, 7, 1, 9), // a category archived today
    DateTime(2026, 10, 25, 9), // clocks go back
    DateTime(2026, 12, 31, 23, 30),
    DateTime(2027, 1, 1, 0, 20), // a new year, twenty minutes old
    DateTime(2027, 1, 4, 9),
  ];

  for (final at in checkpoints) {
    testWidgets('a year of use: invariants and every screen on ${Day.of(at)} ${at.hour}:${at.minute}', (tester) async {
      await withClock(Clock(() => at), () async {
        late Life life;
        final h = await boot(
          tester,
          demo: false,
          setup: (db) async {
            life = await live(db, at);
          },
        );
        await tester.runAsync(() => checkInvariants(h.db, life, at));
        for (final r in const [
          '/home',
          '/activity',
          '/insights',
          '/plan',
          '/insights/review',
          '/assistant',
          '/settings/accounts',
        ]) {
          await h.go(r);
          expect(tester.takeException(), isNull, reason: '$r on $at');
        }
        await h.go('/home');
        expect(
          find.textContaining(Day.monthYear(at).toUpperCase()),
          findsOneWidget,
          reason: 'Home shows ${Day.monthYear(at)}',
        );
        await h.go('/plan');
        for (final tab in ['GOALS', 'RECURRING', 'CASH FLOW', 'BUDGETS']) {
          await tester.tap(find.text(tab));
          await h.settle(2);
          expect(tester.takeException(), isNull, reason: 'plan $tab on $at');
        }
        await h.go('/home');
        unawaited(showEntrySheet(h.ctx));
        await h.settle();
        expect(tester.takeException(), isNull);
        await h.dispose();
      });
    });
  }

  testWidgets('left open across midnight into a new month: screens and bills move on', (tester) async {
    var now = DateTime(2026, 10, 31, 23, 58);
    await withClock(Clock(() => now), () async {
      final h = await boot(
        tester,
        demo: false,
        setup: (db) => db
            .into(db.recurringRules)
            .insert(
              RecurringRulesCompanion.insert(
                type: TxType.expense,
                scope: Scope.household,
                amountCents: 145000,
                accountId: seedId('acct:checking'),
                note: const Value('Rent'),
                frequency: Frequency.monthly,
                anchorDate: '2026-11-01',
                nextDue: '2026-11-01',
              ),
            ),
      );
      await h.go('/home');
      expect(find.textContaining('OCTOBER 2026'), findsOneWidget);
      // Midnight passes with the window open.
      now = DateTime(2026, 11, 1, 0, 3);
      await tester.pump(const Duration(minutes: 2));
      await h.settle();
      expect(find.textContaining('NOVEMBER 2026'), findsOneWidget, reason: 'Home rolled into the new month');
      expect(
        await count(h, "SELECT COUNT(*) AS n FROM transactions WHERE note = 'Rent'"),
        1,
        reason: 'today’s bill posted',
      );
      await h.go('/insights');
      expect(find.text('November 2026'), findsOneWidget, reason: 'Insights follows the new month');
      await h.dispose();
    });
  });
}
