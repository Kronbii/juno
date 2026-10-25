import 'package:drift/drift.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';

// Categories used to only *suggest* a scope, so a personal entry could sit in
// Rent. Now each category belongs to one scope and every expense in it has
// that scope (see `Categories.scope`). This file moves an existing ledger to
// the new shape once, and keeps entries from older app versions in line
// after every sync.
//
// Every write here is stamped one millisecond after the version it replaces,
// never "now": two devices restructuring the same rows write identical
// values with identical stamps (a harmless tie), and any real edit made since
// on any device is newer and wins.

/// Old category names (lowercased) and the starter category each one joins.
const _joins = <String, String>{
  'outings': 'Food & Outings',
  'dining': 'Food & Outings',
  'coffee': 'Food & Outings',
  'entertainment': 'Food & Outings',
  'food & outings': 'Food & Outings',
  'transport': 'Transportation',
  'fuel': 'Transportation',
  'motorcycle': 'Transportation',
  'transportation': 'Transportation',
  'shopping': 'Clothes & Accessories',
  'clothes & accessories': 'Clothes & Accessories',
  'education': 'Learning & Tech',
  'learning & tech': 'Learning & Tech',
  'health': 'Personal Care',
  'fitness': 'Personal Care',
  'personal care': 'Personal Care',
  'dates': 'Dates',
  'subscriptions': 'Subscriptions',
  'rent': 'Rent',
  'electricity': 'Electricity',
  'utilities': 'Utilities',
  'groceries': 'Groceries',
  'household supplies': 'Groceries',
  'internet & phone': 'Internet',
  'internet': 'Internet',
  'other': 'Other',
  'other personal': 'Other',
  'gifts': 'Other',
  'travel': 'Other',
};

/// Entries filed by hand when the categories were restructured (Oct 2026):
/// entry id → starter key. The entry takes that category's scope.
const _filedByHand = <String, String>{
  '01a1540d-7471-712f-9cfd-ecb34802d92b': 'Electricity', // Utilities $200
  '01a1540d-bc40-7c7f-b150-34acc3d60e69': 'Groceries', // baba
  '01a15411-9c30-71ea-b304-bd78b6b43ff3': 'Food & Outings', // Jnoub outing
  '01a15411-eae4-7547-90af-3a5db9bdf9d9': 'Personal Care', // haircut
  '01a15414-b6a7-7074-917f-ac5d3db17f70': 'Transportation', // moto maintenance
  '01a15414-f2f9-7ef3-811b-98e350739179': 'Learning & Tech', // drone standoffs
  '01a159bd-7e7e-72ff-b031-526905bc4120': 'Food & Outings', // food at work
  '01a159d6-fd53-73b9-a427-717febfc7c73': 'Other', // a wedding gift
  '47242e1d-6032-43a4-8ac8-5afe4b5a4d44': 'Other', // sunglasses for a sister
};

/// Only categories made before scoped categories shipped are folded into the
/// starters by name: one you create afterwards called "Shopping" is yours.
final _shippedOn = DateTime.utc(2026, 10, 22);

const restructuredKey = 'categories.scoped';

DateTime _after(DateTime prev) => prev.toUtc().add(const Duration(milliseconds: 1));

