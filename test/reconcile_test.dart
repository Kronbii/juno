// Reconciliation: build random ledgers through the real write path, then
// recompute every dashboard figure independently from raw SQL and compare.
// The oracle below shares no code with the app's analytics.
import 'dart:math';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/insights/analytics.dart';

class World {
  World(this.db, this.ledger, this.accounts, this.categories);

  final AppDatabase db;
  final Ledger ledger;
  final List<Account> accounts;
  final List<Category> categories;
}

Future<World> buildWorld(int seed, {int entries = 400}) async {
  final rnd = Random(seed);
  final db = AppDatabase.memory(NativeDatabase.memory());
  final ledger = Ledger(db);
  await ledger.setRate('LBP', 89500);
  await ledger.upsertAccount(
    AccountsCompanion.insert(
      name: 'Cash LBP',
      kind: AccountKind.cash,
      currency: const Value('LBP'),
      openingBalanceCents: Value(rnd.nextInt(5000000) * 100),
    ),
  );
  await ledger.upsertAccount(
    AccountsCompanion.insert(name: 'Card', kind: AccountKind.credit, openingBalanceCents: Value(-rnd.nextInt(90000))),
  );
  await (db.update(db.accounts)..where((a) => a.id.equals(seedId('acct:checking')))).write(
    AccountsCompanion(openingBalanceCents: Value(rnd.nextInt(800000))),
  );
  final accounts = await db.select(db.accounts).get();
  final categories = await db.select(db.categories).get();
  final expenseCats = categories.where((c) => c.kind == CategoryKind.expense).toList();
  final incomeCats = categories.where((c) => c.kind == CategoryKind.income).toList();

  final today = DateTime.now();
  final ids = <String>[];
  for (var i = 0; i < entries; i++) {
    final day = Day.of(today.subtract(Duration(days: rnd.nextInt(240))));
    final r = rnd.nextDouble();
    final type = r < 0.75 ? TxType.expense : r < 0.9 ? TxType.income : TxType.transfer;
    final acct = accounts[rnd.nextInt(accounts.length)];
    final lbp = acct.currency == 'LBP';
    final cents = lbp ? (rnd.nextInt(400) + 1) * 5000000 : rnd.nextInt(60000) + 1;
    Account? to;
    if (type == TxType.transfer) {
      final others = accounts.where((a) => a.id != acct.id).toList();
      to = others[rnd.nextInt(others.length)];
    }
    final id = await ledger.addTransaction(
      TransactionsCompanion.insert(
        type: type,
        scope: rnd.nextBool() ? Scope.personal : Scope.household,
        amountCents: cents,
        accountId: acct.id,
        toAccountId: Value(to?.id),
        categoryId: Value(
          type == TxType.transfer
              ? null
              : rnd.nextDouble() < 0.05
              ? null // uncategorised
              : (type == TxType.income ? incomeCats : expenseCats)[rnd.nextInt(
                  (type == TxType.income ? incomeCats : expenseCats).length,
                )].id,
        ),
        occurredOn: day,
        note: Value(['Spinneys', 'Taxi', 'Rent', '', 'Netflix'][rnd.nextInt(5)]),
        tags: Value(rnd.nextDouble() < 0.2 ? EntryTags.store(['trip', if (rnd.nextBool()) 'gift']) : ''),
      ),
    );
    ids.add(id);
  }
  // Edits (amount, account and type changes re-price), deletes, restores.
  for (var i = 0; i < 80; i++) {
    final id = ids[rnd.nextInt(ids.length)];
    switch (rnd.nextInt(4)) {
      case 0:
        await ledger.updateTransaction(id, TransactionsCompanion(amountCents: Value(rnd.nextInt(90000) + 1)));
      case 1:
        final t = (await ledger.transactions(const TxQuery())).where((t) => t.id == id).firstOrNull;
        if (t != null && t.type != TxType.transfer) {
          final a = accounts[rnd.nextInt(accounts.length)];
          await ledger.updateTransaction(id, TransactionsCompanion(accountId: Value(a.id)));
        }
      case 2:
        await ledger.deleteTransaction(id);
      case 3:
        await ledger.restoreTransaction(id);
    }
  }
  // Budgets of every shape.
  await ledger.upsertBudget(BudgetsCompanion.insert(limitCents: 150000));
  await ledger.upsertBudget(BudgetsCompanion.insert(scope: const Value(Scope.household), limitCents: 90000));
  await ledger.upsertBudget(
    BudgetsCompanion.insert(categoryId: Value(expenseCats.first.id), scope: const Value(Scope.personal), limitCents: 20000),
  );
  return World(db, ledger, await db.select(db.accounts).get(), categories);
}

/// Oracle: USD value of a live row, straight from columns.
const _usd = 'COALESCE(base_cents, amount_cents)';

