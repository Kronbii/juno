import 'package:drift/drift.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart' show seedStamp;
import 'package:juno/core/money.dart';
import 'package:uuid/uuid.dart';

/// The occurrence after [from] for a rule anchored at [anchor].
///
/// Monthly and yearly rules keep the anchor's day-of-month, clamped to short
/// months — a rule anchored on the 31st lands on 28/29 Feb and returns to the
/// 31st in March rather than drifting to the 28th forever.
DateTime nextOccurrence({
  required DateTime anchor,
  required DateTime from,
  required Frequency frequency,
  int interval = 1,
}) {
  switch (frequency) {
    case Frequency.weekly:
      // Calendar arithmetic, not Duration: adding 7×24h across a DST change
      // lands on 23:00 the day before and the rule drifts a weekday.
      return DateTime(from.year, from.month, from.day + 7 * interval);
    case Frequency.monthly:
      return _monthAt(anchor, from.year, from.month + interval);
    case Frequency.yearly:
      return _monthAt(anchor, from.year + interval, anchor.month);
  }
}

DateTime _monthAt(DateTime anchor, int year, int month) {
  final first = DateTime(year, month);
  final last = DateTime(first.year, first.month + 1, 0).day;
  return DateTime(first.year, first.month, anchor.day.clamp(1, last));
}

/// Every due date of [rule] up to and including [today], starting at its
/// `nextDue`, plus the next due date after them.
(List<String> due, String next) dueDates(RecurringRule rule, DateTime today) {
  final anchor = Day.parse(rule.anchorDate);
  final end = rule.endDate == null ? null : Day.parse(rule.endDate!);
  var cursor = Day.parse(rule.nextDue);
  final due = <String>[];
  // Guard against a corrupt rule spinning forever.
  for (var i = 0; i < 1000; i++) {
    if (cursor.isAfter(today)) break;
    if (end != null && cursor.isAfter(end)) break;
    due.add(Day.of(cursor));
    cursor = nextOccurrence(anchor: anchor, from: cursor, frequency: rule.frequency, interval: rule.interval);
  }
  return (due, Day.of(cursor));
}

/// Occurrence ids derive from (rule, day), so two devices that both post the
/// same due date produce the same row and sync merges them instead of
/// duplicating it.
String occurrenceId(String ruleId, String day) => const Uuid().v5(Namespace.url.value, 'juno:occurrence:$ruleId:$day');

/// Turns every due occurrence of every active rule into a transaction.
///
/// Idempotent: occurrence ids derive from (rule, day), so a second run — or a
/// second device — finds the row and inserts nothing; an occurrence the user
/// deleted stays deleted.
Future<int> materializeRecurring(AppDatabase db, {DateTime? now}) async {
  final today = now ?? DateTime.now();
  final rules = await (db.select(db.recurringRules)..where((r) => r.deletedAt.isNull() & r.active.equals(true))).get();
  var created = 0;
  await db.transaction(() async {
    for (final rule in rules) {
      final (due, next) = dueDates(rule, today);
      if (due.isEmpty) continue;
      for (final day in due) {
        final id = occurrenceId(rule.id, day);
        // By id, and including soft-deleted rows: an occurrence that exists
        // anywhere — edited, moved to another date, or deleted — is never
        // posted again.
        final exists = await (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (exists != null) continue;
        final row = await Ledger.price(
          db,
          TransactionsCompanion.insert(
            id: Value(id),
            type: rule.type,
            scope: rule.scope,
            amountCents: rule.amountCents,
            accountId: rule.accountId,
            categoryId: Value(rule.categoryId),
            occurredOn: day,
            note: Value(rule.note),
            recurringId: Value(rule.id),
            // An automatic posting is not an edit: stamped old, so a copy the
            // user already changed or deleted on another device always wins.
            createdAt: Value(seedStamp),
            updatedAt: Value(seedStamp),
          ),
        );
        await db.into(db.transactions).insert(row, mode: InsertMode.insertOrIgnore);
        created++;
      }
      // nextDue is local bookkeeping, recomputable on every device. Writing it
      // as a synced edit would let a stale device overwrite the rule's real
      // changes (amount, deletion) made elsewhere.
      await (db.update(db.recurringRules)..where((r) => r.id.equals(rule.id))).write(
        RecurringRulesCompanion(nextDue: Value(next)),
      );
    }
  });
  return created;
}
