import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/db/tables.dart';

export 'package:juno/core/db/tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Accounts,
    Categories,
    Transactions,
    Budgets,
    Goals,
    GoalContributions,
    RecurringRules,
    ImportBatches,
    CurrencyRates,
    Attachments,
    LocalMeta,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  /// An in-memory database for tests.
  AppDatabase.memory(super.e);

  static QueryExecutor _open() => driftDatabase(
    name: const String.fromEnvironment('JUNO_DB', defaultValue: 'juno'),
  );

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await seedDefaults(this);
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(transactions, transactions.currency);
        await m.addColumn(transactions, transactions.baseCents);
        await m.addColumn(transactions, transactions.toAmountCents);
        await m.addColumn(transactions, transactions.tags);
        await m.createTable(currencyRates);
        await m.createTable(attachments);
        await seedRates(this);
      }
      if (from < 3) {
        // The (recurring_id, occurred_on) unique index could make a moved
        // occurrence fail to merge during sync; ids are deterministic now.
        await customStatement('DROP INDEX IF EXISTS tx_recurring_day');
        await customStatement('CREATE INDEX IF NOT EXISTS tx_recurring ON transactions (recurring_id)');
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Reads a local-only value.
  Future<String?> meta(String key) async =>
      (await (select(localMeta)..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setMeta(String key, String value) =>
      into(localMeta).insertOnConflictUpdate(LocalMetaData(key: key, value: value));
}
