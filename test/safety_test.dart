import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/backups.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';

TransactionsCompanion entry(String note, int cents) => TransactionsCompanion.insert(
  type: TxType.expense,
  scope: Scope.personal,
  amountCents: cents,
  accountId: seedId('acct:checking'),
  occurredOn: Day.today(),
  note: Value(note),
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('juno-backup'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('snapshot then restore brings back deleted data and keeps newer edits', () async {
    // A file-backed DB (VACUUM INTO works on any connection).
    final db = AppDatabase.memory(NativeDatabase(File('${dir.path}/live.sqlite')));
    final l = Ledger(db);
    final keep = await l.addTransaction(entry('rent', 145000));
    final lost = await l.addTransaction(entry('groceries', 5400));
    final backups = Backups(db, dir: Directory('${dir.path}/b')..createSync());
    final snap = await backups.snapshot();
    expect(snap.existsSync(), isTrue);

    // After the backup: one entry deleted by mistake, another edited.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await (db.delete(db.transactions)..where((t) => t.id.equals(lost))).go(); // hard loss
    await l.updateTransaction(keep, const TransactionsCompanion(note: Value('rent october')));

    final restored = await backups.restore(snap);
    expect(restored, greaterThanOrEqualTo(1));
    final rows = {for (final t in await l.transactions(const TxQuery())) t.id: t};
    expect(rows[lost]?.note, 'groceries', reason: 'lost entry restored');
    expect(rows[lost]?.dirty, isTrue, reason: 'restored rows sync again');
    expect(rows[keep]?.note, 'rent october', reason: 'newer edit not overwritten');
    expect(snap.existsSync(), isTrue, reason: 'backup file untouched');
    await db.close();
  });

  test('daily: no second snapshot within the window; keeps the newest 14', () async {
    final db = AppDatabase.memory(NativeDatabase(File('${dir.path}/live2.sqlite')));
    final backups = Backups(db, dir: Directory('${dir.path}/b2')..createSync());
    expect(await backups.snapshotIfDue(), isNotNull);
    expect(await backups.snapshotIfDue(), isNull);
    for (var i = 0; i < 16; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await backups.snapshot();
    }
    expect((await backups.list()).length, lessThanOrEqualTo(Backups.keep));
    await db.close();
  });

  test('edit history records every change and restores a version', () async {
    final db = AppDatabase.memory(NativeDatabase.memory());
    final l = Ledger(db);
    final id = await l.addTransaction(entry('coffee', 450));
    await l.updateTransaction(id, const TransactionsCompanion(amountCents: Value(500)));
    await l.updateTransaction(id, const TransactionsCompanion(note: Value('flat white')));
    await l.deleteTransaction(id);
    final history = await l.watchHistory(id).first;
    expect(history.map((h) => h.action), ['delete', 'edit', 'edit']);
    // Roll back to the very first version (before the amount change).
    await l.restoreVersion(history.last);
    final t = (await l.transactions(const TxQuery())).single;
    expect(t.amountCents, 450);
    expect(t.note, 'coffee');
    expect(t.deletedAt, isNull);
    await db.close();
  });
}
