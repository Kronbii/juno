import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';

class TxTotals {
  const TxTotals({required this.count, required this.income, required this.expense, required this.expenseByDay});

  static const empty = TxTotals(count: 0, income: 0, expense: 0, expenseByDay: {});

  final int count;
  final int income;
  final int expense;
  final Map<String, int> expenseByDay;
}

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

  DateTime get _now => clock.now().toUtc();

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

  /// The filter half of a query, shared by row lists and aggregates so the
  /// totals above a list always describe exactly the rows it can show.
  Expression<bool> _filter($TransactionsTable t, TxQuery f) {
    final parts = <Expression<bool>>[t.deletedAt.isNull()];
    if (f.from != null) parts.add(t.occurredOn.isBiggerOrEqualValue(f.from!));
    if (f.to != null) parts.add(t.occurredOn.isSmallerOrEqualValue(f.to!));
    if (f.scope != null) parts.add(t.scope.equalsValue(f.scope));
    if (f.type != null) parts.add(t.type.equalsValue(f.type));
    if (f.categoryIds != null && f.categoryIds!.isNotEmpty) parts.add(t.categoryId.isIn(f.categoryIds!));
    if (f.accountId != null) parts.add(t.accountId.equals(f.accountId!) | t.toAccountId.equals(f.accountId!));
    final s = f.search?.trim().toLowerCase();
    if (s != null && s.isNotEmpty) {
      // instr, not LIKE: "50%" or "a_b" must match literally.
      Expression<bool> has(Expression<String> col) =>
          FunctionCallExpression<int>('instr', [col.lower(), Variable(s)]).isBiggerThanValue(0);
      parts.add(has(t.note) | has(t.merchant));
    }
    if (f.tag != null && f.tag!.isNotEmpty) parts.add(t.tags.like('%,${f.tag},%'));
    return parts.reduce((a, b) => a & b);
  }

  SimpleSelectStatement<$TransactionsTable, Transaction> _txSelect(TxQuery f) {
    final q = db.select(db.transactions)
      ..where((t) => _filter(t, f))
      ..orderBy([
        (t) => OrderingTerm.desc(t.occurredOn),
        (t) => OrderingTerm.desc(t.createdAt),
      ]);
    if (f.limit != null) q.limit(f.limit!);
    return q;
  }

  /// Totals over *every* row matching [f] (its limit ignored): entry count,
  /// USD in/out, and money out per day — for headers above a paged list.
  Stream<TxTotals> watchTotals(TxQuery f) {
    final t = db.transactions;
    final usd = coalesce([t.baseCents, t.amountCents]);
    final sum = usd.sum();
    final n = t.id.count();
    final q = db.selectOnly(t)
      ..addColumns([t.occurredOn, t.type, sum, n])
      ..where(_filter(t, f))
      ..groupBy([t.occurredOn, t.type]);
    return q.watch().map((rows) {
      var count = 0;
      var inc = 0;
      var out = 0;
      final perDay = <String, int>{};
      for (final r in rows) {
        final c = r.read(n) ?? 0;
        final v = r.read(sum) ?? 0;
        count += c;
        final type = t.type.converter.fromSql(r.read(t.type));
        if (type == TxType.income) inc += v;
        if (type == TxType.expense) {
          out += v;
          final d = r.read(t.occurredOn)!;
          perDay[d] = (perDay[d] ?? 0) + v;
        }
      }
      return TxTotals(count: count, income: inc, expense: out, expenseByDay: perDay);
    });
  }

  Stream<List<Transaction>> watchTransactions(TxQuery f) => _txSelect(f).watch();

  Future<List<Transaction>> transactions(TxQuery f) => _txSelect(f).get();

  Stream<Transaction?> watchTransaction(String id) =>
      (db.select(db.transactions)..where((t) => t.id.equals(id))).watchSingleOrNull();

  /// Balance per account id: opening + income − expense ± transfers.
  /// Balance per account id as of [asOf] (default today): entries dated
  /// later don't count yet. The date is passed in rather than read by SQLite,
  /// so it follows the app's clock and its timezone.
  Stream<Map<String, int>> watchBalances({String? asOf}) {
    final day = asOf ?? Day.today();
    const sql = '''
      SELECT a.id AS id,
        a.opening_balance_cents
        + COALESCE((SELECT SUM(CASE t.type WHEN 'income' THEN t.amount_cents
                                          WHEN 'expense' THEN -t.amount_cents
                                          ELSE -t.amount_cents END)
                    FROM transactions t
                    WHERE t.account_id = a.id AND t.deleted_at IS NULL
                      AND t.occurred_on <= ?1), 0)
        + COALESCE((SELECT SUM(COALESCE(t.to_amount_cents, t.amount_cents)) FROM transactions t
                    WHERE t.to_account_id = a.id AND t.type = 'transfer'
                      AND t.deleted_at IS NULL AND t.occurred_on <= ?1), 0) AS balance
      FROM accounts a WHERE a.deleted_at IS NULL
    ''';
    return db
        .customSelect(sql, variables: [Variable.withString(day)], readsFrom: {db.accounts, db.transactions})
        .watch()
        .map((rows) => {for (final r in rows) r.read<String>('id'): r.read<int>('balance')});
  }

  /// Category ids ordered by how often they were used in the last 90 days —
  /// the add sheet puts these first.
  Future<List<String>> recentCategoryIds() async {
    final since = Day.of(Day.shift(clock.now(), -90));
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

  /// Keeps the row as it was before an edit/delete (see EntryHistory).
  Future<void> _remember(Transaction before, String action) => db
      .into(db.entryHistory)
      .insert(
        EntryHistoryCompanion.insert(
          transactionId: before.id,
          snapshot: jsonEncode(before.toJson()),
          action: action,
          at: clock.now().toUtc(),
        ),
      );

  Stream<List<EntryHistoryData>> watchHistory(String transactionId) =>
      (db.select(db.entryHistory)
            ..where((h) => h.transactionId.equals(transactionId))
            ..orderBy([(h) => OrderingTerm.desc(h.at)]))
          .watch();

  /// Puts an entry back to a saved version (itself recorded, so a restore
  /// can be undone too).
  Future<void> restoreVersion(EntryHistoryData h) async {
    final old = Transaction.fromJson(jsonDecode(h.snapshot) as Map<String, dynamic>);
    await updateTransaction(
      old.id,
      old
          .toCompanion(true)
          .copyWith(deletedAt: const Value(null), updatedAt: const Value.absent(), dirty: const Value.absent()),
    );
  }

  Future<void> updateTransaction(String id, TransactionsCompanion patch) async {
    var p = patch;
    // Re-price only when the money or the accounts actually changed — the
    // entry sheet sends every field back, and re-pricing an untouched LBP
    // entry at today's rate would silently rewrite past USD totals.
    final cur = await (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();
    await _remember(cur, patch.deletedAt.present && patch.deletedAt.value != null ? 'delete' : 'edit');
    bool changed<T>(Value<T> v, T now) => v.present && v.value != now;
    if (changed(patch.amountCents, cur.amountCents) ||
        changed(patch.accountId, cur.accountId) ||
        changed(patch.toAccountId, cur.toAccountId)) {
      p = await price(
        db,
        patch.copyWith(
          amountCents: patch.amountCents.present ? patch.amountCents : Value(cur.amountCents),
          accountId: patch.accountId.present ? patch.accountId : Value(cur.accountId),
          toAccountId: patch.toAccountId.present ? patch.toAccountId : Value(cur.toAccountId),
        ),
      );
    } else {
      // Keep the stored pricing exactly as logged.
      p = patch.copyWith(
        currency: const Value.absent(),
        baseCents: const Value.absent(),
        toAmountCents: const Value.absent(),
      );
    }
    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      p.copyWith(updatedAt: Value(_now), dirty: const Value(true)),
    );
    _wrote();
  }

  /// Splits one entry into parts (category, scope, amount in the entry's own
  /// currency) that must add up to the original. The first part keeps the
  /// original row; all parts share a split group. USD values are divided in
  /// proportion — at the rate the entry was logged with, not today's — and
  /// the last part takes the rounding so the totals stay exact.
  Future<List<String>> splitTransaction(String id, List<(String? categoryId, Scope scope, int cents)> parts) async {
    final t = await (db.select(db.transactions)..where((x) => x.id.equals(id))).getSingle();
    if (t.type == TxType.transfer) throw ArgumentError('Transfers cannot be split');
    if (parts.length < 2) throw ArgumentError('A split needs at least two parts');
    if (parts.any((p) => p.$3 <= 0)) throw ArgumentError('Every part needs an amount');
    final sum = parts.fold(0, (a, p) => a + p.$3);
    if (sum != t.amountCents) throw ArgumentError('Parts add up to $sum, not ${t.amountCents}');

    final group = t.splitGroup ?? newId();
    final base = t.baseCents;
    var baseLeft = base ?? 0;
    final ids = <String>[];
    await db.transaction(() async {
      for (var i = 0; i < parts.length; i++) {
        final (cat, scope, cents) = parts[i];
        final last = i == parts.length - 1;
        final partBase = base == null ? null : (last ? baseLeft : (base * cents / t.amountCents).round());
        if (partBase != null) baseLeft -= partBase;
        final fields = TransactionsCompanion(
          categoryId: Value(cat),
          scope: Value(scope),
          amountCents: Value(cents),
          currency: Value(t.currency),
          baseCents: Value(partBase),
          splitGroup: Value(group),
        );
        if (i == 0) {
          await _remember(t, 'edit');
          await (db.update(db.transactions)..where((x) => x.id.equals(id))).write(
            fields.copyWith(updatedAt: Value(_now), dirty: const Value(true)),
          );
          ids.add(id);
        } else {
          final nid = newId();
          await db
              .into(db.transactions)
              .insert(
                fields.copyWith(
                  id: Value(nid),
                  type: Value(t.type),
                  accountId: Value(t.accountId),
                  occurredOn: Value(t.occurredOn),
                  note: Value(t.note),
                  merchant: Value(t.merchant),
                  tags: Value(t.tags),
                ),
              );
          ids.add(nid);
        }
      }
    });
    _wrote();
    return ids;
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

  /// Moves an account's opening balance by [deltaCents], reading the row
  /// fresh inside one transaction and touching nothing else, so a rename or
  /// balance change that synced in meanwhile is kept, not overwritten.
  Future<void> adjustOpeningBalance(String accountId, int deltaCents) async {
    if (deltaCents == 0) return;
    await db.transaction(() async {
      final a = await (db.select(db.accounts)..where((x) => x.id.equals(accountId))).getSingle();
      await (db.update(db.accounts)..where((x) => x.id.equals(accountId))).write(
        AccountsCompanion(
          openingBalanceCents: Value(a.openingBalanceCents + deltaCents),
          updatedAt: Value(_now),
          dirty: const Value(true),
        ),
      );
    });
    _wrote();
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

  /// Local knowledge that this device's copy of the file is in the cloud.
  /// Not a synced edit: bumping the row would undo a deletion made on
  /// another device. Other devices find files by trying to download them.
  Future<void> markUploaded(String id) async {
    await (db.update(db.attachments)..where((a) => a.id.equals(id))).write(
      const AttachmentsCompanion(uploaded: Value(true)),
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

  /// Local changes not yet pushed, across every synced table.
  Future<int> unsyncedCount() async {
    var n = 0;
    for (final t in const [
      'accounts',
      'categories',
      'transactions',
      'budgets',
      'goals',
      'goal_contributions',
      'recurring_rules',
      'import_batches',
      'currency_rates',
      'attachments',
    ]) {
      // Seeded defaults are dirty until first sync but hold nothing of yours.
      final r = await db
          .customSelect("SELECT COUNT(*) AS n FROM $t WHERE dirty = 1 AND created_at > '2000-01-02'")
          .getSingle();
      n += r.read<int>('n');
    }
    return n;
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
