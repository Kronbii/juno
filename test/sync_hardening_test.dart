import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/features/plan/recurrence.dart';

import 'support/fake_remote.dart';

AppDatabase fresh() => AppDatabase.memory(NativeDatabase.memory());

Future<void> sync(AppDatabase db, FakeRemote r) => SyncCore(db, r).run();

void main() {
  test('C1: a new device\'s seed rows never overwrite edits made elsewhere', () async {
    final remote = FakeRemote();
    final a = fresh();
    final la = Ledger(a);
    await la.upsertAccount(
      AccountsCompanion(
        id: Value(seedId('acct:checking')),
        name: const Value('BLOM'),
        kind: const Value(AccountKind.checking),
        openingBalanceCents: const Value(500000),
      ),
    );
    await la.setRate('LBP', 90000);
    await sync(a, remote);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    final b = fresh(); // seeds now — later than A's edits
    await sync(b, remote);
    await sync(a, remote);

    for (final db in [a, b]) {
      final acct = await (db.select(db.accounts)..where((x) => x.id.equals(seedId('acct:checking')))).getSingle();
      expect(acct.name, 'BLOM');
      expect(acct.openingBalanceCents, 500000);
      final lbp = await (db.select(db.currencyRates)..where((x) => x.code.equals('LBP'))).getSingle();
      expect(lbp.perUsd, 90000);
    }
  });

  test('C2: recurring materialisation on a stale device does not undo edits', () async {
    final remote = FakeRemote();
    final a = fresh();
    final b = fresh();
    final la = Ledger(a);
    final ruleId = await la.upsertRecurring(
      RecurringRulesCompanion.insert(
        type: TxType.expense,
        scope: Scope.household,
        amountCents: 1000,
        accountId: seedId('acct:checking'),
        frequency: Frequency.monthly,
        anchorDate: '2026-07-02',
        nextDue: '2026-07-02',
      ),
    );
    await materializeRecurring(a, now: DateTime(2026, 8, 10)); // Jul + Aug
    await sync(a, remote);
    await sync(b, remote); // B has the rule and both occurrences

    // A edits the rule and one occurrence.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await la.upsertRecurring(
      RecurringRulesCompanion(
        id: Value(ruleId),
        type: const Value(TxType.expense),
        scope: const Value(Scope.household),
        amountCents: const Value(2000),
        accountId: Value(seedId('acct:checking')),
        frequency: const Value(Frequency.monthly),
        anchorDate: const Value('2026-07-02'),
        nextDue: const Value('2026-09-02'),
      ),
    );
    final jul = occurrenceId(ruleId, '2026-07-02');
    await la.updateTransaction(jul, const TransactionsCompanion(amountCents: Value(1234)));
    await sync(a, remote);

    // B, before pulling, opens in September and posts the Sept occurrence.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await materializeRecurring(b, now: DateTime(2026, 9, 5));
    await sync(b, remote);
    await sync(a, remote);

    for (final db in [a, b]) {
      final rule = await (db.select(db.recurringRules)..where((r) => r.id.equals(ruleId))).getSingle();
      expect(rule.amountCents, 2000, reason: 'rule edit lost');
      final t = await (db.select(db.transactions)..where((t) => t.id.equals(jul))).getSingle();
      expect(t.amountCents, 1234, reason: 'occurrence edit lost');
    }
  });

  test('C2b: a deleted occurrence is not resurrected by another device', () async {
    final remote = FakeRemote();
    final a = fresh();
    final b = fresh();
    final la = Ledger(a);
    final ruleId = await la.upsertRecurring(
      RecurringRulesCompanion.insert(
        type: TxType.expense,
        scope: Scope.personal,
        amountCents: 500,
        accountId: seedId('acct:checking'),
        frequency: Frequency.monthly,
        anchorDate: '2026-07-02',
        nextDue: '2026-07-02',
      ),
    );
    await sync(a, remote);
    await sync(b, remote);
    await materializeRecurring(a, now: DateTime(2026, 7, 3));
    await la.deleteTransaction(occurrenceId(ruleId, '2026-07-02'));
    await sync(a, remote);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await materializeRecurring(b, now: DateTime(2026, 7, 3)); // B never saw it
    await sync(b, remote);
    await sync(a, remote);
    for (final db in [a, b]) {
      final t = await (db.select(
        db.transactions,
      )..where((t) => t.id.equals(occurrenceId(ruleId, '2026-07-02')))).getSingle();
      expect(t.deletedAt, isNotNull, reason: 'deleted occurrence came back');
    }
  });

  test('C3: signing in as another account on a used device is refused', () async {
    final remote = FakeRemote();
    final a = fresh();
    await Ledger(a).addTransaction(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.personal,
        amountCents: 100,
        accountId: seedId('acct:checking'),
        occurredOn: Day.today(),
        note: const Value('u1 data'),
      ),
    );
    await sync(a, remote);
    remote.user = 'user-2';
    await expectLater(sync(a, remote), throwsA(isA<AccountMismatch>()));
    // Nothing of user-1's was written as user-2.
    expect(remote.tables['transactions']!.values.every((r) => r['user_id'] == 'user-1'), isTrue);
  });

  test('C4: rows that commit late are still pulled', () async {
    final remote = FakeRemote();
    final a = fresh();
    final b = fresh();
    await sync(a, remote);
    await sync(b, remote); // B's cursor is now at the newest stamp
    final row = (await a.customSelect("SELECT * FROM accounts WHERE name = 'Cash'").getSingle()).data;
    remote.insertLate(
      'accounts',
      {...row, 'name': 'Late cash', 'updated_at': DateTime.now().toUtc().toIso8601String(), 'user_id': 'user-1'}
        ..remove('dirty'),
    );
    await sync(b, remote);
    final cash = await (b.select(b.accounts)..where((x) => x.id.equals(row['id'] as String))).getSingle();
    expect(cash.name, 'Late cash');
  });

  test('H1: one row the server rejects does not block the rest', () async {
    final remote = FakeRemote()..rejectNotes.add('POISON');
    final a = fresh();
    final b = fresh();
    final la = Ledger(a);
    for (final note in ['ok-1', 'POISON', 'ok-2']) {
      await la.addTransaction(
        TransactionsCompanion.insert(
          type: TxType.expense,
          scope: Scope.personal,
          amountCents: 100,
          accountId: seedId('acct:checking'),
          occurredOn: Day.today(),
          note: Value(note),
        ),
      );
    }
    final core = SyncCore(a, remote);
    await core.run();
    expect(core.failures, 1);
    await sync(b, remote);
    final notes = (await Ledger(b).transactions(const TxQuery())).map((t) => t.note).toSet();
    expect(notes, {'ok-1', 'ok-2'});
    // The poisoned row stays dirty, to retry once fixed.
    final dirty = await a
        .customSelect("SELECT COUNT(*) AS n FROM transactions WHERE dirty = 1 AND note = 'POISON'")
        .getSingle();
    expect(dirty.read<int>('n'), 1);
  });
}
