import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/features/smart/entry_parser.dart';

Category cat(String name, {CategoryKind kind = CategoryKind.expense}) => Category(
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

final cats = [
  for (final n in [
    'Groceries',
    'Dining',
    'Coffee',
    'Transport',
    'Fuel',
    'Rent',
    'Utilities',
    'Subscriptions',
    'Shopping',
    'Household supplies',
  ])
    cat(n),
  cat('Salary', kind: CategoryKind.income),
  cat('Freelance', kind: CategoryKind.income),
];

String id(String name) => seedId('cat:$name');

// Thursday 1 Oct 2026.
final now = DateTime(2026, 10, 1, 14);

ParsedEntry p(String s, {Map<String, String> memory = const {}}) =>
    parseEntry(s, categories: cats, memory: memory, now: now);

void main() {
  test('amount, category and note', () {
    final e = p('12 coffee kalei');
    expect(e.amountCents, 1200);
    expect(e.currency, isNull);
    expect(e.categoryId, id('Coffee'));
    expect(e.note, 'Kalei');
    expect(e.day, isNull);
  });

  test('k suffix means thousands and implies pounds', () {
    final e = p('40k taxi yesterday');
    expect(e.amountCents, 4000000);
    expect(e.currency, 'LBP');
    expect(e.currencyGuessed, isTrue);
    expect(e.categoryId, id('Transport'));
    expect(e.day, '2026-09-30');
  });

  test('explicit currency, scope word', () {
    final e = p('LBP 150000 generator household');
    expect(e.amountCents, 15000000);
    expect(e.currency, 'LBP');
    expect(e.currencyGuessed, isFalse);
    expect(e.scope, Scope.household);
    expect(e.note, 'Generator');
  });

  test('dollar sign and filler words', () {
    final e = p(r'$5.50 lunch at tawlet');
    expect(e.amountCents, 550);
    expect(e.currency, 'USD');
    expect(e.note, 'Lunch Tawlet');
  });

  test('income from the category', () {
    final e = p('salary 5200');
    expect(e.amountCents, 520000);
    expect(e.type, TxType.income);
    expect(e.categoryId, id('Salary'));
  });

  test('"N days ago" is a date, not the amount', () {
    final e = p('2 days ago 18 groceries');
    expect(e.amountCents, 1800);
    expect(e.day, '2026-09-29');
    expect(e.categoryId, id('Groceries'));
  });

  test('weekday means the last one before today', () {
    expect(p('25 dining monday').day, '2026-09-28');
    expect(p('25 dining thursday').day, '2026-09-24'); // today is Thursday
  });

  test('your own history beats keywords', () {
    final e = p('9 spinneys', memory: {'spinneys': id('Groceries')});
    expect(e.categoryId, id('Groceries'));
    expect(e.note, 'Spinneys');
  });

  test('keyword hints when nothing else matches', () {
    expect(p('15.99 netflix').categoryId, id('Subscriptions'));
    expect(p('30 uber eats').categoryId, id('Dining'));
  });

  test('short words never grab a category ("me" is not Home/Rent)', () {
    final e = p('20 me');
    expect(e.categoryId, isNull);
    expect(e.scope, Scope.personal);
  });

  test('million and thousands separators', () {
    expect(p('1.5m rent').amountCents, 150000000);
    expect(p('150,000 lbp fuel').amountCents, 15000000);
    expect(p('150,000 lbp fuel').currency, 'LBP');
  });

  test('no amount still parses the rest', () {
    final e = p('coffee yesterday');
    expect(e.amountCents, isNull);
    expect(e.categoryId, id('Coffee'));
    expect(e.day, '2026-09-30');
  });
}
