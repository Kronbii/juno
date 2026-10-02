// Sync over months between a desktop and a phone that's often in a drawer:
// stale devices posting recurring bills, clocks that are off by hours,
// splits meeting old copies, imports undone after splitting.
import 'package:clock/clock.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/features/plan/recurrence.dart';

import 'support/fake_remote.dart';

AppDatabase fresh() => AppDatabase.memory(NativeDatabase.memory());

Future<void> sync(AppDatabase db, FakeRemote r) => SyncCore(db, r).run();

/// What the app does on opening: catch up with the other device first,
/// then post due bills, then share them.
Future<void> open(AppDatabase db, FakeRemote r, DateTime now) async {
  await sync(db, r);
  await materializeRecurring(db, now: now);
  await sync(db, r);
}

RecurringRulesCompanion rent(int cents, {String? id}) => RecurringRulesCompanion(
  id: id == null ? const Value.absent() : Value(id),
  type: const Value(TxType.expense),
  scope: const Value(Scope.personal),
  amountCents: Value(cents),
  accountId: Value(seedId('acct:checking')),
  frequency: const Value(Frequency.monthly),
  anchorDate: const Value('2026-07-01'),
  nextDue: const Value('2026-07-01'),
  note: const Value('Rent'),
);

Future<Transaction> row(AppDatabase db, String id) =>
    (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();

void main() {
  late FakeRemote remote;
  late AppDatabase desk;
  late AppDatabase phone;
  late Ledger ld;
  late Ledger lp;

  setUp(() {
    remote = FakeRemote();
    desk = fresh();
    phone = fresh();
    ld = Ledger(desk);
    lp = Ledger(phone);
  });
  tearDown(() async {
    await desk.close();
    await phone.close();
  });

  test('a phone opened after weeks posts bills at the rule’s current amount, never its old copy', () async {
    final ruleId = await ld.upsertRecurring(rent(100000));
    await open(desk, remote, DateTime(2026, 7, 2));
    await open(phone, remote, DateTime(2026, 7, 2));
    // August: the desktop raises the rent and keeps posting.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final r = await (desk.select(desk.recurringRules)..where((x) => x.id.equals(ruleId))).getSingle();
    await ld.upsertRecurring(rent(110000, id: ruleId).copyWith(nextDue: Value(r.nextDue)));
    await open(desk, remote, DateTime(2026, 9, 2));
    // The phone, unopened since July, opens in September.
    await open(phone, remote, DateTime(2026, 9, 2));
    await sync(desk, remote);
    for (final db in [desk, phone]) {
      expect((await row(db, occurrenceId(ruleId, '2026-08-01'))).amountCents, 110000);
      expect((await row(db, occurrenceId(ruleId, '2026-09-01'))).amountCents, 110000);
    }
  });

  test('offline phone: its stale copies of bills the desktop already posted never replace them', () async {
    final ruleId = await ld.upsertRecurring(rent(100000));
    await open(desk, remote, DateTime(2026, 7, 2));
    await open(phone, remote, DateTime(2026, 7, 2));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final r = await (desk.select(desk.recurringRules)..where((x) => x.id.equals(ruleId))).getSingle();
    await ld.upsertRecurring(rent(110000, id: ruleId).copyWith(nextDue: Value(r.nextDue)));
    await open(desk, remote, DateTime(2026, 9, 2));
    // The phone opens with no network: it posts from its old rule...
    remote.down = true;
    await open(phone, remote, DateTime(2026, 9, 2)).catchError((_) {});
    remote.down = false;
    // ...and syncs later.
    await sync(phone, remote);
    await sync(desk, remote);
    for (final db in [desk, phone]) {
      expect((await row(db, occurrenceId(ruleId, '2026-09-01'))).amountCents, 110000, reason: 'the server’s copy wins');
    }
  });

  test('a bill deleted on the desktop: an offline phone’s phantom postings are taken back', () async {
    final ruleId = await withClock(Clock.fixed(DateTime(2026, 6, 20, 12)), () => ld.upsertRecurring(rent(100000)));
    await open(desk, remote, DateTime(2026, 7, 2));
    await open(phone, remote, DateTime(2026, 7, 2));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await withClock(Clock.fixed(DateTime(2026, 7, 15, 12)), () => ld.deleteRecurring(ruleId));
    await sync(desk, remote);
    // Phone offline on 2 Sep: posts August and September for a rule it
    // doesn't know is gone.
    remote.down = true;
    await open(phone, remote, DateTime(2026, 9, 2)).catchError((_) {});
    remote.down = false;
    await sync(phone, remote);
    await sync(desk, remote);
    for (final db in [desk, phone]) {
      final live = await (db.select(
        db.transactions,
      )..where((t) => t.recurringId.equals(ruleId) & t.deletedAt.isNull())).get();
      expect(live.map((t) => t.occurredOn), ['2026-07-01'], reason: 'only the bill from before the deletion');
    }
  });

  test('a phone clock two hours slow: its edit made after seeing the desktop’s still sticks', () async {
    final real = DateTime.utc(2026, 10, 2, 12);
    final id = await withClock(
      Clock.fixed(real),
      () => ld.addTransaction(
        TransactionsCompanion.insert(
          type: TxType.expense,
          scope: Scope.personal,
          amountCents: 4500,
          accountId: seedId('acct:checking'),
          occurredOn: '2026-10-02',
          note: const Value('Groceries'),
        ),
      ),
    );
    await sync(desk, remote);
    await sync(phone, remote);
    await withClock(
      Clock.fixed(real.add(const Duration(minutes: 1))),
      () => ld.updateTransaction(id, const TransactionsCompanion(amountCents: Value(5400))),
    );
    await sync(desk, remote);
    await sync(phone, remote);
    await withClock(
      Clock.fixed(real.add(const Duration(minutes: 10)).subtract(const Duration(hours: 2))),
      () => lp.updateTransaction(id, const TransactionsCompanion(note: Value('Groceries – Spinneys'))),
    );
    await sync(phone, remote);
    await sync(desk, remote);
    for (final db in [desk, phone]) {
      final t = await row(db, id);
      expect((t.note, t.amountCents), ('Groceries – Spinneys', 5400));
    }
  });

  test('a phone clock two hours fast: the desktop’s later edit still sticks', () async {
    final real = DateTime.utc(2026, 10, 2, 12);
    final id = await withClock(
      Clock.fixed(real.add(const Duration(hours: 2))),
      () => lp.addTransaction(
        TransactionsCompanion.insert(
          type: TxType.expense,
          scope: Scope.personal,
          amountCents: 4500,
          accountId: seedId('acct:checking'),
          occurredOn: '2026-10-02',
          note: const Value('Taxi'),
        ),
      ),
    );
    await sync(phone, remote);
    await sync(desk, remote);
    await withClock(
      Clock.fixed(real.add(const Duration(minutes: 30))),
      () => ld.deleteTransaction(id),
    );
    await sync(desk, remote);
    await sync(phone, remote);
    for (final db in [desk, phone]) {
      expect((await row(db, id)).deletedAt, isNotNull, reason: 'the delete wasn’t lost to the phone’s future stamp');
    }
  });

  test('split on the desktop, stale edit on the phone: the money is counted once', () async {
    final id = await ld.addTransaction(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.personal,
        amountCents: 10000,
        accountId: seedId('acct:checking'),
        occurredOn: '2026-10-02',
        note: const Value('Carrefour'),
      ),
    );
    await sync(desk, remote);
    await sync(phone, remote);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await ld.splitTransaction(id, [(null, Scope.household, 6000), (null, Scope.personal, 4000)]);
    await sync(desk, remote);
    // The phone, not yet synced, edits the original entry's note.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await lp.updateTransaction(id, const TransactionsCompanion(note: Value('Carrefour weekly shop')));
    await sync(phone, remote);
    await sync(desk, remote);
    await sync(phone, remote);
    for (final db in [desk, phone]) {
      final rows = await Ledger(db).transactions(const TxQuery());
      expect(rows.fold(0, (s, t) => s + t.amountCents), 10000, reason: 'paid once');
      expect(rows.map((t) => t.splitGroup).toSet().length, 1, reason: 'still one split');
    }
  });

  test('undoing an import also takes back the parts of entries split since', () async {
    final batch = await ld.commitImport('bank.csv', [
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.personal,
        amountCents: 10000,
        accountId: seedId('acct:checking'),
        occurredOn: '2026-09-10',
        merchant: const Value('Carrefour'),
      ),
    ]);
    final r = (await ld.transactions(const TxQuery())).single;
    await ld.splitTransaction(r.id, [(null, Scope.household, 6000), (null, Scope.personal, 4000)]);
    await ld.undoImport(batch);
    expect(await ld.transactions(const TxQuery()), isEmpty);
  });
}
