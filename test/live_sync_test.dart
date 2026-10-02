// End-to-end sync against a real Supabase project (network, real auth).
//   JUNO_LIVE_EMAIL=… JUNO_LIVE_PASSWORD=… flutter test test/live_sync_test.dart --run-skipped
// Reads URL/key from supabase.json. Tagged so normal runs skip it.
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/attachments/attachment_store.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/features/assistant/assistant.dart';
import 'package:juno/features/assistant/assistant_tools.dart';
import 'package:juno/features/plan/recurrence.dart' show occurrenceId;
import 'package:juno/features/settings/balance_check.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('two local databases converge through Supabase', () async {
    SharedPreferences.setMockInitialValues({});
    final cfg = jsonDecode(File('supabase.json').readAsStringSync()) as Map<String, dynamic>;
    final email = Platform.environment['JUNO_LIVE_EMAIL']!;
    final password = Platform.environment['JUNO_LIVE_PASSWORD']!;

    Future<SupabaseClient> client() async {
      final c = SupabaseClient(
        cfg['SUPABASE_URL'] as String,
        cfg['SUPABASE_ANON_KEY'] as String,
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      );
      await c.auth.signInWithPassword(email: email, password: password);
      return c;
    }

    AttachmentStore.directory = Directory.systemTemp.createTempSync('juno-live');
    final ca = await client();
    final cb = await client();
    final a = AppDatabase.memory(NativeDatabase.memory());
    final b = AppDatabase.memory(NativeDatabase.memory());
    final la = Ledger(a);
    final lb = Ledger(b);

    final id = await la.addTransaction(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.household,
        amountCents: 4321,
        accountId: seedId('acct:checking'),
        occurredOn: Day.today(),
        note: const Value('live sync test'),
        tags: const Value(',test,'),
      ),
    );
    await SyncCore(a, SupabaseRemote(ca)).run();
    await SyncCore(b, SupabaseRemote(cb)).run();

    final onB = await lb.transactions(const TxQuery());
    expect(onB.single.id, id);
    expect(onB.single.note, 'live sync test');
    expect(onB.single.tags, ',test,');
    expect((await b.select(b.categories).get()).length, (await a.select(a.categories).get()).length);

    // Edit on B, delete on A later: both converge on deleted.
    await lb.updateTransaction(id, const TransactionsCompanion(note: Value('edited on B')));
    await SyncCore(b, SupabaseRemote(cb)).run();
    await SyncCore(a, SupabaseRemote(ca)).run();
    expect((await la.transactions(const TxQuery())).single.note, 'edited on B');

    // Receipt round-trip through Storage.
    final storeA = AttachmentStore(la);
    await storeA.save(
      id,
      PendingFile(name: 'r.png', mime: 'image/png', bytes: Uint8List.fromList(List.filled(64, 7))),
    );
    await SyncCore(a, SupabaseRemote(ca)).run();
    await storeA.sync(ca);
    await SyncCore(a, SupabaseRemote(ca)).run();
    await SyncCore(b, SupabaseRemote(cb)).run();
    final att = (await b.select(b.attachments).get()).single;
    // Both test "devices" share one folder; remove the file so B must fetch
    // it from Storage like a real second device.
    final f = await AttachmentStore.fileFor(att);
    await f.delete();
    await AttachmentStore(lb).sync(cb);
    expect(f.existsSync(), isTrue, reason: 'receipt not downloaded on B');
    expect(f.lengthSync(), 64);

    // Server-side LWW: B edits first but syncs last; A's newer edit must win.
    await lb.updateTransaction(id, const TransactionsCompanion(note: Value('older edit on B')));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await la.updateTransaction(id, const TransactionsCompanion(note: Value('newer edit on A')));
    await SyncCore(a, SupabaseRemote(ca)).run();
    await SyncCore(b, SupabaseRemote(cb)).run();
    await SyncCore(a, SupabaseRemote(ca)).run();
    expect((await la.transactions(const TxQuery())).single.note, 'newer edit on A');
    expect((await lb.transactions(const TxQuery())).single.note, 'newer edit on A');

    // Paging: 600 rows in one push share a server timestamp; all must arrive.
    await la.commitImport('bulk.csv', [
      for (var i = 0; i < 600; i++)
        TransactionsCompanion.insert(
          type: TxType.expense,
          scope: Scope.personal,
          amountCents: i + 1,
          accountId: seedId('acct:checking'),
          occurredOn: Day.today(),
        ),
    ]);
    await SyncCore(a, SupabaseRemote(ca)).run();
    await SyncCore(b, SupabaseRemote(cb)).run();
    expect((await lb.transactions(const TxQuery())).length, 601);
    final batch = (await la.watchImports().first).single;
    await la.undoImport(batch.id);
    await SyncCore(a, SupabaseRemote(ca)).run();
    await SyncCore(b, SupabaseRemote(cb)).run();
    expect((await lb.transactions(const TxQuery())).length, 1);

    await la.deleteTransaction(id);
    await SyncCore(a, SupabaseRemote(ca)).run();
    await SyncCore(b, SupabaseRemote(cb)).run();
    expect(await lb.transactions(const TxQuery()), isEmpty);

    // v4–v6 write paths through the real server: a "For" entry with person
    // tags, both balance-check fixes, and an assistant draft logged then
    // undone.
    final forKids = await la.addTransaction(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.household,
        amountCents: 4801,
        accountId: seedId('acct:checking'),
        occurredOn: Day.today(),
        tags: Value(EntryTags.store(['@karim', '@lea'])),
      ),
    );
    final cash = await (a.select(a.accounts)..where((x) => x.id.equals(seedId('acct:cash')))).getSingle();
    final chk = await (a.select(a.accounts)..where((x) => x.id.equals(seedId('acct:checking')))).getSingle();
    final balA = await la.watchBalances().first;
    await applyBalanceCheck(la, cash, actual: balA[cash.id]! - 750, current: balA[cash.id]!, fix: BalanceFix.entry);
    await applyBalanceCheck(la, chk, actual: balA[chk.id]! + 10000, current: balA[chk.id]!, fix: BalanceFix.opening);
    final tools = AssistantTools(la);
    await tools.run('draft_entry', {'amount': 3, 'note': 'live draft'});
    final draft = tools.takeDrafts().single;
    final chat = Assistant(AiAssist(await SharedPreferences.getInstance()), la);
    final drafted = await chat.log(draft);
    await SyncCore(a, SupabaseRemote(ca)).run();
    await SyncCore(b, SupabaseRemote(cb)).run();
    await chat.unlog(draft);
    await SyncCore(a, SupabaseRemote(ca)).run();
    await SyncCore(b, SupabaseRemote(cb)).run();
    final rowsB = {for (final t in await b.select(b.transactions).get()) t.id: t};
    expect(EntryTags.parse(rowsB[forKids]!.tags), ['@karim', '@lea']);
    expect(rowsB[drafted]!.deletedAt, isNotNull, reason: 'Undo reached the other device');
    expect(rowsB.values.where((t) => t.note == 'Balance check' && t.deletedAt == null).length, 1);
    expect(await lb.watchBalances().first, await la.watchBalances().first, reason: 'balances agree after the checks');

    // A bill posting the server already has is never replaced by another
    // device's stale copy (insert-only push).
    final ruleId = newId(); // the server's column is a uuid
    final occ = occurrenceId(ruleId, Day.today());
    TransactionsCompanion posting(int cents) => TransactionsCompanion.insert(
      id: Value(occ),
      type: TxType.expense,
      scope: Scope.personal,
      amountCents: cents,
      accountId: seedId('acct:checking'),
      occurredOn: Day.today(),
      recurringId: Value(ruleId),
      createdAt: Value(seedStamp),
      updatedAt: Value(seedStamp),
    );
    await a.into(a.transactions).insert(posting(110000));
    await SyncCore(a, SupabaseRemote(ca)).run();
    await b.into(b.transactions).insert(posting(100000), mode: InsertMode.insertOrReplace);
    await SyncCore(b, SupabaseRemote(cb)).run();
    for (final db in [a, b]) {
      await SyncCore(db, SupabaseRemote(db == a ? ca : cb)).run();
      final t = await (db.select(db.transactions)..where((x) => x.id.equals(occ))).getSingle();
      expect(t.amountCents, 110000, reason: 'the server’s first copy wins');
    }

    // Leave nothing behind in Storage: the test user's rows go with the
    // user, but files don't.
    final mine = ca.auth.currentUser!.id;
    final left = await ca.storage.from(AttachmentStore.bucket).list(path: mine);
    if (left.isNotEmpty) {
      await ca.storage.from(AttachmentStore.bucket).remove([for (final o in left) '$mine/${o.name}']);
    }

    await a.close();
    await b.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
