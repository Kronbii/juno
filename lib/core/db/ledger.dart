import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';

/// Filters for transaction queries. Null fields don't filter.
@immutable
class TxQuery {
  const TxQuery({
    this.from,
    this.to,
    this.scope,
    this.type,
    this.categoryIds,
    this.accountId,
    this.search,
    this.tag,
    this.limit,
  });

  /// Inclusive `YYYY-MM-DD` bounds.
  final String? from;
  final String? to;
  final Scope? scope;
  final TxType? type;
  final Set<String>? categoryIds;
  final String? accountId;
  final String? search;

  /// A single normalised tag.
  final String? tag;
  final int? limit;

  TxQuery copyWith({
    String? from,
    String? to,
    Scope? scope,
    TxType? type,
    Set<String>? categoryIds,
    String? accountId,
    String? search,
    String? tag,
    int? limit,
    bool clearScope = false,
    bool clearTag = false,
    bool clearType = false,
    bool clearCategories = false,
    bool clearAccount = false,
    bool clearRange = false,
  }) => TxQuery(
    from: clearRange ? null : from ?? this.from,
    to: clearRange ? null : to ?? this.to,
    scope: clearScope ? null : scope ?? this.scope,
    type: clearType ? null : type ?? this.type,
    categoryIds: clearCategories ? null : categoryIds ?? this.categoryIds,
    accountId: clearAccount ? null : accountId ?? this.accountId,
    search: search ?? this.search,
    tag: clearTag ? null : tag ?? this.tag,
    limit: limit ?? this.limit,
  );

  @override
  bool operator ==(Object other) =>
      other is TxQuery &&
      other.from == from &&
      other.to == to &&
      other.scope == scope &&
      other.type == type &&
      _setEq(other.categoryIds, categoryIds) &&
      other.accountId == accountId &&
      other.search == search &&
      other.tag == tag &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(
    from,
    to,
    scope,
    type,
    categoryIds == null ? null : Object.hashAllUnordered(categoryIds!),
    accountId,
    search,
    tag,
    limit,
  );

  static bool _setEq(Set<String>? a, Set<String>? b) =>
      a == null ? b == null : b != null && a.length == b.length && a.containsAll(b);
}

/// The one door into the database. Every write stamps `updatedAt` and marks
/// the row dirty so the sync engine knows to push it; deletes are soft so the
/// deletion itself can sync.
class Ledger {
  Ledger(this.db, {this.onWrite});

  final AppDatabase db;

  /// Called after any local write — the sync engine debounces a push on it.
  final void Function()? onWrite;

  DateTime get _now => DateTime.now().toUtc();

  void _wrote() => onWrite?.call();

  // ---------------------------------------------------------------- reads

  Stream<List<Account>> watchAccounts({bool includeArchived = false}) {
    final q = db.select(db.accounts)
      ..where((a) => a.deletedAt.isNull())
      ..orderBy([(a) => OrderingTerm(expression: a.sort), (a) => OrderingTerm(expression: a.name)]);
    if (!includeArchived) q.where((a) => a.archived.equals(false));
    return q.watch();
  }

  Stream<List<Category>> watchCategories({bool includeArchived = false}) {
    final q = db.select(db.categories)
      ..where((c) => c.deletedAt.isNull())
      ..orderBy([(c) => OrderingTerm(expression: c.sort), (c) => OrderingTerm(expression: c.name)]);
    if (!includeArchived) q.where((c) => c.archived.equals(false));
    return q.watch();
  }

  SimpleSelectStatement<$TransactionsTable, Transaction> _txSelect(TxQuery f) {
    final q = db.select(db.transactions)..where((t) => t.deletedAt.isNull());
    if (f.from != null) q.where((t) => t.occurredOn.isBiggerOrEqualValue(f.from!));
    if (f.to != null) q.where((t) => t.occurredOn.isSmallerOrEqualValue(f.to!));
    if (f.scope != null) q.where((t) => t.scope.equalsValue(f.scope));
    if (f.type != null) q.where((t) => t.type.equalsValue(f.type));
    if (f.categoryIds != null && f.categoryIds!.isNotEmpty) {
      q.where((t) => t.categoryId.isIn(f.categoryIds!));
    }
    if (f.accountId != null) {
      q.where((t) => t.accountId.equals(f.accountId!) | t.toAccountId.equals(f.accountId!));
    }
    final s = f.search?.trim();
    if (s != null && s.isNotEmpty) {
      final like = '%${s.replaceAll('%', r'\%')}%';
      q.where((t) => t.note.like(like) | t.merchant.like(like));
    }
    if (f.tag != null && f.tag!.isNotEmpty) q.where((t) => t.tags.like('%,${f.tag},%'));
    q.orderBy([
      (t) => OrderingTerm.desc(t.occurredOn),
      (t) => OrderingTerm.desc(t.createdAt),
    ]);
    if (f.limit != null) q.limit(f.limit!);
    return q;
  }

