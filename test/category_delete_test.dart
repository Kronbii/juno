import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';

import 'support/harness.dart';

void main() {
  // Personal, personal, household.
  final coffee = seedId('cat:Dates');
  final dining = seedId('cat:Food & Outings');
  final groceries = seedId('cat:Groceries');
  final clothes = seedId('cat:Clothes & Accessories');

  Future<AppDatabase> fresh() async {
    final db = AppDatabase.memory(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    return db;
  }

  TransactionsCompanion entry(String category, int cents, {String? id}) => TransactionsCompanion.insert(
    id: id == null ? const Value.absent() : Value(id),
    type: TxType.expense,
    scope: Scope.personal,
    amountCents: cents,
    accountId: seedId('acct:cash'),
    categoryId: Value(category),
    occurredOn: Day.today(),
  );

  Future<int> count(AppDatabase db, String sql) async => (await db.customSelect(sql).getSingle()).read<int>('n');

  test('history moves to the chosen category; totals unchanged; the category is a synced tombstone', () async {
    final db = await fresh();
    addTearDown(db.close);
    final l = Ledger(db);
    await l.addTransaction(entry(coffee, 450));
    await l.addTransaction(entry(coffee, 550));
    final gone = await l.addTransaction(entry(coffee, 300));
    await l.deleteTransaction(gone);
    await l.addTransaction(entry(dining, 2000));
    await l.upsertRecurring(
      RecurringRulesCompanion.insert(
        type: TxType.expense,
        scope: Scope.personal,
        amountCents: 500,
        accountId: seedId('acct:cash'),
        categoryId: Value(coffee),
        frequency: Frequency.monthly,
        anchorDate: Day.today(),
        nextDue: Day.today(),
      ),
    );
    final before = await count(db, 'SELECT SUM(amount_cents) n FROM transactions WHERE deleted_at IS NULL');

    await l.deleteCategory(coffee, intoId: dining);

    expect(await count(db, "SELECT COUNT(*) n FROM transactions WHERE category_id = '$coffee'"), 0);
    expect(
      await count(db, "SELECT COUNT(*) n FROM transactions WHERE category_id = '$dining'"),
      4,
      reason: 'the deleted entry moves too, so an undo lands in Dining',
    );
    expect(await count(db, 'SELECT SUM(amount_cents) n FROM transactions WHERE deleted_at IS NULL'), before);
    expect(await count(db, "SELECT COUNT(*) n FROM recurring_rules WHERE category_id = '$dining'"), 1);
    final cat = await (db.select(db.categories)..where((c) => c.id.equals(coffee))).getSingle();
    expect(cat.deletedAt, isNotNull);
    expect(cat.dirty, isTrue);
    expect(await count(db, "SELECT COUNT(*) n FROM transactions WHERE category_id = '$dining' AND dirty = 1"), 4);
  });

  test('budgets: added to the target budget in the same scope, moved when there is none', () async {
    final db = await fresh();
    addTearDown(db.close);
    final l = Ledger(db);
    await l.upsertBudget(BudgetsCompanion.insert(categoryId: Value(coffee), limitCents: 6000));
    await l.upsertBudget(BudgetsCompanion.insert(categoryId: Value(dining), limitCents: 30000));
    await l.upsertBudget(BudgetsCompanion.insert(categoryId: Value(groceries), limitCents: 50000));

    await l.deleteCategory(coffee, intoId: dining);
    final live = await (db.select(db.budgets)..where((b) => b.deletedAt.isNull())).get();
    expect(live.where((b) => b.categoryId == dining).single.limitCents, 36000);
    expect(live.where((b) => b.categoryId == coffee), isEmpty);

    await l.deleteCategory(groceries, intoId: seedId('cat:Utilities'));
    final after = await (db.select(db.budgets)..where((b) => b.deletedAt.isNull())).get();
    expect(after.where((b) => b.categoryId == seedId('cat:Utilities')).single.limitCents, 50000);
  });

  test('an entry another device logged in the deleted category before syncing follows it', () async {
    final db = await fresh();
    addTearDown(db.close);
    final l = Ledger(db);
    await l.deleteCategory(coffee, intoId: dining);
    // Dining is later merged into Clothes: the earlier move follows on.
    await l.deleteCategory(dining, intoId: clothes);
    // Arrives from the phone with the old category, as sync would write it.
    await db.into(db.transactions).insert(entry(coffee, 400, id: 'from-phone'));

    expect(await l.remapMergedCategories(), 1);
    final t = await (db.select(db.transactions)..where((x) => x.id.equals('from-phone'))).getSingle();
    expect(t.categoryId, clothes);
    expect(t.dirty, isTrue, reason: 'the move is pushed back so the phone sees it');
    expect(await l.remapMergedCategories(), 0);
  });

  test('a category cannot be merged into itself', () async {
    final db = await fresh();
    addTearDown(db.close);
    expect(() => Ledger(db).deleteCategory(coffee, intoId: coffee), throwsArgumentError);
  });

  test("spending moves only within its scope, so no scope's total changes", () async {
    final db = await fresh();
    addTearDown(db.close);
    final l = Ledger(db);
    await l.addTransaction(entry(coffee, 450));
    expect(() => l.deleteCategory(coffee, intoId: groceries), throwsArgumentError);
    expect((await (db.select(db.categories)..where((c) => c.id.equals(coffee))).getSingle()).deletedAt, isNull);
    // Income has no scope: any income category will do.
    await l.deleteCategory(seedId('cat:Freelance'), intoId: seedId('cat:Salary'));
  });

  testWidgets('settings: delete asks where history goes, then moves it', (tester) async {
    final h = await boot(tester, demo: false, setup: (db) => Ledger(db).addTransaction(entry(coffee, 450)));
    await h.go('/settings/categories');
    await tester.tap(find.text('Dates'));
    await h.settle();
    await tester.ensureVisible(find.text('Delete category'));
    await tester.tap(find.text('Delete category'));
    await h.settle();
    expect(find.textContaining('Its 1 entry'), findsOneWidget);
    final confirm = find.widgetWithText(InkWell, 'Delete and move history');
    expect(tester.widget<InkWell>(confirm.first).onTap, isNull, reason: 'nothing happens until a target is chosen');
    expect(find.text('Rent'), findsNothing, reason: 'a household category is no home for personal spending');
    await tester.tap(find.text('Food & Outings').last);
    await h.settle(1);
    await tester.tap(find.text('Delete and move history'));
    await h.settle();
    expect(await count(h.db, "SELECT COUNT(*) n FROM transactions WHERE category_id = '$dining'"), 1);
    expect(find.textContaining('moved to Food & Outings'), findsOneWidget);
    expect(find.text('Dates'), findsNothing);
    expect(tester.takeException(), isNull);
    await h.dispose();
  });
}
