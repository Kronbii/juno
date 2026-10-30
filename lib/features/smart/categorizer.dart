import 'package:drift/drift.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/features/smart/entry_parser.dart';

/// Where a category guess came from.
enum GuessSource { history, keywords, ai }

class CategoryGuess {
  const CategoryGuess(this.category, this.source, {this.sure = true});

  final Category category;
  final GuessSource source;

  /// False when the AI said it was guessing.
  final bool sure;

  /// Worth a second look: picked by keywords, or by an AI that was guessing.
  bool get provisional => source == GuessSource.keywords || (source == GuessSource.ai && !sure);
}

/// Picks a category for an entry from its note. Your history first: the
/// same note filed before is free and follows your corrections. Then the
/// AI, given your categories, the ones usual for [scope] and your past
/// entries that share words with the note. The on-device keywords only when
/// the AI is off, can't be reached or can't place it — a guess [markGuess]
/// leaves for the AI to check later. Null when nothing fits; [timeout]
/// bounds the wait.
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
  final local = await guessOnDevice(db, note: note, scope: scope, type: type, categories: categories);
  if (local?.source == GuessSource.history || ai == null || !ai.enabled) return local;
  final asked = await askAi(
    db,
    note: note,
    scope: scope,
    type: type,
    amountCents: amountCents,
    currency: currency,
    categories: categories,
    ai: ai,
    timeout: timeout,
  );
  return asked?.guess ?? local;
}

/// The categories an entry of [type] may go to.
List<Category> _pool(List<Category> categories, TxType type) {
  final kind = type == TxType.income ? CategoryKind.income : CategoryKind.expense;
  return [
    for (final c in categories)
      if (c.kind == kind && !c.archived && c.deletedAt == null) c,
  ];
}

/// From this device alone, free and offline: the same note filed before,
/// else the keyword parser. Null when neither can say.
Future<CategoryGuess?> guessOnDevice(
  AppDatabase db, {
  required String note,
  required Scope scope,
  required TxType type,
  required List<Category> categories,
}) async {
  final text = note.trim();
  final pool = _pool(categories, type);
  if (text.isEmpty || pool.isEmpty) return null;
  final byId = {for (final c in pool) c.id: c};
  final memory = await Ledger(db).merchantCategoryMemory();
  final remembered = byId[memory[text.toLowerCase()]];
  if (remembered != null) return CategoryGuess(remembered, GuessSource.history);
  final keyword = byId[parseEntry(text, categories: pool, memory: memory).categoryId];
  return keyword == null ? null : CategoryGuess(keyword, GuessSource.keywords);
}