  Stream<List<Transaction>> watchTransactions(TxQuery f) => _txSelect(f).watch();

  Future<List<Transaction>> transactions(TxQuery f) => _txSelect(f).get();

  Stream<Transaction?> watchTransaction(String id) =>
      (db.select(db.transactions)..where((t) => t.id.equals(id))).watchSingleOrNull();

  /// Balance per account id: opening + income − expense ± transfers.
  Stream<Map<String, int>> watchBalances() {
    const sql = '''
      SELECT a.id AS id,
        a.opening_balance_cents
        + COALESCE((SELECT SUM(CASE t.type WHEN 'income' THEN t.amount_cents
                                          WHEN 'expense' THEN -t.amount_cents
                                          ELSE -t.amount_cents END)
                    FROM transactions t
                    WHERE t.account_id = a.id AND t.deleted_at IS NULL), 0)
        + COALESCE((SELECT SUM(COALESCE(t.to_amount_cents, t.amount_cents)) FROM transactions t
                    WHERE t.to_account_id = a.id AND t.type = 'transfer'
                      AND t.deleted_at IS NULL), 0) AS balance
      FROM accounts a WHERE a.deleted_at IS NULL
    ''';
    return db
        .customSelect(sql, readsFrom: {db.accounts, db.transactions})
        .watch()
        .map((rows) => {for (final r in rows) r.read<String>('id'): r.read<int>('balance')});
  }

  /// Category ids ordered by how often they were used in the last 90 days —
  /// the add sheet puts these first.
  Future<List<String>> recentCategoryIds() async {
    final since = Day.of(DateTime.now().subtract(const Duration(days: 90)));
    final rows = await db
        .customSelect(
          '''
SELECT category_id, COUNT(*) AS n FROM transactions
         WHERE deleted_at IS NULL AND category_id IS NOT NULL AND occurred_on >= ?
         GROUP BY category_id ORDER BY n DESC''',
          variables: [Variable.withString(since)],
          readsFrom: {db.transactions},
        )
        .get();
    return [for (final r in rows) r.read<String>('category_id')];
  }

  /// merchant/note (lowercased) → most recently used category. Powers CSV
  /// auto-categorisation.
  Future<Map<String, String>> merchantCategoryMemory() async {
    final rows = await db
        .customSelect(
          '''
SELECT LOWER(TRIM(CASE WHEN merchant <> '' THEN merchant ELSE note END)) AS k,
                category_id
         FROM transactions
         WHERE deleted_at IS NULL AND category_id IS NOT NULL
         ORDER BY occurred_on ASC''',
          readsFrom: {db.transactions},
        )
        .get();
    return {
      for (final r in rows)
        if (r.read<String>('k').isNotEmpty) r.read<String>('k'): r.read<String>('category_id'),
    };
  }

  Future<Set<String>> existingDedupeHashes() async {
    final rows =
        await (db.selectOnly(db.transactions)
              ..addColumns([db.transactions.dedupeHash])
              ..where(db.transactions.dedupeHash.isNotNull() & db.transactions.deletedAt.isNull()))
            .get();
    return {for (final r in rows) r.read(db.transactions.dedupeHash)!};
  }

  // --------------------------------------------------------------- writes

  Future<Map<String, double>> rates() async => {
    for (final r in await (db.select(db.currencyRates)..where((r) => r.deletedAt.isNull())).get()) r.code: r.perUsd,
  };

