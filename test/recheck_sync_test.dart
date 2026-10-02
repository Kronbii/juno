// Re-check after v4–v6: the new write paths (balance checks, entries logged
// from the assistant and undone, "For" person tags, entries adopted from the
// editor) go through sync like any other write, and two devices end up
// identical.
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/features/assistant/assistant.dart';
import 'package:juno/features/assistant/assistant_tools.dart';
import 'package:juno/features/settings/balance_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_remote.dart';

Future<Account> account(AppDatabase db, String id) =>
    (db.select(db.accounts)..where((a) => a.id.equals(id))).getSingle();

Future<void> sync(List<AppDatabase> dbs, FakeRemote remote) async {
  for (var pass = 0; pass < 2; pass++) {
    for (final d in dbs) {
      await SyncCore(d, remote).run();
    }
  }
}

/// Every synced table, minus local-only columns.
Future<Map<String, List<Map<String, Object?>>>> dump(AppDatabase db) async => {
  for (final t in SyncCore.tables)
    t: [
      for (final r in await db.customSelect('SELECT * FROM $t ORDER BY id').get())
        {
          for (final e in r.data.entries)
            if (e.key != 'dirty' && e.key != 'user_id') e.key: e.value,
        },
    ],
};

void main() {
  late FakeRemote remote;
  late AppDatabase a;
  late AppDatabase b;
  late Ledger la;
  late Ledger lb;

  setUp(() async {
    remote = FakeRemote();
    a = AppDatabase.memory(NativeDatabase.memory());
    b = AppDatabase.memory(NativeDatabase.memory());
    la = Ledger(a);
    lb = Ledger(b);
    await a.customSelect('SELECT 1').get();
    await b.customSelect('SELECT 1').get();
    await sync([a, b], remote);
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });

  test('balance checks (entry and starting balance) reach the other device', () async {
    final cash = await account(a, seedId('acct:cash'));
    final chk = await account(a, seedId('acct:checking'));
    await applyBalanceCheck(la, cash, actual: -2500, current: 0, fix: BalanceFix.entry);
    await applyBalanceCheck(la, chk, actual: 125000, current: 0, fix: BalanceFix.opening);
    await sync([a, b], remote);
    expect(await lb.watchBalances().first, await la.watchBalances().first);
    expect((await account(b, chk.id)).openingBalanceCents, 125000);
    final entry = await (b.select(b.transactions)..where((t) => t.note.equals('Balance check'))).getSingle();
    expect(EntryTags.parse(entry.tags), [adjustmentTag]);
    expect(await dump(b), await dump(a));
  });

  test('a balance check made from a stale sheet keeps the other device’s changes', () async {
    // Device A opens the check on Checking and holds that copy of the row.
    final stale = await account(a, seedId('acct:checking'));
    // Meanwhile device B renames the account and sets its starting balance.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await lb.upsertAccount(
      AccountsCompanion(
        id: Value(stale.id),
        name: const Value('Main account'),
        kind: Value(stale.kind),
        currency: Value(stale.currency),
        openingBalanceCents: const Value(50000),
      ),
    );
    await sync([b, a], remote);
    // A taps Fix: real balance $700, Juno now says $500 (B's opening).
    final current = (await la.watchBalances().first)[stale.id]!;
    expect(current, 50000);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await applyBalanceCheck(la, stale, actual: 70000, current: current, fix: BalanceFix.opening);
    await sync([a, b], remote);
    for (final db in [a, b]) {
      final acct = await account(db, stale.id);
      expect(acct.name, 'Main account', reason: 'the rename must survive');
      expect(acct.openingBalanceCents, 70000, reason: 'B’s 500 plus the 200 difference');
    }
  });

  test('assistant: logged and undone entries, person tags and adopted edits sync', () async {
    SharedPreferences.setMockInitialValues({'ai.key': 'sk'});
    var n = 0;
    final ai = AiAssist(
      await SharedPreferences.getInstance(),
      client: MockClient((_) async {
        n++;
        Map<String, Object> call(String id, Map<String, Object> args) => {
          'id': id,
          'type': 'function',
          'function': {'name': 'draft_entry', 'arguments': jsonEncode(args)},
        };
        final message = n == 1
            ? {
                'role': 'assistant',
                'content': null,
                'tool_calls': [
                  call('1', {'amount': 12, 'category': 'dining'}),
                  call('2', {'amount': 30, 'category': 'groceries'}),
                ],
              }
            : {'role': 'assistant', 'content': 'Ready.'};
        return http.Response(
          jsonEncode({
            'choices': [
              {'message': message},
            ],
          }),
          200,
        );
      }),
    );
    final chat = Assistant(ai, la);
    final line = await chat.ask('log 12 dinner and 30 groceries');
    expect(line.drafts.length, 2);
    final kept = await chat.log(line.drafts.first);
    final undone = await chat.log(line.drafts.last);
    await chat.unlog(line.drafts.last);
    // A household entry "For" two people.
    final forKids = await la.addTransaction(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.household,
        amountCents: 4801,
        accountId: seedId('acct:checking'),
        occurredOn: '2026-09-19',
        tags: Value(EntryTags.store(['@karim', '@lea', 'school'])),
      ),
    );
    await sync([a, b], remote);
    final onB = {for (final t in await b.select(b.transactions).get()) t.id: t};
    expect(onB[kept]!.deletedAt, isNull);
    expect(onB[undone]!.deletedAt, isNotNull, reason: 'Undo is a delete, and deletes sync');
    expect(EntryTags.parse(onB[forKids]!.tags), ['@karim', '@lea', 'school']);
    expect(await dump(b), await dump(a));

    // B edits the kept entry's people; A sees it.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await lb.updateTransaction(kept, TransactionsCompanion(tags: Value(EntryTags.store(['@mom']))));
    await sync([b, a], remote);
    final onA = await (a.select(a.transactions)..where((t) => t.id.equals(kept))).getSingle();
    expect(onA.tags, ',@mom,');
  });

  test('the assistant’s Undo after the entry synced removes it everywhere', () async {
    final tools = AssistantTools(la);
    await tools.run('draft_entry', {'amount': 9, 'note': 'Bakery'});
    final d = tools.takeDrafts().single;
    SharedPreferences.setMockInitialValues({});
    final chat = Assistant(AiAssist(await SharedPreferences.getInstance()), la);
    final id = await chat.log(d);
    await sync([a, b], remote);
    expect(await (b.select(b.transactions)..where((t) => t.id.equals(id))).getSingleOrNull(), isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await chat.unlog(d);
    await sync([a, b], remote);
    final onB = await (b.select(b.transactions)..where((t) => t.id.equals(id))).getSingle();
    expect(onB.deletedAt, isNotNull);
  });
}
