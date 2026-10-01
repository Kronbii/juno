import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/sync/sync_engine.dart';

import 'support/fake_remote.dart';

void main() {
  test('pulls every row even when a page boundary splits rows sharing one server timestamp', () async {
    final remote = FakeRemote();
    final a = AppDatabase.memory(NativeDatabase.memory());
    final b = AppDatabase.memory(NativeDatabase.memory());
    final la = Ledger(a);
    // 300 rows in one push, then 700 more: pages of 500 straddle groups.
    for (final n in [300, 700]) {
      await la.commitImport('batch-$n.csv', [
        for (var i = 0; i < n; i++)
          TransactionsCompanion.insert(
            type: TxType.expense,
            scope: Scope.personal,
            amountCents: i + 1,
            accountId: seedId('acct:checking'),
            occurredOn: Day.today(),
          ),
      ]);
      await SyncCore(a, remote).run();
    }
    await SyncCore(b, remote).run();
    final onA = await a.customSelect('SELECT COUNT(*) AS n FROM transactions').getSingle();
    final onB = await b.customSelect('SELECT COUNT(*) AS n FROM transactions').getSingle();
    expect(onA.read<int>('n'), 1000);
    expect(onB.read<int>('n'), 1000, reason: 'rows were skipped at a page boundary');
    await a.close();
    await b.close();
  });
}
