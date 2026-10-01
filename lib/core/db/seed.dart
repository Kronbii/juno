import 'package:drift/drift.dart';
import 'package:juno/core/db/database.dart';
import 'package:uuid/uuid.dart';

/// Seeded rows get name-derived ids, so two devices that both seed on first
/// launch converge on the same rows when they sync instead of duplicating.
String seedId(String key) => const Uuid().v5(Namespace.url.value, 'juno:seed:$key');

/// Rates for currencies Juno knows out of the box. Editable in Settings.
Future<void> seedRates(AppDatabase db) => db.batch((b) {
  b.insertAll(db.currencyRates, [
    CurrencyRatesCompanion.insert(id: Value(seedId('fx:LBP')), code: 'LBP', perUsd: 89500),
    CurrencyRatesCompanion.insert(id: Value(seedId('fx:EUR')), code: 'EUR', perUsd: 0.86),
  ], mode: InsertMode.insertOrIgnore);
});

/// Starter accounts and categories so the app is useful on first open.
Future<void> seedDefaults(AppDatabase db) async {
  await seedRates(db);
  await db.batch((b) {
    b.insertAll(db.accounts, [
      AccountsCompanion.insert(
        id: Value(seedId('acct:checking')),
        name: 'Checking',
        kind: AccountKind.checking,
        sort: const Value(0),
      ),
      AccountsCompanion.insert(
        id: Value(seedId('acct:cash')),
        name: 'Cash',
        kind: AccountKind.cash,
        sort: const Value(1),
      ),
      AccountsCompanion.insert(
        id: Value(seedId('acct:savings')),
        name: 'Savings',
        kind: AccountKind.savings,
        sort: const Value(2),
      ),
    ]);

    var i = 0;
    CategoriesCompanion cat(
      String name,
      String icon,
      int color, {
      CategoryKind kind = CategoryKind.expense,
      Scope scope = Scope.personal,
    }) => CategoriesCompanion.insert(
      id: Value(seedId('cat:$name')),
      name: name,
      icon: icon,
      colorIndex: color,
      kind: kind,
      defaultScope: Value(scope),
      sort: Value(i++),
    );

    b.insertAll(db.categories, [
      cat('Groceries', 'cart', 0, scope: Scope.household),
      cat('Dining', 'dining', 1),
      cat('Coffee', 'coffee', 4),
      cat('Transport', 'car', 2),
      cat('Fuel', 'fuel', 3),
      cat('Rent', 'home', 6, scope: Scope.household),
      cat('Utilities', 'bolt', 3, scope: Scope.household),
      cat('Internet & phone', 'wifi', 5, scope: Scope.household),
      cat('Subscriptions', 'repeat', 7),
      cat('Shopping', 'bag', 4),
      cat('Health', 'health', 2),
      cat('Fitness', 'fitness', 5),
      cat('Entertainment', 'ticket', 7),
      cat('Travel', 'plane', 0),
      cat('Gifts', 'gift', 4),
      cat('Household supplies', 'spray', 2, scope: Scope.household),
      cat('Education', 'book', 6),
      cat('Other', 'dots', 6),
      cat('Salary', 'briefcase', 5, kind: CategoryKind.income),
      cat('Freelance', 'laptop', 2, kind: CategoryKind.income),
      cat('Refunds', 'undo', 0, kind: CategoryKind.income),
      cat('Other income', 'plus', 3, kind: CategoryKind.income),
    ]);
  });
}
