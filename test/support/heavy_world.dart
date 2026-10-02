// A ledger after years of real use, for layout and scale tests: LBP
// balances in the billions, $100k+ months, long and Arabic names, emoji,
// 40 categories, 15 accounts (some archived), 30 budgets, 20 goals, 60
// recurring rules, 50 tags, 10 family members, thousands of history rows.
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';

const longCat = [
  'Kids school tuition, books, uniforms, transport and the afternoon tutoring sessions',
  'مصاريف المدرسة والكتب والقرطاسية للأولاد',
  '🍕 Pizza Fridays with the cousins 🎉',
  'Generator subscription (اشتراك موتور) — building 3, floor 7',
  'Supercalifragilisticexpialidociousandthensomemorewords',
  'Car loan installment + insurance + mechanic + parking at the office garage downtown',
];

const longAcct = [
  'Fransabank LBP salary account — old lira only, do not use for fresh dollars',
  'حساب التوفير في بنك عودة',
  'Visa Platinum credit card ending 4432 — shared with spouse',
  'Cash in the drawer at home 💵',
];

const notes = [
  '',
  '',
  'Spinneys weekly shop',
  'Dinner at Em Sherif with the whole family for Teta birthday, valet and tip included, plus dessert takeaway box',
  'فاتورة الكهرباء والمولد لشهر أيلول',
  '☕️ coffee',
  'Taxi to Hamra',
  'Pharmacy — Panadol, vitamins, and the prescription refill for dad (insurance partially reimbursed later)',
];
const merchants = [
  '',
  '',
  'Spinneys',
  'Carrefour Hazmieh',
  'Abou Hassan Supermarket',
  'TotalEnergies',
  'ABC Achrafieh',
];

String ago(DateTime today, int d) => Day.of(DateTime(today.year, today.month, today.day - d));

