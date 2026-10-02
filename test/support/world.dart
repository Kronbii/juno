// A random ledger built through the real write path, for reconciliation
// tests: LBP and card accounts, entries of every type over eight months,
// edits that re-price, deletes, restores, and budgets of every shape.
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';

class World {
  World(this.db, this.ledger, this.accounts);

  final AppDatabase db;
  final Ledger ledger;
  final List<Account> accounts;
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
    final day = Day.of(DateTime(today.year, today.month, today.day - (rnd.nextInt(240))));
    final r = rnd.nextDouble();
    final type = r < 0.75
        ? TxType.expense
        : r < 0.9
        ? TxType.income
        : TxType.transfer;
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
                    )]
                    .id,
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
    BudgetsCompanion.insert(
      categoryId: Value(expenseCats.first.id),
      scope: const Value(Scope.personal),
      limitCents: 20000,
    ),
  );
  return World(db, ledger, await db.select(db.accounts).get());
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

/// The seeds a randomised test runs: [defaults], plus `JUNO_SEEDS` more
/// when that's set (`JUNO_SEEDS=40 flutter test …` for a deep run).
List<int> seeds(List<int> defaults) {
  final extra = int.tryParse(Platform.environment['JUNO_SEEDS'] ?? '') ?? 0;
  return [...defaults, for (var i = 0; i < extra; i++) 10000 + i * 7919];
}
