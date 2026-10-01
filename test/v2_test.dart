import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/deeplink/quick_add.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/import/csv_import.dart';
import 'package:juno/features/insights/analytics.dart';

void main() {
  test('FX formatting and conversion', () {
    final rates = {'LBP': 89500.0, 'EUR': 0.86};
    expect(Fx.format(150000000, 'LBP'), 'LBP 1,500,000');
    expect(Fx.format(1250, 'EUR'), '€12.50');
    expect(Fx.toUsd(895000000, 'LBP', rates), 10000);
    expect(Fx.convert(10000, 'USD', 'LBP', rates), 895000000);
    expect(Fx.baseFor(500, 'USD', rates), isNull);
  });

  test('tags normalise, store and parse', () {
    expect(EntryTags.store(['#Trip Istanbul', 'gift', 'Gift', ' ']), ',trip-istanbul,gift,');
    expect(EntryTags.parse(',trip-istanbul,gift,'), ['trip-istanbul', 'gift']);
    expect(EntryTags.store([]), '');
    expect(EntryTags.fromInput('trip, #Work stuff,'), ['trip', 'work-stuff']);
  });

  test('ledger prices LBP entries and cross-currency transfers', () async {
    final db = AppDatabase.memory(NativeDatabase.memory());
    final ledger = Ledger(db);
    final lbp = await ledger.upsertAccount(
      AccountsCompanion.insert(name: 'Cash LBP', kind: AccountKind.cash, currency: const Value('LBP')),
    );
    final id = await ledger.addTransaction(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.personal,
        amountCents: 895000000,
        accountId: lbp,
        occurredOn: Day.today(),
        tags: Value(EntryTags.store(['taxi'])),
      ),
    );
    final t = (await ledger.transactions(const TxQuery())).single;
    expect(t.id, id);
    expect(t.currency, 'LBP');
    expect(t.usd, 10000);
    expect((await ledger.transactions(const TxQuery(tag: 'taxi'))).single.id, id);
    expect(await ledger.transactions(const TxQuery(tag: 'tax')), isEmpty);

    // $50 from Checking arrives as LBP 4,475,000 in cash.
    await ledger.addTransaction(
      TransactionsCompanion.insert(
        type: TxType.transfer,
        scope: Scope.personal,
        amountCents: 5000,
        accountId: seedId('acct:checking'),
        toAccountId: Value(lbp),
        occurredOn: Day.today(),
      ),
    );
    final balances = await ledger.watchBalances().first;
    expect(balances[lbp], -895000000 + 447500000);

    // Editing the amount re-prices the USD value.
    await ledger.updateTransaction(id, const TransactionsCompanion(amountCents: Value(179000000)));
    final edited = (await ledger.transactions(const TxQuery(type: TxType.expense))).single;
    expect(edited.usd, 2000);
    await db.close();
  });

  test('net worth series rebuilds monthly balances in USD', () {
    Account acct(String id, int opening, String cur) => Account(
      id: id,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      dirty: false,
      name: id,
      kind: AccountKind.cash,
      openingBalanceCents: opening,
      currency: cur,
      archived: false,
      sort: 0,
    );
    Transaction tx(String day, int cents, TxType type) => Transaction(
      id: newId(),
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      dirty: false,
      type: type,
      scope: Scope.personal,
      amountCents: cents,
      accountId: 'usd',
      occurredOn: day,
      note: '',
      merchant: '',
      currency: 'USD',
      tags: '',
    );
    final series = netWorthSeries(
      accounts: [acct('usd', 100000, 'USD'), acct('lbp', 895000000, 'LBP')],
      txs: [tx('2026-08-10', 50000, TxType.income), tx('2026-09-03', 20000, TxType.expense)],
      perUsd: {'LBP': 89500},
      last: DateTime(2026, 9),
      months: 3,
    );
    expect(series.map((p) => p.$2), [110000, 160000, 140000]);
  });

  test('quick add carries currency and tags', () {
    final q = QuickAdd.parse(Uri.parse('juno://add?amount=500000&currency=lbp&tags=taxi,work'))!;
    expect(q.currency, 'LBP');
    expect(q.tags, ['taxi', 'work']);
  });

  test('Notion-style export with a category column and long dates', () {
    const csv =
        'Name,Amount,Category,Date\nGroceries run,\$54.20,Grocery,"October 1, 2026"\nTaxi,\$6,transport,"September 30, 2026"\n';
    final t = CsvTable.parse(csv);
    final m = ColumnMapping.guess(t);
    expect(m.category, 2);
    expect(m.dateFormat, 'MMMM d, yyyy');
    Category cat(String name) => Category(
      id: seedId('cat:$name'),
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
    final rows = buildRows(
      table: t,
      mapping: m.copyWith(mode: AmountMode.signedPositiveOut),
      existingHashes: {},
      memory: {},
      categories: [cat('Groceries'), cat('Transport')],
    );
    expect(rows.map((r) => r.categoryId), [seedId('cat:Groceries'), seedId('cat:Transport')]);
    expect(rows.first.day, '2026-10-01');
    expect(rows.first.cents, -5420);
  });

  test('v1 database upgrades to v2 in place', () async {
    // Build a v1-shaped file by creating v2 then dropping the v2 additions
    // and resetting user_version — then reopen and let onUpgrade run.
    final file = NativeDatabase.memory(
      setup: (raw) {
        raw
          ..execute('''
          CREATE TABLE transactions (id TEXT NOT NULL PRIMARY KEY, user_id TEXT, created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL, deleted_at TEXT, dirty INTEGER NOT NULL DEFAULT 1, type TEXT NOT NULL,
            scope TEXT NOT NULL, amount_cents INTEGER NOT NULL, account_id TEXT NOT NULL, to_account_id TEXT,
            category_id TEXT, occurred_on TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', merchant TEXT NOT NULL DEFAULT '',
            recurring_id TEXT, import_batch_id TEXT, dedupe_hash TEXT);
        ''')
          ..execute(
            'INSERT INTO transactions (id, created_at, updated_at, type, scope, amount_cents, account_id, occurred_on) '
            "VALUES ('t1', '2026-09-01T00:00:00.000Z', '2026-09-01T00:00:00.000Z', 'expense', 'personal', 1200, 'a', '2026-09-01')",
          )
          ..execute('PRAGMA user_version = 1');
      },
    );
    final db = AppDatabase.memory(file);
    final t = await db.select(db.transactions).getSingle();
    expect(t.currency, 'USD');
    expect(t.usd, 1200);
    expect(t.tags, '');
    expect((await db.select(db.currencyRates).get()).map((r) => r.code), containsAll(['LBP', 'EUR']));
    await db.close();
  });
}