/// [txCount] entries over ~3 years; 40 categories, 15 accounts (LBP in the
/// billions), 30 budgets, 20 goals, 60 recurring rules, 50 tags, 10 people,
/// a few archived accounts/categories still referenced by rules/budgets.
Future<void> heavyWorld(AppDatabase db, {int txCount = 20000, bool history = true}) async {
  final rnd = Random(7);
  final today = DateTime.now();
  final now = DateTime.now().toUtc();

  // --- categories
  final catIds = <String>[];
  final incomeIds = <String>[seedId('cat:Salary'), seedId('cat:Freelance')];
  await db.batch((b) {
    for (var i = 0; i < 40; i++) {
      final id = 'cat-heavy-$i';
      final income = i >= 36;
      final name = i < longCat.length
          ? longCat[i]
          : 'Category number $i ${i.isEven ? 'with a fairly long descriptive name' : ''}';
      b.insert(
        db.categories,
        CategoriesCompanion.insert(
          id: Value(id),
          name: name,
          icon: 'dots',
          colorIndex: i % 8,
          kind: income ? CategoryKind.income : CategoryKind.expense,
          sort: Value(100 + i),
          archived: Value(i >= 30 && i < 34),
        ),
      );
      (income ? incomeIds : catIds).add(id);
    }
  });

  // --- accounts
  final acctIds = <String>[];
  final acctCur = <String, String>{};
  final archivedAcct = <String>{};
  await db.batch((b) {
    for (var i = 0; i < 15; i++) {
      final id = 'acct-heavy-$i';
      final lbp = i % 3 == 0;
      final name = i < longAcct.length ? longAcct[i] : 'Account $i ${lbp ? 'LBP' : 'USD'}';
      final archived = i >= 12;
      b.insert(
        db.accounts,
        AccountsCompanion.insert(
          id: Value(id),
          name: name,
          kind: i == 2 ? AccountKind.credit : (i == 1 ? AccountKind.savings : AccountKind.checking),
          currency: Value(lbp ? 'LBP' : 'USD'),
          // LBP 4,500,000,000 / $250,000
          openingBalanceCents: Value(lbp ? 450000000000 : (i == 2 ? -1250000 : 25000000)),
          archived: Value(archived),
          sort: Value(10 + i),
        ),
      );
      acctIds.add(id);
      acctCur[id] = lbp ? 'LBP' : 'USD';
      if (archived) archivedAcct.add(id);
    }
  });
  final liveAccts = acctIds.where((a) => !archivedAcct.contains(a)).toList();

  // --- tags & people
  final tags = [
    for (var i = 0; i < 50; i++) i == 0 ? 'summer-trip-to-istanbul-and-cappadocia-with-the-kids-2025' : 'tag$i',
  ];
  final people = [
    '@mom',
    '@dad',
    '@teta-im-georges',
    '@uncle-sami',
    '@karim',
    '@lea',
    '@nour',
    '@cousin-elie-from-zahle-who-always-borrows',
    '@maya',
    '@jad',
  ];

  // --- transactions
  final rows = <TransactionsCompanion>[];
  for (var i = 0; i < txCount; i++) {
    final d = rnd.nextInt(1095);
    final r = rnd.nextDouble();
    final type = r < 0.85
        ? TxType.expense
        : r < 0.95
        ? TxType.income
        : TxType.transfer;
    final acct = liveAccts[rnd.nextInt(liveAccts.length)];
    final lbp = acctCur[acct] == 'LBP';
    var cents = lbp ? (rnd.nextInt(900) + 1) * 5000000 : rnd.nextInt(30000) + 100;
    if (rnd.nextInt(400) == 0) cents = lbp ? 450000000000 : 2500000000; // LBP 4.5B, or $25M (capped below)
    if (!lbp && cents > 1000000000) cents = 8500000; // $85,000
    final t = <String>[
      if (rnd.nextInt(4) == 0) tags[rnd.nextInt(tags.length)],
      if (rnd.nextInt(6) == 0) people[rnd.nextInt(people.length)],
      if (rnd.nextInt(20) == 0) people[rnd.nextInt(people.length)],
    ];
    final toAcct = type == TxType.transfer ? liveAccts[(liveAccts.indexOf(acct) + 1) % liveAccts.length] : null;
    final toLbp = toAcct != null && acctCur[toAcct] == 'LBP';
    rows.add(
      TransactionsCompanion.insert(
        type: type,
        scope: rnd.nextBool() ? Scope.personal : Scope.household,
        amountCents: cents,
        accountId: acct,
        toAccountId: Value(toAcct),
        toAmountCents: Value(
          toAcct == null || toLbp == lbp ? null : (toLbp ? (cents * 89500) : (cents / 89500).round()),
        ),
        categoryId: Value(
          type == TxType.transfer
              ? null
              : type == TxType.income
              ? incomeIds[rnd.nextInt(incomeIds.length)]
              : catIds[rnd.nextInt(catIds.length)],
        ),
        occurredOn: ago(today, d),
        note: Value(notes[rnd.nextInt(notes.length)]),
        merchant: Value(merchants[rnd.nextInt(merchants.length)]),
        currency: Value(lbp ? 'LBP' : 'USD'),
        baseCents: Value(lbp ? (cents / 89500).round() : null),
        tags: Value(EntryTags.store(t)),
      ),
    );
  }
  // This month: a few huge USD entries so hero/metric figures reach $100k+.
  for (final (c, n) in [(25000000, 'Down payment on the apartment in Mar Mikhael'), (8500000, 'New car')]) {
    rows.add(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.household,
        amountCents: c,
        accountId: liveAccts[1],
        categoryId: Value(catIds[0]),
        occurredOn: Day.of(today),
        note: Value(n),
      ),
    );
  }
  rows.add(
    TransactionsCompanion.insert(
      type: TxType.income,
      scope: Scope.personal,
      amountCents: 45000000,
      accountId: liveAccts[1],
      categoryId: Value(incomeIds.first),
      occurredOn: Day.of(DateTime(today.year, today.month)),
      note: const Value('Bonus'),
    ),
  );
  for (var i = 0; i < rows.length; i += 2000) {
    await db.batch((b) => b.insertAll(db.transactions, rows.sublist(i, min(i + 2000, rows.length))));
  }

  // --- budgets (30), some on archived categories
  await db.batch((b) {
    for (var i = 0; i < 30; i++) {
      b.insert(
        db.budgets,
        BudgetsCompanion.insert(
          categoryId: Value(i < 28 ? catIds[i] : null),
          scope: Value(i.isEven ? null : Scope.household),
          limitCents: (rnd.nextInt(50) + 1) * 100000 + (i == 0 ? 5000000 : 0),
        ),
      );
    }
  });

  // --- goals (20)
  final goalIds = <String>[];
  await db.batch((b) {
    for (var i = 0; i < 20; i++) {
      final id = 'goal-heavy-$i';
      goalIds.add(id);
      b.insert(
        db.goals,
        GoalsCompanion.insert(
          id: Value(id),
          name: i == 0
              ? 'Emergency fund — six months of expenses for the whole family including school fees and generator'
              : i == 1
              ? 'شقة في الأشرفية'
              : 'Goal $i',
          targetCents: 150000000 + i * 1000000,
          targetDate: Value(ago(today, -400 - i * 30)),
          colorIndex: Value(i % 8),
        ),
      );
      for (var k = 0; k < 24; k++) {
        b.insert(
          db.goalContributions,
          GoalContributionsCompanion.insert(
            goalId: id,
            amountCents: 500000 + rnd.nextInt(500000),
            occurredOn: ago(today, k * 30),
          ),
        );
      }
    }
  });

  // --- recurring (60), some on LBP and archived accounts
  await db.batch((b) {
    for (var i = 0; i < 60; i++) {
      final acct = i < 6 ? acctIds[12 + i % 3] : acctIds[i % 12];
      final lbp = acctCur[acct] == 'LBP';
      final f = i % 10 == 0
          ? Frequency.yearly
          : i % 3 == 0
          ? Frequency.weekly
          : Frequency.monthly;
      final next = ago(today, -(i % 8));
      b.insert(
        db.recurringRules,
        RecurringRulesCompanion.insert(
          type: i % 7 == 0 ? TxType.income : TxType.expense,
          scope: i.isEven ? Scope.household : Scope.personal,
          amountCents: lbp ? (i == 0 ? 450000000000 : 4500000000) : 12000 + i * 1000,
          accountId: acct,
          categoryId: Value(catIds[i % catIds.length]),
          note: Value(
            i == 1
                ? 'Monthly transfer to the building committee for the generator, elevator maintenance and the concierge'
                : i == 2
                ? 'اشتراك الإنترنت'
                : '',
          ),
          frequency: f,
          anchorDate: next,
          nextDue: next,
        ),
      );
    }
  });

  // --- entry history: a few thousand prior versions
  if (history) {
    final some = await (db.select(db.transactions)..limit(2000)).get();
    await db.batch((b) {
      for (final t in some) {
        for (var k = 0; k < 3; k++) {
          b.insert(
            db.entryHistory,
            EntryHistoryCompanion.insert(
              transactionId: t.id,
              snapshot: jsonEncode(t.toJson()),
              action: 'edit',
              at: now,
            ),
          );
        }
      }
    });
  }
}
