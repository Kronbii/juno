import 'package:drift/drift.dart';
import 'package:juno/core/db/database.dart';
import 'package:uuid/uuid.dart';

/// Seeded rows get name-derived ids, so two devices that both seed on first
/// launch converge on the same rows when they sync instead of duplicating.
String seedId(String key) => const Uuid().v5(Namespace.url.value, 'juno:seed:$key');

/// Seeded rows carry this timestamp instead of "now": any real edit made on
/// any device is newer and wins, and two devices' identical seeds tie
/// harmlessly. (Stamped "now", a phone installed later would overwrite your
/// renamed accounts and edited rates with defaults.)
final seedStamp = DateTime.utc(2000);

/// Rates for currencies Juno knows out of the box. Editable in Settings.
Future<void> seedRates(AppDatabase db) => db.batch((b) {
  b.insertAll(db.currencyRates, [
    CurrencyRatesCompanion.insert(
      id: Value(seedId('fx:LBP')),
      code: 'LBP',
      perUsd: 89500,
      createdAt: Value(seedStamp),
      updatedAt: Value(seedStamp),
    ),
    CurrencyRatesCompanion.insert(
      id: Value(seedId('fx:EUR')),
      code: 'EUR',
      perUsd: 0.86,
      createdAt: Value(seedStamp),
      updatedAt: Value(seedStamp),
    ),
  ], mode: InsertMode.insertOrIgnore);
});

/// Starter accounts and categories so the app is useful on first open.
Future<void> seedDefaults(AppDatabase db) async {
  await seedRates(db);
  await db.batch((b) {
    b
      ..insertAll(db.accounts, [
        AccountsCompanion.insert(
          id: Value(seedId('acct:checking')),
          createdAt: Value(seedStamp),
          updatedAt: Value(seedStamp),
          name: 'Checking',
          kind: AccountKind.checking,
          sort: const Value(0),
        ),
        AccountsCompanion.insert(
          id: Value(seedId('acct:cash')),
          createdAt: Value(seedStamp),
          updatedAt: Value(seedStamp),
          name: 'Cash',
          kind: AccountKind.cash,
          sort: const Value(1),
        ),
        AccountsCompanion.insert(
          id: Value(seedId('acct:savings')),
          createdAt: Value(seedStamp),
          updatedAt: Value(seedStamp),
          name: 'Savings',
          kind: AccountKind.savings,
          sort: const Value(2),
        ),
      ])
      ..insertAll(db.categories, [
        for (final (i, c) in starterCategories.indexed)
          CategoriesCompanion.insert(
            id: Value(c.id),
            createdAt: Value(seedStamp),
            updatedAt: Value(seedStamp),
            name: c.name,
            icon: c.icon,
            colorIndex: c.color,
            kind: c.kind,
            scope: Value(c.scope),
            sort: Value(i),
          ),
      ]);
  });
}

/// A category Juno starts with. [key] names its id, so every device seeds
/// the same rows and converges on sync; it stays fixed when [name] changes.
class StarterCategory {
  const StarterCategory(
    this.key,
    this.name,
    this.icon,
    this.color, {
    required this.scope,
    this.kind = CategoryKind.expense,
  });

  final String key;
  final String name;
  final String icon;
  final int color;
  final Scope scope;
  final CategoryKind kind;

  String get id => seedId('cat:$key');
}

/// Spending categories per scope, then income (which has no scope). Order
/// is the starting sort order.
const starterCategories = [
  StarterCategory('Transportation', 'Transportation', 'car', 2, scope: Scope.personal),
  StarterCategory('Dates', 'Dates', 'heart', 4, scope: Scope.personal),
  StarterCategory('Food & Outings', 'Food & Outings', 'dining', 1, scope: Scope.personal),
  StarterCategory('Subscriptions', 'Subscriptions', 'repeat', 7, scope: Scope.personal),
  StarterCategory('Clothes & Accessories', 'Clothes & Accessories', 'bag', 0, scope: Scope.personal),
  StarterCategory('Learning & Tech', 'Learning & Tech', 'laptop', 6, scope: Scope.personal),
  StarterCategory('Personal Care', 'Personal Care', 'beauty', 5, scope: Scope.personal),
  StarterCategory('Rent', 'Rent', 'home', 6, scope: Scope.household),
  StarterCategory('Electricity', 'Electricity', 'bolt', 3, scope: Scope.household),
  StarterCategory('Utilities', 'Utilities', 'water', 0, scope: Scope.household),
  StarterCategory('Groceries', 'Groceries', 'cart', 2, scope: Scope.household),
  StarterCategory('household:Subscriptions', 'Subscriptions', 'repeat', 7, scope: Scope.household),
  StarterCategory('Internet', 'Internet', 'wifi', 5, scope: Scope.household),
  StarterCategory('Other', 'Other', 'dots', 6, scope: Scope.other),
  StarterCategory('Salary', 'Salary', 'briefcase', 5, scope: Scope.personal, kind: CategoryKind.income),
  StarterCategory('Freelance', 'Freelance', 'laptop', 2, scope: Scope.personal, kind: CategoryKind.income),
  StarterCategory('Refunds', 'Refunds', 'undo', 0, scope: Scope.personal, kind: CategoryKind.income),
  StarterCategory('Other income', 'Other income', 'plus', 3, scope: Scope.personal, kind: CategoryKind.income),
];