Future<int> sqlSum(AppDatabase db, String where, [List<Object> args = const []]) async {
  final r = await db
      .customSelect(
        'SELECT COALESCE(SUM($_usd), 0) AS s FROM transactions WHERE deleted_at IS NULL AND $where',
        variables: [for (final a in args) Variable(a)],
      )
      .getSingle();
  return r.read<int>('s');
}

void main() {
  for (final seed in [1, 2, 3, 42, 777]) {
    test('dashboard figures reconcile with raw SQL (seed $seed)', () async {
      final w = await buildWorld(seed);
      final now = DateTime.now();
      for (var back = 0; back < 8; back++) {
        final m = DateTime(now.year, now.month - back);
        final from = Day.firstOfMonth(m);
        final to = Day.lastOfMonth(m);
        for (final scope in [null, Scope.personal, Scope.household]) {
          final txs = await w.ledger.transactions(TxQuery(from: from, to: to, scope: scope));
          final s = PeriodSummary.of(txs);
          final scopeSql = scope == null ? '1=1' : "scope = '${scope.name}'";
          final range = "occurred_on BETWEEN '$from' AND '$to' AND $scopeSql";
          expect(s.expense, await sqlSum(w.db, "type = 'expense' AND $range"), reason: 'expense $from $scope');
          expect(s.income, await sqlSum(w.db, "type = 'income' AND $range"), reason: 'income $from $scope');
          // Internal consistency: parts add up to the whole.
          expect(s.byScope.values.fold(0, (a, b) => a + b), s.expense);
          expect(s.byCategory.values.fold(0, (a, b) => a + b), s.expense);
          for (final e in s.byCategory.entries) {
            final where = e.key == null ? 'category_id IS NULL' : "category_id = '${e.key}'";
            expect(e.value, await sqlSum(w.db, "type = 'expense' AND $range AND $where"), reason: 'cat ${e.key}');
          }
          // Transfers never count.
          expect(txs.where((t) => t.type == TxType.transfer).every((t) => !s.byCategory.containsKey(t.categoryId) || t.categoryId == null), isTrue);
        }
        // Budgets against SQL.
        final monthTx = await w.ledger.transactions(TxQuery(from: from, to: to));
        final budgets = await w.ledger.watchBudgets().first;
        for (final st in budgetStatuses(budgets, monthTx)) {
          final b = st.budget;
          final where = [
            "type = 'expense'",
            "occurred_on BETWEEN '$from' AND '$to'",
            if (b.categoryId != null) "category_id = '${b.categoryId}'",
            if (b.scope != null) "scope = '${b.scope!.name}'",
          ].join(' AND ');
          expect(st.spent, await sqlSum(w.db, where), reason: 'budget ${b.id} $from');
        }
      }

      // Balances: replay every live row by hand, in each account's currency.
      final live = await (w.db.select(w.db.transactions)..where((t) => t.deletedAt.isNull())).get();
      final expected = {for (final a in w.accounts) a.id: a.openingBalanceCents};
      for (final t in live) {
        switch (t.type) {
          case TxType.income:
            expected[t.accountId] = expected[t.accountId]! + t.amountCents;
          case TxType.expense:
            expected[t.accountId] = expected[t.accountId]! - t.amountCents;
          case TxType.transfer:
            expected[t.accountId] = expected[t.accountId]! - t.amountCents;
            expected[t.toAccountId!] = expected[t.toAccountId!]! + (t.toAmountCents ?? t.amountCents);
        }
      }
      final balances = await w.ledger.watchBalances().first;
      for (final a in w.accounts) {
        expect(balances[a.id], expected[a.id], reason: 'balance ${a.name}');
      }

      // Net worth: this month's point equals today's balances at today's
      // rates (entries dated in the future excluded by construction).
      final rates = await w.ledger.rates();
      final series = netWorthSeries(
        accounts: w.accounts,
        txs: live,
        perUsd: rates,
        last: DateTime(now.year, now.month),
      );
      final nowWorth = w.accounts.fold(0, (s, a) => s + Fx.toUsd(balances[a.id]!, a.currency, rates));
      expect(series.last.$2, nowWorth);

      // Every stored USD value matches its own rate at the time (LBP) or is
      // the amount itself (USD).
      for (final t in live) {
        if (t.currency == 'USD') {
          expect(t.baseCents, isNull, reason: 'USD row with base ${t.id}');
        } else {
          expect(t.baseCents, (t.amountCents / 89500).round(), reason: 'LBP row ${t.id}');
        }
        final acct = w.accounts.firstWhere((a) => a.id == t.accountId);
        expect(t.currency, acct.currency, reason: 'currency follows account ${t.id}');
        if (t.type == TxType.transfer) {
          final dest = w.accounts.firstWhere((a) => a.id == t.toAccountId);
          if (dest.currency == acct.currency) {
            expect(t.toAmountCents, isNull);
          } else {
            expect(t.toAmountCents, Fx.convert(t.amountCents, acct.currency, dest.currency, rates));
          }
          expect(t.categoryId, isNull, reason: 'transfers are uncategorised');
        }
      }
      await w.db.close();
    });
  }
}
