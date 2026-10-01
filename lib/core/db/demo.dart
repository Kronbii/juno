import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';

/// Four months of plausible activity for screenshots and trying the app.
/// Deterministic for a given [now] so test renders are stable.
Future<void> seedDemo(AppDatabase db, {DateTime? now}) async {
  final today = now ?? DateTime.now();
  final rnd = math.Random(7);
  String cat(String name) => seedId('cat:$name');
  final checking = seedId('acct:checking');
  final cash = seedId('acct:cash');
  final savings = seedId('acct:savings');

  await (db.update(
    db.accounts,
  )..where((a) => a.id.equals(checking))).write(const AccountsCompanion(openingBalanceCents: Value(420000)));
  await (db.update(
    db.accounts,
  )..where((a) => a.id.equals(savings))).write(const AccountsCompanion(openingBalanceCents: Value(1250000)));
  await (db.update(
    db.accounts,
  )..where((a) => a.id.equals(cash))).write(const AccountsCompanion(openingBalanceCents: Value(18000)));

  final rows = <TransactionsCompanion>[];
  final lbp = seedId('acct:cash-lbp');
  await db
      .into(db.accounts)
      .insertOnConflictUpdate(
        AccountsCompanion.insert(
          id: Value(lbp),
          name: 'Cash LBP',
          kind: AccountKind.cash,
          currency: const Value('LBP'),
          openingBalanceCents: const Value(450000000),
          sort: const Value(3),
        ),
      );

  void add(
    DateTime d,
    String category,
    int cents,
    Scope scope,
    String note, {
    TxType type = TxType.expense,
    String? account,
    List<String> tags = const [],
  }) {
    if (d.isAfter(today)) return;
    rows.add(
      TransactionsCompanion.insert(
        type: type,
        scope: scope,
        amountCents: cents,
        accountId: account ?? checking,
        categoryId: Value(cat(category)),
        occurredOn: Day.of(d),
        note: Value(note),
        tags: Value(EntryTags.store(tags)),
      ),
    );
  }

  void addLbp(DateTime d, String category, int pounds, Scope scope, String note) {
    if (d.isAfter(today)) return;
    rows.add(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: scope,
        amountCents: pounds * 100,
        accountId: lbp,
        categoryId: Value(cat(category)),
        occurredOn: Day.of(d),
        note: Value(note),
        currency: const Value('LBP'),
        baseCents: Value((pounds * 100 / 89500).round()),
      ),
    );
  }

  for (var m = 3; m >= 0; m--) {
    final first = DateTime(today.year, today.month - m);
    final days = Day.daysInMonth(first);
    add(first, 'Salary', 520000, Scope.personal, 'Monthly payroll', type: TxType.income);
    if (m.isEven) {
      add(
        DateTime(first.year, first.month, 18),
        'Freelance',
        85000 + rnd.nextInt(40000),
        Scope.personal,
        'Design retainer',
        type: TxType.income,
      );
    }
    add(DateTime(first.year, first.month, 2), 'Rent', 145000, Scope.household, 'Apartment rent');
    add(
      DateTime(first.year, first.month, 6),
      'Utilities',
      9000 + rnd.nextInt(5000),
      Scope.household,
      'EDL electricity',
    );
    add(DateTime(first.year, first.month, 9), 'Internet & phone', 4500, Scope.household, 'Home fibre');
    add(DateTime(first.year, first.month, 12), 'Subscriptions', 1599, Scope.personal, 'Netflix');
    add(DateTime(first.year, first.month, 14), 'Subscriptions', 2000, Scope.personal, 'Claude Pro');
    add(DateTime(first.year, first.month, 21), 'Fitness', 6000, Scope.personal, 'Gym membership');
    add(DateTime(first.year, first.month, 11), 'Dining', 7800, Scope.personal, 'Date night', tags: ['date-night']);
    add(
      DateTime(first.year, first.month, 24),
      'Gifts',
      4500 + rnd.nextInt(3000),
      Scope.household,
      'Gift for mom',
      tags: ['family', 'gift'],
    );
    if (m == 1) {
      final trip = DateTime(first.year, first.month, 5);
      add(trip, 'Travel', 38000, Scope.personal, 'Flight to Istanbul', tags: ['trip-istanbul']);
      add(trip.add(const Duration(days: 1)), 'Travel', 54000, Scope.personal, 'Hotel Galata', tags: ['trip-istanbul']);
      add(
        trip.add(const Duration(days: 2)),
        'Dining',
        6200,
        Scope.personal,
        'Karaköy Lokantası',
        tags: ['trip-istanbul'],
      );
    }
    for (var d = 1; d <= days; d++) {
      final day = DateTime(first.year, first.month, d);
      if (rnd.nextDouble() < 0.55) {
        add(
          day,
          'Coffee',
          350 + rnd.nextInt(300),
          Scope.personal,
          ['Kalei', 'Sip', 'Backburner'][rnd.nextInt(3)],
          account: rnd.nextBool() ? cash : null,
        );
      }
      if (d % 4 == 0) {
        add(
          day,
          'Groceries',
          3500 + rnd.nextInt(6500),
          Scope.household,
          ['Spinneys', 'Carrefour', 'Fahed'][rnd.nextInt(3)],
        );
      }
      if (rnd.nextDouble() < 0.22) {
        add(
          day,
          'Dining',
          1800 + rnd.nextInt(4200),
          rnd.nextDouble() < 0.3 ? Scope.household : Scope.personal,
          ['Tawlet', 'Em Sherif', 'Toters order', 'Bar Tartine'][rnd.nextInt(4)],
        );
      }
      if (rnd.nextDouble() < 0.18) add(day, 'Transport', 600 + rnd.nextInt(1400), Scope.personal, 'Bolt ride');
      if (d % 9 == 0) add(day, 'Fuel', 4000 + rnd.nextInt(2000), Scope.personal, 'Total station');
      if (rnd.nextDouble() < 0.08) {
        add(
          day,
          'Shopping',
          2500 + rnd.nextInt(12000),
          Scope.personal,
          ['Amazon', 'ABC Verdun', 'Zara'][rnd.nextInt(3)],
        );
      }
      if (rnd.nextDouble() < 0.05) {
        add(day, 'Household supplies', 1500 + rnd.nextInt(3500), Scope.household, 'Cleaning supplies');
      }
      if (rnd.nextDouble() < 0.12) {
        addLbp(day, 'Transport', 200000 + rnd.nextInt(6) * 50000, Scope.personal, 'Service taxi');
      }
      if (d == 15) addLbp(day, 'Household supplies', 1800000, Scope.household, 'Generator subscription');
      if (rnd.nextDouble() < 0.04) add(day, 'Health', 2000 + rnd.nextInt(6000), Scope.personal, 'Pharmacy');
    }
  }
  await db.batch((b) => b.insertAll(db.transactions, rows));

  await db.batch((b) {
    b.insertAll(db.budgets, [
      BudgetsCompanion.insert(categoryId: Value(cat('Dining')), limitCents: 30000),
      BudgetsCompanion.insert(categoryId: Value(cat('Groceries')), limitCents: 60000),
      BudgetsCompanion.insert(categoryId: Value(cat('Coffee')), limitCents: 6000),
      BudgetsCompanion.insert(scope: const Value(Scope.household), limitCents: 250000),
    ]);
    final g1 = seedId('goal:emergency');
    final g2 = seedId('goal:laptop');
    b
      ..insertAll(db.goals, [
        GoalsCompanion.insert(id: Value(g1), name: 'Emergency fund', targetCents: 1800000, colorIndex: const Value(2)),
        GoalsCompanion.insert(
          id: Value(g2),
          name: 'New MacBook',
          targetCents: 320000,
          colorIndex: const Value(6),
          targetDate: Value(Day.of(DateTime(today.year, today.month + 5))),
        ),
      ])
      ..insertAll(db.goalContributions, [
        GoalContributionsCompanion.insert(
          goalId: g1,
          amountCents: 1100000,
          occurredOn: Day.of(today.subtract(const Duration(days: 90))),
        ),
        GoalContributionsCompanion.insert(
          goalId: g1,
          amountCents: 150000,
          occurredOn: Day.of(today.subtract(const Duration(days: 30))),
        ),
        GoalContributionsCompanion.insert(
          goalId: g2,
          amountCents: 95000,
          occurredOn: Day.of(today.subtract(const Duration(days: 20))),
        ),
      ]);
    final nextMonth = DateTime(today.year, today.month + 1);
    b.insertAll(db.recurringRules, [
      RecurringRulesCompanion.insert(
        type: TxType.expense,
        scope: Scope.household,
        amountCents: 145000,
        accountId: checking,
        categoryId: Value(cat('Rent')),
        note: const Value('Apartment rent'),
        frequency: Frequency.monthly,
        anchorDate: Day.of(DateTime(nextMonth.year, nextMonth.month, 2)),
        nextDue: Day.of(DateTime(nextMonth.year, nextMonth.month, 2)),
      ),
      RecurringRulesCompanion.insert(
        type: TxType.expense,
        scope: Scope.personal,
        amountCents: 1599,
        accountId: checking,
        categoryId: Value(cat('Subscriptions')),
        note: const Value('Netflix'),
        frequency: Frequency.monthly,
        anchorDate: Day.of(today.add(const Duration(days: 3))),
        nextDue: Day.of(today.add(const Duration(days: 3))),
      ),
      RecurringRulesCompanion.insert(
        type: TxType.income,
        scope: Scope.personal,
        amountCents: 520000,
        accountId: checking,
        categoryId: Value(cat('Salary')),
        note: const Value('Monthly payroll'),
        frequency: Frequency.monthly,
        anchorDate: Day.of(nextMonth),
        nextDue: Day.of(nextMonth),
      ),
    ]);
  });
}