  /// Fills currency, USD base and (for cross-currency transfers) the
  /// received amount from the accounts involved, unless the caller set them.
  static Future<TransactionsCompanion> price(AppDatabase db, TransactionsCompanion tx) async {
    if (!tx.accountId.present || !tx.amountCents.present) return tx;
    final account = await (db.select(db.accounts)..where((a) => a.id.equals(tx.accountId.value))).getSingleOrNull();
    final currency = tx.currency.present ? tx.currency.value : account?.currency ?? baseCurrency;
    final perUsd = {
      for (final r in await (db.select(db.currencyRates)..where((r) => r.deletedAt.isNull())).get()) r.code: r.perUsd,
    };
    var out = tx.copyWith(
      currency: Value(currency),
      baseCents: tx.baseCents.present ? tx.baseCents : Value(Fx.baseFor(tx.amountCents.value, currency, perUsd)),
    );
    final toId = tx.toAccountId.present ? tx.toAccountId.value : null;
    if (toId != null && !tx.toAmountCents.present) {
      final to = await (db.select(db.accounts)..where((a) => a.id.equals(toId))).getSingleOrNull();
      final toCurrency = to?.currency ?? currency;
      out = out.copyWith(
        toAmountCents: Value(
          toCurrency == currency ? null : Fx.convert(tx.amountCents.value, currency, toCurrency, perUsd),
        ),
      );
    }
    return out;
  }

  Future<String> addTransaction(TransactionsCompanion tx) async {
    final id = tx.id.present ? tx.id.value : newId();
    await db.into(db.transactions).insert((await price(db, tx)).copyWith(id: Value(id)));
    _wrote();
    return id;
  }

  Future<void> updateTransaction(String id, TransactionsCompanion patch) async {
    var p = patch;
    // Re-price when the money or the account changed.
    if (patch.amountCents.present || patch.accountId.present) {
      final cur = await (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();
      p = await price(
        db,
        patch.copyWith(
          amountCents: patch.amountCents.present ? patch.amountCents : Value(cur.amountCents),
          accountId: patch.accountId.present ? patch.accountId : Value(cur.accountId),
          toAccountId: patch.toAccountId.present ? patch.toAccountId : Value(cur.toAccountId),
        ),
      );
    }
    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      p.copyWith(updatedAt: Value(_now), dirty: const Value(true)),
    );
    _wrote();
  }

  Future<void> deleteTransaction(String id) => updateTransaction(id, TransactionsCompanion(deletedAt: Value(_now)));

  Future<void> restoreTransaction(String id) =>
      updateTransaction(id, const TransactionsCompanion(deletedAt: Value(null)));

  Future<String> duplicateTransaction(Transaction t, {String? onDay}) => addTransaction(
    TransactionsCompanion.insert(
      type: t.type,
      scope: t.scope,
      amountCents: t.amountCents,
      accountId: t.accountId,
      toAccountId: Value(t.toAccountId),
      categoryId: Value(t.categoryId),
      occurredOn: onDay ?? Day.today(),
      note: Value(t.note),
      merchant: Value(t.merchant),
      tags: Value(t.tags),
    ),
  );

  Future<String> upsertAccount(AccountsCompanion a) async {
    final id = a.id.present ? a.id.value : newId();
    await db
        .into(db.accounts)
        .insertOnConflictUpdate(
          a.copyWith(id: Value(id), updatedAt: Value(_now), dirty: const Value(true)),
        );
    _wrote();
    return id;
  }

  Future<String> upsertCategory(CategoriesCompanion c) async {
    final id = c.id.present ? c.id.value : newId();
    await db
        .into(db.categories)
        .insertOnConflictUpdate(
          c.copyWith(id: Value(id), updatedAt: Value(_now), dirty: const Value(true)),
        );
    _wrote();
    return id;
  }

  Future<void> reorderCategories(List<String> idsInOrder) async {
    await db.transaction(() async {
      for (var i = 0; i < idsInOrder.length; i++) {
        await (db.update(db.categories)..where((c) => c.id.equals(idsInOrder[i]))).write(
          CategoriesCompanion(sort: Value(i), updatedAt: Value(_now), dirty: const Value(true)),
        );
      }
    });
    _wrote();
  }

  // -------------------------------------------------------- plan: budgets

  Stream<List<Budget>> watchBudgets() => (db.select(db.budgets)..where((b) => b.deletedAt.isNull())).watch();