/// The AI's pick for [note]. Null when no answer came back (off, capped,
/// offline, timed out); a null guess when it answered but nothing fit.
Future<({CategoryGuess? guess})?> askAi(
  AppDatabase db, {
  required String note,
  required Scope scope,
  required TxType type,
  required int amountCents,
  required String currency,
  required List<Category> categories,
  required AiAssist ai,
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (!ai.enabled) return null;
  final text = note.trim();
  final pool = _pool(categories, type);
  if (text.isEmpty || pool.isEmpty) return (guess: null);
  final byName = {for (final c in pool) c.name: c};
  final r = await ai
      .pickCategory(
        note: text,
        amount: Fx.format(amountCents, currency),
        scope: scope.label,
        categories: byName.keys.toList(),
        usual: [
          for (final c in pool)
            if (c.defaultScope == scope) c.name,
        ],
        examples: await pastExamples(db, text, byId: {for (final c in pool) c.id: c}),
      )
      .timeout(timeout, onTimeout: () => null);
  if (r == null) return null;
  final picked = byName[r.category];
  return (guess: picked == null ? null : CategoryGuess(picked, GuessSource.ai, sure: r.sure));
}

/// Leaves [id]'s category for a second look when [g] was a guess — by
/// keywords (the AI checks it once it can) or by an unsure AI (shown with a
/// "?") — and clears any earlier one otherwise.
Future<void> markGuess(Ledger ledger, String id, CategoryGuess? g) =>
    g != null && g.provisional ? ledger.markFiling(id, byAi: g.source == GuessSource.ai) : ledger.clearFiling(id);

/// Your past (note, category) pairs, at most [limit]: those sharing a word
/// with [note] first — the ones that teach the AI your names for things —
/// then the most recent. One row per distinct note, in its latest category.
/// Guesses still awaiting a second look aren't yours yet, so they're left out.
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
WHERE deleted_at IS NULL AND category_id IS NOT NULL AND TRIM(note) <> '' AND ${Ledger.notAwaitingFiling}
GROUP BY LOWER(TRIM(note))
ORDER BY at DESC
LIMIT 400''',
        readsFrom: {db.transactions, db.localMeta},
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

/// Files quick entries (Back Tap, Siri, Shortcuts, widgets) whose category
/// nobody chose; run on open and resume.
///
/// First on the device, so nothing waits on the network: each one saved
/// without a category is filed now from your history or keywords. Then,
/// while the AI answers, it takes a second look at the keyword guesses and
/// at whatever is still uncategorised, at most [max] calls a run. Its pick
/// replaces the keyword's; when it says it's guessing, the entry shows a "?"
/// until you edit it. An entry changed since it was filed is left alone.
/// An answer that places nothing costs that entry one of its two tries; no
/// answer at all (offline, capped) ends the run and costs none. With no AI
/// set up, keyword guesses are final. Entries from the last two weeks;
/// older keyword guesses stand. [timeout] bounds each AI call. Returns how
/// many entries changed category.
Future<int> fileQuickEntries(
  AppDatabase db, {
  required Ledger ledger,
  AiAssist? ai,
  int max = 10,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final since = Day.of(DateTime.now().subtract(const Duration(days: 14)));
  Future<List<Transaction>> uncategorised() =>
      (db.select(db.transactions)
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
  final categories = await (db.select(db.categories)..where((c) => c.deletedAt.isNull())).get();
  final accounts = {for (final a in await db.select(db.accounts).get()) a.id: a};
  var changed = 0;

  Future<void> file(Transaction t, CategoryGuess g) async {
    if (g.category.id != t.categoryId) {
      await ledger.updateTransaction(t.id, TransactionsCompanion(categoryId: Value(g.category.id)));
      changed++;
    }
    await markGuess(ledger, t.id, g);
  }

  Future<CategoryGuess?> onDevice(Transaction t) =>
      guessOnDevice(db, note: t.note, scope: t.scope, type: t.type, categories: categories);

  for (final t in await uncategorised()) {
    final g = await onDevice(t);
    if (g != null) await file(t, g);
  }

  final checking = ai != null && ai.enabled;
  final marks = await ledger.filings();
  final marked = marks.isEmpty
      ? const <Transaction>[]
      : await (db.select(db.transactions)..where((t) => t.id.isIn(marks.keys))).get();
  final byId = {for (final t in marked) t.id: t};
  final toCheck = <Transaction>[];
  for (final MapEntry(key: id, value: f) in marks.entries) {
    final t = byId[id];
    if (t == null || !f.holds(t) || (!f.byAi && (!checking || t.occurredOn.compareTo(since) < 0))) {
      // Gone or changed since (yours now); or a keyword guess with no AI to
      // check it, or too old to revisit, which stands.
      await ledger.clearFiling(id);
    } else if (!f.byAi) {
      toCheck.add(t);
    }
  }
  if (ai == null || !ai.enabled) return changed;
  toCheck.addAll(await uncategorised());

  var calls = 0;
  for (final t in toCheck) {
    final triedKey = 'quick.filing.tries.${t.id}';
    final tries = int.tryParse(await db.meta(triedKey) ?? '') ?? 0;
    if (tries >= 2) continue;
    // Filed the same way by you since: no need to ask.
    final local = await onDevice(t);
    if (local?.source == GuessSource.history) {
      await file(t, local!);
      continue;
    }
    if (calls++ >= max) break;
    final asked = await askAi(
      db,
      note: t.note,
      scope: t.scope,
      type: t.type,
      amountCents: t.amountCents,
      currency: accounts[t.accountId]?.currency ?? 'USD',
      categories: categories,
      ai: ai,
      timeout: timeout,
    );
    if (asked == null) break;
    final g = asked.guess;
    if (g == null) {
      await db.setMeta(triedKey, '${tries + 1}');
      continue;
    }
    await file(t, g);
  }
  return changed;
}
