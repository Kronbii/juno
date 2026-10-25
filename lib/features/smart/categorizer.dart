import 'package:drift/drift.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/features/smart/entry_parser.dart';

/// Where a category guess came from, cheapest first.
enum GuessSource { history, keywords, ai }

class CategoryGuess {
  const CategoryGuess(this.category, this.source, {this.sure = true});

  final Category category;
  final GuessSource source;

  /// False when the AI said it was guessing.
  final bool sure;
}

/// Picks a category for an entry from its note, spending as little as
/// possible: the same note filed before (free, and it follows your
/// corrections), then the on-device keyword parser (free), and only then
/// the AI, given [scope]'s categories and your own
/// past entries that share words with the note. Null when nothing fits or
/// the AI is off or unreachable; [timeout] bounds the wait.
Future<CategoryGuess?> guessCategory(
  AppDatabase db, {
  required String note,
  required Scope scope,
  required TxType type,
  required int amountCents,
  required String currency,
  required List<Category> categories,
  AiAssist? ai,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final text = note.trim();
  if (text.isEmpty) return null;
  final kind = type == TxType.income ? CategoryKind.income : CategoryKind.expense;
  // Spending is filed within its scope: a household entry never lands in
  // a personal category, and two scopes' "Subscriptions" never collide.
  final pool = [
    for (final c in categories)
      if (c.kind == kind && !c.archived && c.deletedAt == null && (kind == CategoryKind.income || c.scope == scope)) c,
  ];
  if (pool.isEmpty) return null;
  final byId = {for (final c in pool) c.id: c};

  final memory = await Ledger(db).merchantCategoryMemory();
  final remembered = byId[memory[text.toLowerCase()]];
  if (remembered != null) return CategoryGuess(remembered, GuessSource.history);

  final parsed = parseEntry(text, categories: pool, memory: memory);
  final keyword = byId[parsed.categoryId];
  if (keyword != null) return CategoryGuess(keyword, GuessSource.keywords);

  if (ai == null || !ai.enabled) return null;
  final byName = {for (final c in pool) c.name: c};
  final examples = await pastExamples(db, text, byId: byId);
  final r = await ai
      .pickCategory(
        note: text,
        amount: Fx.format(amountCents, currency),
        scope: scope.label,
        categories: byName.keys.toList(),
        examples: examples,
      )
      .timeout(timeout, onTimeout: () => null);
  final picked = r == null ? null : byName[r.category];
  return picked == null ? null : CategoryGuess(picked, GuessSource.ai, sure: r!.sure);
}

/// Your past (note, category) pairs, at most [limit]: those sharing a word
/// with [note] first — the ones that teach the AI your names for things —
/// then the most recent. One row per distinct note, in its latest category.
Future<List<(String, String)>> pastExamples(
  AppDatabase db,
  String note, {
  required Map<String, Category> byId,
  int limit = 24,
}) async {
  final rows = await db
      .customSelect(
        '''
SELECT LOWER(TRIM(note)) AS k, note, category_id, MAX(updated_at) AS at
FROM transactions
WHERE deleted_at IS NULL AND category_id IS NOT NULL AND TRIM(note) <> ''
GROUP BY LOWER(TRIM(note))
ORDER BY at DESC
LIMIT 400''',
        readsFrom: {db.transactions},
      )
      .get();
  final words = _words(note);
  final related = <(String, String)>[];
  final recent = <(String, String)>[];
  for (final r in rows) {
    final c = byId[r.read<String>('category_id')];
    if (c == null) continue;
    final n = r.read<String>('note').trim();
    // Long notes teach little and cost tokens.
    final pair = (n.length > 60 ? n.substring(0, 60) : n, c.name);
    (_words(n).any(words.contains) ? related : recent).add(pair);
  }
  return [...related.take(limit), ...recent].take(limit).toList();
}

Set<String> _words(String s) => {
  for (final w in s.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
    if (w.length >= 3) w,
};

/// Files quick entries that were saved without a category because the AI
/// couldn't be reached at the time (offline, or the app went to the
/// background first). At most [max] entries from the last two weeks per run.
Future<int> fileUncategorisedQuickEntries(
  AppDatabase db, {
  required Ledger ledger,
  AiAssist? ai,
  int max = 10,
}) async {
  final since = Day.of(DateTime.now().subtract(const Duration(days: 14)));
  final pending =
      await (db.select(db.transactions)
            ..where(
              (t) =>
                  t.deletedAt.isNull() &
                  t.categoryId.isNull() &
                  t.type.isIn([TxType.expense.name, TxType.income.name]) &
                  t.occurredOn.isBiggerOrEqualValue(since) &
                  t.tags.like('%,quick,%') &
                  t.note.trim().length.isBiggerThanValue(0),
            )
            ..limit(max * 3))
          .get();
  if (pending.isEmpty) return 0;
  final categories = await (db.select(db.categories)..where((c) => c.deletedAt.isNull())).get();
  final accounts = {for (final a in await db.select(db.accounts).get()) a.id: a};
  var filed = 0;
  var attempts = 0;
  for (final t in pending) {
    // Two tries each: an entry nothing can place must not cost an AI call
    // on every launch.
    final triedKey = 'quick.filing.tries.${t.id}';
    final tries = int.tryParse(await db.meta(triedKey) ?? '') ?? 0;
    if (tries >= 2) continue;
    if (attempts++ >= max) break;
    final g = await guessCategory(
      db,
      note: t.note,
      scope: t.scope,
      type: t.type,
      amountCents: t.amountCents,
      currency: accounts[t.accountId]?.currency ?? 'USD',
      categories: categories,
      ai: ai,
    );
    if (g == null) {
      await db.setMeta(triedKey, '${tries + 1}');
      continue;
    }
    await ledger.updateTransaction(t.id, TransactionsCompanion(categoryId: Value(g.category.id)));
    filed++;
  }
  return filed;
}