  Future<String> upsertBudget(BudgetsCompanion b) async {
    final id = b.id.present ? b.id.value : newId();
    await db
        .into(db.budgets)
        .insertOnConflictUpdate(
          b.copyWith(id: Value(id), updatedAt: Value(_now), dirty: const Value(true)),
        );
    _wrote();
    return id;
  }

  Future<void> deleteBudget(String id) async {
    await (db.update(db.budgets)..where((b) => b.id.equals(id))).write(
      BudgetsCompanion(deletedAt: Value(_now), updatedAt: Value(_now), dirty: const Value(true)),
    );
    _wrote();
  }

  // ---------------------------------------------------------- plan: goals

  Stream<List<Goal>> watchGoals() =>
      (db.select(db.goals)
            ..where((g) => g.deletedAt.isNull() & g.archived.equals(false))
            ..orderBy([(g) => OrderingTerm(expression: g.createdAt)]))
          .watch();

  /// goalId → saved so far.
  Stream<Map<String, int>> watchGoalSaved() => db
      .customSelect(
        'SELECT goal_id, SUM(amount_cents) AS s FROM goal_contributions '
        'WHERE deleted_at IS NULL GROUP BY goal_id',
        readsFrom: {db.goalContributions},
      )
      .watch()
      .map((rows) => {for (final r in rows) r.read<String>('goal_id'): r.read<int>('s')});

  Stream<List<GoalContribution>> watchContributions(String goalId) =>
      (db.select(db.goalContributions)
            ..where((c) => c.goalId.equals(goalId) & c.deletedAt.isNull())
            ..orderBy([(c) => OrderingTerm.desc(c.occurredOn)]))
          .watch();

  Future<String> upsertGoal(GoalsCompanion g) async {
    final id = g.id.present ? g.id.value : newId();
    await db
        .into(db.goals)
        .insertOnConflictUpdate(
          g.copyWith(id: Value(id), updatedAt: Value(_now), dirty: const Value(true)),
        );
    _wrote();
    return id;
  }

  Future<void> deleteGoal(String id) async {
    await (db.update(db.goals)..where((g) => g.id.equals(id))).write(
      GoalsCompanion(deletedAt: Value(_now), updatedAt: Value(_now), dirty: const Value(true)),
    );
    _wrote();
  }

  Future<void> addContribution(String goalId, int cents, {String? note}) async {
    await db
        .into(db.goalContributions)
        .insert(
          GoalContributionsCompanion.insert(
            goalId: goalId,
            amountCents: cents,
            occurredOn: Day.today(),
            note: Value(note ?? ''),
          ),
        );
    _wrote();
  }

  Future<void> deleteContribution(String id) async {
    await (db.update(db.goalContributions)..where((c) => c.id.equals(id))).write(
      GoalContributionsCompanion(
        deletedAt: Value(_now),
        updatedAt: Value(_now),
        dirty: const Value(true),
      ),
    );
    _wrote();
  }

  // ------------------------------------------------------ plan: recurring

  Stream<List<RecurringRule>> watchRecurring() =>
      (db.select(db.recurringRules)
            ..where((r) => r.deletedAt.isNull())
            ..orderBy([(r) => OrderingTerm(expression: r.nextDue)]))
          .watch();

  Future<String> upsertRecurring(RecurringRulesCompanion r) async {
    final id = r.id.present ? r.id.value : newId();
    await db
        .into(db.recurringRules)
        .insertOnConflictUpdate(
          r.copyWith(id: Value(id), updatedAt: Value(_now), dirty: const Value(true)),
        );
    _wrote();
    return id;
  }

  Future<void> deleteRecurring(String id) async {
    await (db.update(db.recurringRules)..where((r) => r.id.equals(id))).write(
      RecurringRulesCompanion(deletedAt: Value(_now), updatedAt: Value(_now), dirty: const Value(true)),
    );
    _wrote();
  }

  // ------------------------------------------------------------ currency

  Stream<List<CurrencyRate>> watchRates() =>
      (db.select(db.currencyRates)
            ..where((r) => r.deletedAt.isNull())
            ..orderBy([(r) => OrderingTerm(expression: r.code)]))
          .watch();

  /// Sets the rate for [code]; the row id is the code so devices converge.
  Future<void> setRate(String code, double perUsd) async {
    await db
        .into(db.currencyRates)
        .insertOnConflictUpdate(
          CurrencyRatesCompanion.insert(
            id: Value(seedId('fx:$code')),
            code: code,
            perUsd: perUsd,
            updatedAt: Value(_now),
            dirty: const Value(true),
            deletedAt: const Value(null),
          ),
        );
    _wrote();
  }