/// Moves this device's ledger to scoped categories, once. Starter categories
/// are created (or, for the old seeded rows they reuse, moved to their
/// scope); old categories are folded into the starter they became, entries
/// and recurring bills with them; entries whose category no longer matches
/// their scope keep their scope and move category (see [conformCategories]).
/// No amount and, except for [_filedByHand], no entry's scope changes, so
/// every scope's totals are exactly what they were.
Future<void> restructureCategories(AppDatabase db) async {
  if (await db.meta(restructuredKey) != null) return;
  await db.transaction(() async {
    final starters = {for (final s in starterCategories) s.key: s};
    final rows = {for (final c in await db.select(db.categories).get()) c.id: c};

    // 1. Starters exist, each in its scope. A deleted one stays deleted.
    for (final s in starterCategories.where((s) => s.kind == CategoryKind.expense)) {
      final row = rows[s.id];
      if (row == null) {
        await db
            .into(db.categories)
            .insert(
              CategoriesCompanion.insert(
                id: Value(s.id),
                createdAt: Value(seedStamp),
                updatedAt: Value(seedStamp),
                name: s.name,
                icon: s.icon,
                colorIndex: s.color,
                kind: s.kind,
                scope: Value(s.scope),
                sort: Value(starterCategories.indexOf(s)),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      } else if (row.deletedAt == null && (row.scope != s.scope || row.kind != s.kind)) {
        // An old seeded row this starter reuses (old "Other" was personal).
        await (db.update(db.categories)..where((c) => c.id.equals(s.id))).write(
          CategoriesCompanion(
            name: Value(s.name),
            kind: Value(s.kind),
            scope: Value(s.scope),
            archived: const Value(false),
            updatedAt: Value(_after(row.updatedAt)),
            dirty: const Value(true),
          ),
        );
      }
    }

    // 2. Old categories fold into the starter they became.
    final starterIds = {for (final s in starterCategories) s.id};
    for (final c in rows.values) {
      final key = _joins[c.name.trim().toLowerCase()];
      if (key == null ||
          c.kind != CategoryKind.expense ||
          c.deletedAt != null ||
          starterIds.contains(c.id) ||
          !c.createdAt.isBefore(_shippedOn)) {
        continue;
      }
      final into = starters[key]!;
      await _moveRows(db, c.id, into.id);
      await _moveBudgets(db, c.id, into);
      final at = _after(c.updatedAt);
      await (db.update(db.categories)..where((x) => x.id.equals(c.id))).write(
        CategoriesCompanion(deletedAt: Value(at), updatedAt: Value(at), dirty: const Value(true)),
      );
      // Entries an older app version logs here later follow on after sync.
      await db.setMeta('category.merged.${c.id}', into.id);
    }

    // 3. Entries filed by hand take their category and its scope.
    for (final e in _filedByHand.entries) {
      final into = starters[e.value]!;
      final t = await (db.select(db.transactions)..where((t) => t.id.equals(e.key))).getSingleOrNull();
      if (t == null || (t.categoryId == into.id && t.scope == into.scope)) continue;
      await (db.update(db.transactions)..where((x) => x.id.equals(t.id))).write(
        TransactionsCompanion(
          categoryId: Value(into.id),
          scope: Value(into.scope),
          updatedAt: Value(_after(t.updatedAt)),
          dirty: const Value(true),
        ),
      );
    }

    await conformCategories(db);
    await db.setMeta(restructuredKey, '1');
  });
}

/// Puts every expense and recurring bill in a category of its own scope.
/// Older app versions treated a category's scope as a hint, so they can
/// still log a personal entry in Rent. The entry's scope was the choice
/// made, so it stays, and the entry moves to the category of the same name
/// in that scope if there is one, otherwise to the scope's catch-all
/// (household → Groceries, other → Other) or, for personal, no category.
/// Runs after every sync; returns how many rows moved.
Future<int> conformCategories(AppDatabase db) async {
  final cats = await (db.select(db.categories)..where((c) => c.deletedAt.isNull())).get();
  final byId = {for (final c in cats) c.id: c};
  final spending = cats.where((c) => c.kind == CategoryKind.expense).toList();

  String? home(String? categoryId, Scope scope) {
    final c = byId[categoryId];
    if (c == null || c.kind != CategoryKind.expense || c.scope == scope) return categoryId;
    final named = c.name.trim().toLowerCase();
    Category? find(String name) =>
        spending.where((k) => k.scope == scope && !k.archived && k.name.trim().toLowerCase() == name).firstOrNull;
    return (find(named) ??
            switch (scope) {
              Scope.household => find('groceries'),
              Scope.other => find('other'),
              Scope.personal => null,
            })
        ?.id;
  }

  var moved = 0;
  final txs = await (db.select(
    db.transactions,
  )..where((t) => t.type.equalsValue(TxType.expense) & t.categoryId.isNotNull())).get();
  for (final t in txs) {
    final to = home(t.categoryId, t.scope);
    if (to == t.categoryId) continue;
    await (db.update(db.transactions)..where((x) => x.id.equals(t.id))).write(
      TransactionsCompanion(categoryId: Value(to), updatedAt: Value(_after(t.updatedAt)), dirty: const Value(true)),
    );
    moved++;
  }
  final rules = await (db.select(
    db.recurringRules,
  )..where((r) => r.type.equalsValue(TxType.expense) & r.categoryId.isNotNull())).get();
  for (final r in rules) {
    final to = home(r.categoryId, r.scope);
    if (to == r.categoryId) continue;
    await (db.update(db.recurringRules)..where((x) => x.id.equals(r.id))).write(
      RecurringRulesCompanion(categoryId: Value(to), updatedAt: Value(_after(r.updatedAt)), dirty: const Value(true)),
    );
    moved++;
  }
  // A category budget is for that category's scope.
  final budgets = await (db.select(db.budgets)..where((b) => b.deletedAt.isNull() & b.categoryId.isNotNull())).get();
  for (final b in budgets) {
    final c = byId[b.categoryId];
    if (c == null || c.kind != CategoryKind.expense || b.scope == c.scope) continue;
    await (db.update(db.budgets)..where((x) => x.id.equals(b.id))).write(
      BudgetsCompanion(scope: Value(c.scope), updatedAt: Value(_after(b.updatedAt)), dirty: const Value(true)),
    );
    moved++;
  }
  return moved;
}

Future<void> _moveRows(AppDatabase db, String from, String to) async {
  for (final t in await (db.select(db.transactions)..where((t) => t.categoryId.equals(from))).get()) {
    await (db.update(db.transactions)..where((x) => x.id.equals(t.id))).write(
      TransactionsCompanion(categoryId: Value(to), updatedAt: Value(_after(t.updatedAt)), dirty: const Value(true)),
    );
  }
  for (final r in await (db.select(db.recurringRules)..where((r) => r.categoryId.equals(from))).get()) {
    await (db.update(db.recurringRules)..where((x) => x.id.equals(r.id))).write(
      RecurringRulesCompanion(categoryId: Value(to), updatedAt: Value(_after(r.updatedAt)), dirty: const Value(true)),
    );
  }
}

/// A folded category's budget joins the starter's budget, or becomes it.
Future<void> _moveBudgets(AppDatabase db, String from, StarterCategory into) async {
  final live = await (db.select(db.budgets)..where((b) => b.deletedAt.isNull())).get();
  for (final b in live.where((b) => b.categoryId == from)) {
    final twin = (await (db.select(
      db.budgets,
    )..where((t) => t.deletedAt.isNull() & t.categoryId.equals(into.id))).get()).firstOrNull;
    if (twin != null) {
      await (db.update(db.budgets)..where((t) => t.id.equals(twin.id))).write(
        BudgetsCompanion(
          limitCents: Value(twin.limitCents + b.limitCents),
          updatedAt: Value(_after(twin.updatedAt)),
          dirty: const Value(true),
        ),
      );
      final at = _after(b.updatedAt);
      await (db.update(db.budgets)..where((t) => t.id.equals(b.id))).write(
        BudgetsCompanion(deletedAt: Value(at), updatedAt: Value(at), dirty: const Value(true)),
      );
    } else {
      await (db.update(db.budgets)..where((t) => t.id.equals(b.id))).write(
        BudgetsCompanion(
          categoryId: Value(into.id),
          scope: Value(into.scope),
          updatedAt: Value(_after(b.updatedAt)),
          dirty: const Value(true),
        ),
      );
    }
  }
}
