import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/features/smart/entry_parser.dart';

/// Juno's starter categories, each in its scope.
final cats = [
  for (final c in starterCategories)
    Category(
      id: c.id,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      dirty: false,
      name: c.name,
      icon: c.icon,
      colorIndex: c.color,
      kind: c.kind,
      scope: c.scope,
      sort: 0,
      archived: false,
    ),
];

/// By starter key: "household:Subscriptions" is the household one.
String id(String key) => seedId('cat:$key');

// Thursday 1 Oct 2026.
final now = DateTime(2026, 10, 1, 14);

ParsedEntry p(String s, {Map<String, String> memory = const {}, Scope? prefer}) =>
    parseEntry(s, categories: cats, memory: memory, now: now, prefer: prefer);

void main() {
  test('amount, category and note', () {
    final e = p('12 groceries spinneys');
    expect(e.amountCents, 1200);
    expect(e.currency, isNull);
    expect(e.categoryId, id('Groceries'));
    expect(e.note, 'Spinneys');
    expect(e.day, isNull);
  });

  test('k suffix means thousands and implies pounds', () {
    final e = p('40k taxi yesterday');
    expect(e.amountCents, 4000000);
    expect(e.currency, 'LBP');
    expect(e.currencyGuessed, isTrue);
    expect(e.categoryId, id('Transportation'));
    expect(e.day, '2026-09-30');
  });

  test('explicit currency, scope word', () {
    final e = p('LBP 150000 cash household');
    expect(e.amountCents, 15000000);
    expect(e.currency, 'LBP');
    expect(e.currencyGuessed, isFalse);
    expect(e.scope, Scope.household);
    expect(e.categoryId, isNull);
    expect(e.note, 'Cash');
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
    expect(p('30 uber eats').categoryId, id('Food & Outings'));
    expect(p('LBP 150000 generator').categoryId, id('Electricity'));
  });

  test('a typo keeps its first letter: "grocries" is Groceries, "eats" is not Dates', () {
    expect(p('18 grocries').categoryId, id('Groceries'));
    expect(p('18 tranportation').categoryId, id('Transportation'));
    expect(p('12 eats').categoryId, isNull);
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
    final e = p('dates yesterday');
    expect(e.amountCents, isNull);
    expect(e.categoryId, id('Dates'));
    expect(e.day, '2026-09-30');
  });

  test('spending takes its category\'s scope: "rent" is household', () {
    final e = p('600 rent');
    expect(e.categoryId, id('Rent'));
    expect(e.scope, Scope.household);
    // Even when the text says otherwise: the category decides.
    expect(p('600 rent personal').scope, Scope.household);
    expect(p('20 dates').scope, Scope.personal);
    expect(p('5 other').scope, Scope.other);
  });

  test('two scopes\' "Subscriptions": the scope said, else the one preferred, picks', () {
    expect(p('10 subscriptions household').categoryId, id('household:Subscriptions'));
    expect(p('10 subscriptions household').scope, Scope.household);
    expect(p('10 subscriptions personal').categoryId, id('Subscriptions'));
    expect(p('10 subscriptions', prefer: Scope.household).categoryId, id('household:Subscriptions'));
    expect(p('10 subscriptions', prefer: Scope.personal).categoryId, id('Subscriptions'));
    expect(p('15.99 netflix household').categoryId, id('household:Subscriptions'));
    // Your history names the exact one.
    expect(p('9 shahid', memory: {'shahid': id('household:Subscriptions')}).scope, Scope.household);
  });

  test('income has no scope to follow', () {
    final e = p('salary 5200 household');
    expect(e.type, TxType.income);
    expect(e.scope, Scope.household);
  });
}
