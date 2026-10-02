import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/housekeeping.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('edit history: a year back and at most 20 versions an entry; flags of past days and months go', () async {
    final db = AppDatabase.memory(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime.utc(2026, 10, 2, 12);
    await db.batch(
      (b) => b.insertAll(db.entryHistory, [
        for (var i = 0; i < 30; i++)
          EntryHistoryCompanion.insert(
            transactionId: 'busy',
            snapshot: '{}',
            action: 'edit',
            at: now.subtract(Duration(days: i)),
          ),
        EntryHistoryCompanion.insert(transactionId: 'old', snapshot: '{}', action: 'edit', at: DateTime.utc(2025, 9)),
        EntryHistoryCompanion.insert(
          transactionId: 'recent',
          snapshot: '{}',
          action: 'edit',
          at: DateTime.utc(2026, 8),
        ),
      ]),
    );
    SharedPreferences.setMockInitialValues({
      'notified.bill.3f2a9c1e-1234-5678-9abc-def012345678.2026-07-01': true, // > 60 days
      'notified.bill.3f2a9c1e-1234-5678-9abc-def012345678.2026-09-20': true,
      'notified.budget.3f2a9c1e-1234-5678-9abc-def012345678.2026-08.near': true, // before last month
      'notified.budget.3f2a9c1e-1234-5678-9abc-def012345678.2026-09.over': true,
      'ai.spent.2025-09': 100,
      'ai.spent.2026-01': 100,
      'ai.used.2025-08': 3,
      'themeMode': 'dark',
    });
    final prefs = await SharedPreferences.getInstance();
    await Housekeeping.run(db, prefs, now: now);

    final left = await db.select(db.entryHistory).get();
    expect(left.where((h) => h.transactionId == 'busy').length, 20);
    expect(
      left.where((h) => h.transactionId == 'busy').map((h) => h.at).reduce((a, b) => a.isBefore(b) ? a : b),
      now.subtract(const Duration(days: 19)),
      reason: 'the newest 20 kept',
    );
    expect(left.map((h) => h.transactionId).toSet(), {'busy', 'recent'});
    expect(prefs.getKeys(), {
      'notified.bill.3f2a9c1e-1234-5678-9abc-def012345678.2026-09-20',
      'notified.budget.3f2a9c1e-1234-5678-9abc-def012345678.2026-09.over',
      'ai.spent.2026-01',
      'themeMode',
    });
  });

  test('runs at most once a day', () async {
    final db = AppDatabase.memory(NativeDatabase.memory());
    addTearDown(db.close);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await Housekeeping.runIfDue(db, prefs, now: DateTime(2026, 10, 2, 9));
    await prefs.setBool('notified.bill.x.2026-01-01', true);
    await Housekeeping.runIfDue(db, prefs, now: DateTime(2026, 10, 2, 18));
    expect(prefs.getBool('notified.bill.x.2026-01-01'), isTrue, reason: 'already tidied today');
    await Housekeeping.runIfDue(db, prefs, now: DateTime(2026, 10, 3, 9));
    expect(prefs.getBool('notified.bill.x.2026-01-01'), isNull);
  });
}
