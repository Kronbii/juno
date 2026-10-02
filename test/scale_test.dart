// Years of data: the queries that run on every save, and every sync, stay
// fast — and an existing database gains the indexes they need on upgrade.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/features/smart/advisor.dart';

import 'support/fake_remote.dart';
import 'support/heavy_world.dart';

Future<int> ms(Future<void> Function() f) async {
  final sw = Stopwatch()..start();
  await f();
  return sw.elapsedMilliseconds;
}

void main() {
  test(
    '20,000 entries: balances, a save, the split check and suggestions stay fast',
    () async {
      final db = AppDatabase.memory(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();
      await heavyWorld(db, history: false);
      final ledger = Ledger(db);
      await ledger.watchBalances(asOf: '2026-10-01').first; // warm up
      // A new date: a fresh query, not drift's cached stream.
      final balances = await ms(() => ledger.watchBalances(asOf: '2026-10-02').first);
      final heal = await ms(() => SyncCore(db, FakeRemote()).healSplits());
      final history = await ledger.transactions(const TxQuery(from: '2026-04-01'));
      final anomalies = await ms(() async => detectAnomalies(history: history, categoryNames: const {}));
      final subs = await ms(() async => detectSubscriptions(history, const []));
      final ideas = anomalies + subs;
      // ignore: avoid_print, the numbers are the point
      print(
        '20k entries: balances ${balances}ms · split check ${heal}ms · '
        '${history.length} entries in six months: anomalies ${anomalies}ms, subscriptions ${subs}ms',
      );
      expect(balances, lessThan(80));
      expect(heal, lessThan(150));
      expect(ideas, lessThan(600));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('upgrading a version-5 database adds the new indexes and keeps the data', () async {
    final dir = Directory.systemTemp.createTempSync('juno-mig');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/juno.sqlite');
    final v5 = AppDatabase.memory(NativeDatabase(file));
    await v5.customSelect('SELECT 1').get();
    for (final i in ['tx_account_day', 'tx_to_account', 'tx_split']) {
      await v5.customStatement('DROP INDEX $i');
    }
    await v5.customStatement('PRAGMA user_version = 5');
    final before = (await v5.select(v5.accounts).get()).length;
    await v5.close();

    final db = AppDatabase.memory(NativeDatabase(file));
    addTearDown(db.close);
    final names = (await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'index'").get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(names, containsAll(['tx_account_day', 'tx_to_account', 'tx_split']));
    expect((await db.select(db.accounts).get()).length, before);
    final plan = await db
        .customSelect(
          "EXPLAIN QUERY PLAN SELECT SUM(amount_cents) FROM transactions WHERE account_id = 'x' AND occurred_on <= '2026-10-02'",
        )
        .get();
    expect(plan.map((r) => r.data['detail']).join(' '), contains('tx_account_day'));
  });
}
