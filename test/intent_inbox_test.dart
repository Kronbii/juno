import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/ios/intent_inbox.dart';
import 'package:juno/core/money.dart';

void main() {
  late AppDatabase db;
  late List<Category> cats;
  late List<Account> accts;

  setUp(() async {
    db = AppDatabase.memory(NativeDatabase.memory());
    cats = await db.select(db.categories).get();
    accts = await db.select(db.accounts).get();
  });
  tearDown(() => db.close());

  test('parses the inbox contract and tolerates junk', () {
    expect(parseInbox(null), isEmpty);
    expect(parseInbox('not json'), isEmpty);
    final items = parseInbox(
      '[{"id":"A1","amount":12.5,"category":"Groceries","scope":"household","at":"2026-10-01T09:30:00"},{"no":"id"}]',
    );
    expect(items, hasLength(1));
    expect(items.single.amount, 12.5);
  });

  test('a structured intent becomes the right row, keeping its id', () async {
    final item = parseInbox(
      '[{"id":"AB-12","amount":12.5,"category":"grocery","scope":"household","note":"Spinneys","at":"2026-10-01T09:30:00"}]',
    ).single;
    final row = (await inboxToEntry(item, categories: cats, accounts: accts, rates: const {}))!;
    expect(row.id.value, 'ab-12');
    expect(row.amountCents.value, 1250);
    expect(row.categoryId.value, seedId('cat:Groceries'));
    expect(row.scope.value, Scope.household);
    expect(row.occurredOn.value, '2026-10-01');
    expect(row.note.value, 'Spinneys');
  });

  test('dictated text is parsed like the quick line', () async {
    final item = parseInbox('[{"id":"t1","text":"salary 5200"}]').single;
    final row = (await inboxToEntry(item, categories: cats, accounts: accts, rates: const {}))!;
    expect(row.type.value, TxType.income);
    expect(row.amountCents.value, 520000);
    expect(row.categoryId.value, seedId('cat:Salary'));
  });

  test('"yesterday" is the day before it was said, not before Juno was opened', () async {
    // Said on 28 September; Juno opened on 2 October.
    final item = parseInbox('[{"id":"t2","text":"12 taxi yesterday","at":"2026-09-28T19:40:00"}]').single;
    final row = (await inboxToEntry(item, categories: cats, accounts: accts, rates: const {}))!;
    expect(row.occurredOn.value, '2026-09-27');
    final today = parseInbox('[{"id":"t3","text":"5 coffee today","at":"2026-09-28T08:00:00"}]').single;
    expect(
      (await inboxToEntry(today, categories: cats, accounts: accts, rates: const {}))!.occurredOn.value,
      '2026-09-28',
    );
  });

  test('LBP with no LBP account converts instead of being read as dollars', () async {
    final item = parseInbox('[{"id":"l1","amount":179000,"currency":"LBP","category":"Transport"}]').single;
    final row = (await inboxToEntry(item, categories: cats, accounts: accts, rates: const {'LBP': 89500}))!;
    expect(row.amountCents.value, 200); // $2.00 in the USD account
    expect(row.note.value, contains('LBP 179,000'));
  });

  test('no amount → nothing is saved', () async {
    final item = parseInbox('[{"id":"n1","category":"Coffee"}]').single;
    expect(await inboxToEntry(item, categories: cats, accounts: accts, rates: const {}), isNull);
  });

  test('importing the same id twice adds one row', () async {
    final item = parseInbox('[{"id":"dup","amount":3}]').single;
    final l = Ledger(db);
    for (var i = 0; i < 2; i++) {
      final exists = await (db.select(db.transactions)..where((t) => t.id.equals('dup'))).getSingleOrNull();
      if (exists == null) {
        await l.addTransaction((await inboxToEntry(item, categories: cats, accounts: accts, rates: const {}))!);
      }
    }
    expect((await l.transactions(const TxQuery())).length, 1);
    expect(Day.today(), isNotEmpty);
  });
}
