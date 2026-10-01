import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/deeplink/quick_add.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/import/csv_import.dart';
import 'package:juno/features/plan/recurrence.dart';

void main() {
  test('weekly recurrence keeps the weekday across DST changes', () {
    // Pure calendar arithmetic: no Duration-based day stepping.
    var d = DateTime(2026, 10, 20);
    final seen = <String>[];
    for (var i = 0; i < 4; i++) {
      d = nextOccurrence(anchor: DateTime(2026, 10, 20), from: d, frequency: Frequency.weekly);
      seen.add(Day.of(d));
    }
    expect(seen, ['2026-10-27', '2026-11-03', '2026-11-10', '2026-11-17']);
  });

  test('editing a note does not re-price a foreign entry at today’s rate', () async {
    final db = AppDatabase.memory(NativeDatabase.memory());
    final l = Ledger(db);
    final lbp = await l.upsertAccount(
      AccountsCompanion.insert(name: 'LBP', kind: AccountKind.cash, currency: const Value('LBP')),
    );
    final id = await l.addTransaction(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.personal,
        amountCents: 89500000,
        accountId: lbp,
        occurredOn: Day.today(),
      ),
    );
    await l.setRate('LBP', 100000);
    // The entry sheet sends every field back on save.
    await l.updateTransaction(
      id,
      TransactionsCompanion(amountCents: const Value(89500000), accountId: Value(lbp), note: const Value('x')),
    );
    final t = (await l.transactions(const TxQuery())).single;
    expect(t.usd, 1000, reason: 'USD value must stay at the rate it was logged with');
    // A real amount change re-prices at the current rate.
    await l.updateTransaction(id, TransactionsCompanion(amountCents: const Value(100000000), accountId: Value(lbp)));
    expect((await l.transactions(const TxQuery())).single.usd, 1000);
    await db.close();
  });

  test('Money.parse reads dot thousands and never uses floats', () {
    expect(Money.parse('150.000'), 15000000);
    expect(Money.parse('1.234.567'), 123456700);
    expect(Money.parse('1.234.567,89'), 123456789);
    expect(Money.parse('12.50'), 1250);
    expect(Money.parse('0.285'), 29); // three decimals with a leading 0: decimal
    expect(Money.parse('1.005'), 100500); // 1,005 — thousands
    expect(Money.parse('19.99'), 1999);
    expect(Money.parse('1.5'), 150);
    expect(Money.parse('12 DR'), -1200);
    expect(Money.parse('Address Line 1'), isNull);
  });

  test('CSV: ambiguous day/month dates prefer day-first and are flagged', () {
    final values = ['03/04/2026', '05/04/2026'];
    expect(DateFormats.detect(values), 'dd/MM/yyyy');
    expect(DateFormats.isAmbiguous(values, 'dd/MM/yyyy'), isTrue);
    expect(DateFormats.isAmbiguous(['25/04/2026', '03/04/2026'], 'dd/MM/yyyy'), isFalse);
    // Detection looks at every row, not a sample: a later 25th settles it.
    final many = [for (var i = 0; i < 80; i++) '0${1 + i % 9}/04/2026', '04/25/2026'];
    expect(DateFormats.detect(many), 'MM/dd/yyyy');
  });

  test('a header like "Address Line 1" is a header, not data', () {
    final t = CsvTable.parse('Date,Address Line 1,Amount\n2026-09-01,Hamra,-4.50\n');
    expect(t.headers, ['Date', 'Address Line 1', 'Amount']);
  });

  test('fuzzy matching handles non-Latin names and never matches everything', () {
    expect(fuzzyMatch('مطعم', ['مطعم', 'Coffee'], (s) => s), 'مطعم');
    expect(fuzzyMatch('Coffee', ['مطعم', 'Coffee'], (s) => s), 'Coffee');
    expect(fuzzyMatch('Groceries', ['🍕', 'Coffee'], (s) => s), isNull);
  });

  test('dedupe hash depends on the account', () {
    expect(
      dedupeHash('2026-09-01', -450, 'X', 1, account: 'a'),
      isNot(dedupeHash('2026-09-01', -450, 'X', 1, account: 'b')),
    );
  });

  test('balances and net worth today exclude future-dated entries', () async {
    final db = AppDatabase.memory(NativeDatabase.memory());
    final l = Ledger(db);
    await l.addTransaction(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.personal,
        amountCents: 5000,
        accountId: seedId('acct:checking'),
        occurredOn: Day.of(DateTime.now().add(const Duration(days: 20))),
      ),
    );
    expect((await l.watchBalances().first)[seedId('acct:checking')], 0);
    await db.close();
  });

  test('Fx refuses to convert without a rate instead of treating it as USD', () {
    expect(() => Fx.toUsd(1500000000, 'LBP', const {}), throwsStateError);
  });

  test('choosing "—" for a column clears it', () {
    const m = ColumnMapping(date: 0, debit: 2, credit: 3, mode: AmountMode.debitCredit, dateFormat: 'yyyy-MM-dd');
    final cleared = m.withColumn('debit', null);
    expect(cleared.debit, isNull);
    expect(cleared.credit, 3);
    expect(cleared.mode, AmountMode.debitCredit);
  });
}
