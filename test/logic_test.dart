import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/deeplink/quick_add.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/import/csv_import.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/plan/recurrence.dart';

AppDatabase _db() => AppDatabase.memory(NativeDatabase.memory());

Transaction _tx(
  String day,
  int cents, {
  TxType type = TxType.expense,
  Scope scope = Scope.personal,
  String? cat,
  String note = '',
}) => Transaction(
  id: newId(),
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  type: type,
  scope: scope,
  amountCents: cents,
  accountId: 'a',
  categoryId: cat,
  occurredOn: day,
  note: note,
  merchant: '',
  currency: 'USD',
  tags: '',
);

void main() {
  group('Money', () {
    test('parses the formats banks and people type', () {
      expect(Money.parse(r'$1,204.50'), 120450);
      expect(Money.parse('12'), 1200);
      expect(Money.parse('12.5'), 1250);
      expect(Money.parse('-12.00'), -1200);
      expect(Money.parse('(45.10)'), -4510);
      expect(Money.parse('1.204,50'), 120450);
      expect(Money.parse('12,5'), 1250);
      expect(Money.parse('1,204'), 120400);
      expect(Money.parse('USD 7.99'), 799);
      expect(Money.parse('abc'), isNull);
      expect(Money.parse(''), isNull);
    });

    test('formats', () {
      expect(Money.format(120450), r'$1,204.50');
      expect(Money.whole(120450), r'$1,205');
      expect(Money.signed(-1250), r'−⁠$12.50');
      expect(Money.compact(0), r'$0');
    });
  });

  group('Day', () {
    test('round-trips and bounds months', () {
      expect(Day.of(DateTime(2026, 2, 3)), '2026-02-03');
      expect(Day.parse('2026-02-03'), DateTime(2026, 2, 3));
      expect(Day.lastOfMonth(DateTime(2028, 2)), '2028-02-29');
    });
  });

  group('CSV import', () {
    const bank = '''
Date,Description,Amount,Balance
2026-09-01,SPINNEYS ACHRAFIEH,-54.20,1000
2026-09-01,STARBUCKS,-4.50,995.5
2026-09-01,STARBUCKS,-4.50,991
2026-09-02,PAYROLL ACME,5200.00,6191
2026-09-03,Netflix.com,-15.99,6175
''';

    test('guesses columns and date format', () {
      final t = CsvTable.parse(bank);
      expect(t.headers, ['Date', 'Description', 'Amount', 'Balance']);
      final m = ColumnMapping.guess(t);
      expect(m.date, 0);
      expect(m.description, 1);
      expect(m.amount, 2);
      expect(m.dateFormat, 'yyyy-MM-dd');
      expect(m.isComplete, isTrue);
    });

    test('debit/credit columns and EU dates', () {
      const csv = 'Posting Date;Details;Debit;Credit\n31/08/2026;Rent;1450,00;\n01/09/2026;Salary;;5200,00\n';
      final t = CsvTable.parse(csv);
      final m = ColumnMapping.guess(t);
      expect(m.mode, AmountMode.debitCredit);
      expect(m.dateFormat, 'dd/MM/yyyy');
      final rows = buildRows(table: t, mapping: m, existingHashes: {}, memory: {}, categories: []);
      expect(rows.map((r) => r.cents), [-145000, 520000]);
      expect(rows.first.day, '2026-08-31');
    });

    test('dedupe: identical rows in one file stay distinct, re-import is flagged', () {
      final t = CsvTable.parse(bank);
      final m = ColumnMapping.guess(t);
      final first = buildRows(table: t, mapping: m, existingHashes: {}, memory: {}, categories: []);
      final coffees = first.where((r) => r.description == 'STARBUCKS').toList();
      expect(coffees, hasLength(2));
      expect(coffees[0].hash, isNot(coffees[1].hash));

      final again = buildRows(
        table: t,
        mapping: m,
        existingHashes: {for (final r in first) r.hash},
        memory: {},
        categories: [],
      );
      expect(again.every((r) => r.duplicate && !r.include), isTrue);
    });

    test('suggests categories from history, then keywords', () {
      final cats = [
        _cat('Coffee', CategoryKind.expense),
        _cat('Subscriptions', CategoryKind.expense),
        _cat('Groceries', CategoryKind.expense),
        _cat('Salary', CategoryKind.income),
      ];
      final byName = {for (final c in cats) c.name.toLowerCase(): c};
      final memory = {'spinneys achrafieh': cats[2].id};
      expect(suggestCategory('SPINNEYS ACHRAFIEH', TxType.expense, memory, byName), cats[2].id);
      expect(suggestCategory('STARBUCKS #22', TxType.expense, memory, byName), cats[0].id);
      expect(suggestCategory('Netflix.com', TxType.expense, memory, byName), cats[1].id);
      expect(suggestCategory('PAYROLL ACME', TxType.income, memory, byName), cats[3].id);
      // Kind must match: an income row never lands in an expense category.
      expect(suggestCategory('Netflix refund', TxType.income, memory, byName), isNull);
    });
  });

  group('Recurrence', () {
    test('monthly keeps the anchor day through short months', () {
      final anchor = DateTime(2026, 1, 31);
      var d = anchor;
      final seen = <String>[];
      for (var i = 0; i < 3; i++) {
        d = nextOccurrence(anchor: anchor, from: d, frequency: Frequency.monthly);
        seen.add(Day.of(d));
      }
      expect(seen, ['2026-02-28', '2026-03-31', '2026-04-30']);
    });

    test('materialisation is idempotent and respects deletions', () async {
      final db = _db();
      final ledger = Ledger(db);
      final account = seedId('acct:checking');
      await ledger.upsertRecurring(
        RecurringRulesCompanion.insert(
          type: TxType.expense,
          scope: Scope.household,
          amountCents: 145000,
          accountId: account,
          frequency: Frequency.monthly,
          anchorDate: '2026-07-02',
          nextDue: '2026-07-02',
        ),
      );
      final now = DateTime(2026, 10);
      expect(await materializeRecurring(db, now: now), 3); // Jul, Aug, Sep
      expect(await materializeRecurring(db, now: now), 0);

      final txs = await ledger.transactions(const TxQuery());
      await ledger.deleteTransaction(txs.first.id);
      // Rewind the rule as if another device still had the old nextDue.
      await db.customStatement("UPDATE recurring_rules SET next_due = '2026-07-02'");
      expect(await materializeRecurring(db, now: now), 0);
      expect((await ledger.transactions(const TxQuery())).length, 2);
      await db.close();
    });
  });

  group('Analytics', () {
    test('summary ignores transfers and splits scopes', () {
      final s = PeriodSummary.of([
        _tx('2026-09-01', 500000, type: TxType.income),
        _tx('2026-09-02', 10000, scope: Scope.household, cat: 'g'),
        _tx('2026-09-03', 2500, cat: 'c'),
        _tx('2026-09-04', 99999, type: TxType.transfer),
      ]);
      expect(s.income, 500000);
      expect(s.expense, 12500);
      expect(s.byScope[Scope.household], 10000);
      expect(s.byScope[Scope.personal], 2500);
      expect(s.rankedCategories.first.key, 'g');
      expect(s.savingsRate, closeTo(0.975, 1e-9));
    });

    test('pace projects only the current month', () {
      final p = MonthPace(month: DateTime(2026, 9), expense: 30000, today: DateTime(2026, 9, 10));
      expect(p.avgDaily, 3000);
      expect(p.projected, 90000);
      final past = MonthPace(month: DateTime(2026, 8), expense: 31000, today: DateTime(2026, 9, 10));
      expect(past.projected, 31000);
    });

    test('budget status matches category and scope', () {
      final b = Budget(
        id: 'b',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        dirty: false,
        scope: Scope.household,
        limitCents: 10000,
      );
      final st = budgetStatuses(
        [b],
        [
          _tx('2026-09-01', 9000, scope: Scope.household),
          _tx('2026-09-01', 5000),
        ],
      ).single;
      expect(st.spent, 9000);
      expect(st.near, isTrue);
      expect(st.over, isFalse);
    });

    test('monthly series buckets by month', () {
      final pts = monthlySeries(
        [_tx('2026-08-15', 100), _tx('2026-09-01', 200, scope: Scope.household)],
        DateTime(2026, 9),
        3,
      );
      expect(pts.map((p) => p.expense), [0, 100, 200]);
      expect(pts.last.household, 200);
    });
  });

  group('Quick add links', () {
    test('parses the Back Tap shortcut URL', () {
      final q = QuickAdd.parse(Uri.parse('juno://add?amount=12,50&category=grocery&scope=Household&note=Spinneys'))!;
      expect(q.amountCents, 1250);
      expect(q.category, 'grocery');
      expect(q.scope, Scope.household);
      expect(q.note, 'Spinneys');
      expect(q.saveDirectly, isTrue);
    });

    test('no amount or confirm opens the sheet', () {
      expect(QuickAdd.parse(Uri.parse('juno://add'))!.saveDirectly, isFalse);
      expect(QuickAdd.parse(Uri.parse('juno://add?amount=3&confirm=1'))!.saveDirectly, isFalse);
      expect(QuickAdd.parse(Uri.parse('juno://settings')), isNull);
    });

    test('fuzzy matches category names', () {
      const names = ['Groceries', 'Dining', 'Coffee', 'Internet & phone'];
      expect(fuzzyMatch('grocery', names, (s) => s), 'Groceries');
      expect(fuzzyMatch('Groceris', names, (s) => s), 'Groceries');
      expect(fuzzyMatch('coffee', names, (s) => s), 'Coffee');
      expect(fuzzyMatch('internet', names, (s) => s), 'Internet & phone');
      expect(fuzzyMatch('zzzzzz', names, (s) => s), isNull);
    });
  });
}

Category _cat(String name, CategoryKind kind) => Category(
  id: seedId('cat:$name'),
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  name: name,
  icon: 'dots',
  colorIndex: 0,
  kind: kind,
  defaultScope: Scope.personal,
  sort: 0,
  archived: false,
);
