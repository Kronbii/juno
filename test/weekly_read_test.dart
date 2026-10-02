import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/features/home/weekly_read.dart';
import 'package:juno/features/import/csv_import.dart';

var _n = 0;
Transaction tx(String day, int cents, {TxType type = TxType.expense, String? cat, int? base}) => Transaction(
  id: 'w${_n++}',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  type: type,
  scope: Scope.personal,
  amountCents: cents,
  accountId: seedId('acct:checking'),
  categoryId: cat,
  occurredOn: day,
  note: 'private note',
  merchant: 'Private shop',
  currency: base == null ? 'USD' : 'LBP',
  baseCents: base,
  tags: '',
);

Category cat(String id, String name) => Category(
  id: id,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  name: name,
  icon: 'cart',
  colorIndex: 0,
  kind: CategoryKind.expense,
  defaultScope: Scope.personal,
  sort: 0,
  archived: false,
);

void main() {
  final cats = {'g': cat('g', 'Groceries'), 'd': cat('d', 'Dining')};
  // Thursday 1 October 2026: the week began Monday 28 September.
  final thu = DateTime(2026, 10, 1, 20);

  test('this week so far against the same days of last week', () {
    final f = weekFacts(
      [
        tx('2026-09-28', 3000, cat: 'g'), // Mon, this week
        tx('2026-10-01', 1500, cat: 'd'), // Thu, today
        tx('2026-10-01', 100000, base: 1117, cat: 'd'), // LBP, counted in dollars
        tx('2026-09-21', 2000, cat: 'g'), // last Mon
        tx('2026-09-24', 500), // last Thu: same days, counts
        tx('2026-09-25', 9999), // last Fri: later in the week, not compared
        tx('2026-09-27', 7777), // last Sun
        tx('2026-10-01', 500000, type: TxType.income), // income ignored
        tx('2026-10-01', 4000, type: TxType.transfer), // transfers ignored
      ],
      cats,
      thu,
    );
    expect(f.monday, '2026-09-28');
    expect(f.daysIn, 4);
    expect(f.spent, 3000 + 1500 + 1117);
    expect(f.lastWeek, 2000 + 500);
    expect(f.entries, 3);
    expect(f.top.first, ('Groceries', 3000));
    expect(f.top[1], ('Dining', 2617));
    expect(
      f.text,
      r'You’ve spent $56 this week, $31 more than by this point last week. Most of it went to Groceries ($30).',
    );
  });

  test('Monday compares with last Monday only; Sunday with the whole week', () {
    final mon = weekFacts(
      [tx('2026-09-28', 100), tx('2026-09-21', 300), tx('2026-09-22', 999)],
      cats,
      DateTime(2026, 9, 28),
    );
    expect((mon.daysIn, mon.spent, mon.lastWeek), (1, 100, 300));
    final sun = weekFacts(
      [tx('2026-10-04', 100), tx('2026-09-27', 300), tx('2026-09-28', 50)],
      cats,
      DateTime(2026, 10, 4),
    );
    expect((sun.daysIn, sun.spent, sun.lastWeek), (7, 150, 300));
  });

  test('a week across a month and year boundary', () {
    // Thursday 31 Dec 2026; Monday was 28 Dec.
    final f = weekFacts(
      [tx('2026-12-28', 100), tx('2026-12-21', 40), tx('2027-01-01', 999)],
      cats,
      DateTime(2026, 12, 31),
    );
    expect((f.monday, f.spent, f.lastWeek), ('2026-12-28', 100, 40));
  });

  test('quiet weeks read naturally', () {
    expect(weekFacts([], cats, thu).text, 'Nothing spent yet this week.');
    expect(
      weekFacts([tx('2026-09-29', 1000)], cats, thu).text,
      r'You’ve spent $10 this week.',
    );
    expect(
      weekFacts([tx('2026-09-29', 1000), tx('2026-09-22', 1000)], cats, thu).text,
      startsWith(r'You’ve spent $10 this week, the same as by this point last week.'),
    );
  });

  test('what the AI is given holds totals only: no notes, shops or single entries', () {
    final f = weekFacts([tx('2026-09-29', 1234, cat: 'g'), tx('2026-09-22', 400)], cats, thu);
    expect(f.facts, isNot(contains('private')));
    expect(f.facts, isNot(contains('Private')));
    expect(f.facts, contains(r'Spent so far: $12'));
    expect(f.facts, contains(r'Same days last week: $4'));
  });

  test('import: AI suggestions fill only empty rows, with a category of the right kind', () {
    final salary = Category(
      id: 's',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      dirty: false,
      name: 'Salary',
      icon: 'briefcase',
      colorIndex: 0,
      kind: CategoryKind.income,
      defaultScope: Scope.personal,
      sort: 0,
      archived: false,
    );
    ImportRow row(String d, int cents, {String? cat}) =>
        ImportRow(index: 0, day: '2026-09-01', description: d, cents: cents, hash: d, categoryId: cat);
    final rows = [
      row(' SPINNEYS ', -2000),
      row('PAYROLL', 500000),
      row('PAYROLL REFUND', 3000),
      row('KNOWN', -100, cat: 'd'),
      row('MYSTERY', -100),
    ];
    final placed = applyCategorySuggestions(
      rows,
      {'SPINNEYS': 'Groceries', 'PAYROLL': 'Salary', 'PAYROLL REFUND': 'Dining', 'KNOWN': 'Groceries'},
      [...cats.values, salary],
    );
    expect(placed, 2);
    expect([for (final r in rows) r.categoryId], ['g', 's', null, 'd', null]);
    expect([for (final r in rows) r.aiSuggested], [true, true, false, false, false]);
  });
}