  // ---------------------------------------------------------------- tags

  /// Every tag in use, with how many live entries carry it, most used first.
  Stream<List<(String, int)>> watchTags() => db
      .customSelect(
        "SELECT tags FROM transactions WHERE deleted_at IS NULL AND tags <> ''",
        readsFrom: {db.transactions},
      )
      .watch()
      .map((rows) {
        final counts = <String, int>{};
        for (final r in rows) {
          for (final t in r.read<String>('tags').split(',')) {
            if (t.isNotEmpty) counts[t] = (counts[t] ?? 0) + 1;
          }
        }
        return counts.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
      });

  // ---------------------------------------------------------- attachments

  Stream<List<Attachment>> watchAttachments(String transactionId) =>
      (db.select(db.attachments)
            ..where((a) => a.transactionId.equals(transactionId) & a.deletedAt.isNull())
            ..orderBy([(a) => OrderingTerm(expression: a.createdAt)]))
          .watch();

  /// transactionId → attachment count, for the paperclip on rows.
  Stream<Map<String, int>> watchAttachmentCounts() => db
      .customSelect(
        'SELECT transaction_id, COUNT(*) AS n FROM attachments WHERE deleted_at IS NULL GROUP BY transaction_id',
        readsFrom: {db.attachments},
      )
      .watch()
      .map((rows) => {for (final r in rows) r.read<String>('transaction_id'): r.read<int>('n')});

  Future<String> addAttachment(AttachmentsCompanion a) async {
    final id = a.id.present ? a.id.value : newId();
    await db.into(db.attachments).insert(a.copyWith(id: Value(id)));
    _wrote();
    return id;
  }

  Future<void> deleteAttachment(String id) async {
    await (db.update(db.attachments)..where((a) => a.id.equals(id))).write(
      AttachmentsCompanion(deletedAt: Value(_now), updatedAt: Value(_now), dirty: const Value(true)),
    );
    _wrote();
  }

  Future<List<Attachment>> attachmentsWhere({required bool uploaded}) =>
      (db.select(db.attachments)..where((a) => a.deletedAt.isNull() & a.uploaded.equals(uploaded))).get();

  Future<void> markUploaded(String id) async {
    await (db.update(db.attachments)..where((a) => a.id.equals(id))).write(
      AttachmentsCompanion(uploaded: const Value(true), updatedAt: Value(_now), dirty: const Value(true)),
    );
  }

  // ---------------------------------------------------------------- import

  Stream<List<ImportBatche>> watchImports() =>
      (db.select(db.importBatches)
            ..where((b) => b.deletedAt.isNull())
            ..orderBy([(b) => OrderingTerm.desc(b.createdAt)]))
          .watch();

  Future<String> commitImport(String filename, List<TransactionsCompanion> rows) async {
    final batchId = newId();
    await db.transaction(() async {
      await db
          .into(db.importBatches)
          .insert(
            ImportBatchesCompanion.insert(id: Value(batchId), filename: filename, rowCount: rows.length),
          );
      final priced = [for (final r in rows) await price(db, r.copyWith(importBatchId: Value(batchId)))];
      await db.batch((b) => b.insertAll(db.transactions, priced));
    });
    _wrote();
    return batchId;
  }

  /// Undoes an import: soft-deletes the batch and every row it brought in.
  Future<void> undoImport(String batchId) async {
    final now = _now;
    await db.transaction(() async {
      await (db.update(db.transactions)..where((t) => t.importBatchId.equals(batchId))).write(
        TransactionsCompanion(deletedAt: Value(now), updatedAt: Value(now), dirty: const Value(true)),
      );
      await (db.update(db.importBatches)..where((b) => b.id.equals(batchId))).write(
        ImportBatchesCompanion(deletedAt: Value(now), updatedAt: Value(now), dirty: const Value(true)),
      );
    });
    _wrote();
  }

  /// Wipes every local row (used by "Reset local data").
  Future<void> wipe() async {
    await db.transaction(() async {
      for (final t in db.allTables) {
        await db.delete(t).go();
      }
    });
  }
}
