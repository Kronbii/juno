import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/sync/sync_engine.dart';

/// An in-memory stand-in for Supabase: rows keyed by (table, id), stamped
/// with a monotonically increasing server_updated_at like the SQL trigger.
class FakeRemote implements SyncRemote {
  final Map<String, Map<String, Map<String, dynamic>>> tables = {};
  var _clock = 0;

  @override
  String? get userId => 'user-1';

  @override
  Future<void> upsert(String table, List<Map<String, dynamic>> rows) async {
    final t = tables.putIfAbsent(table, () => {});
    for (final r in rows) {
      _clock++;
      t[r['id'] as String] = {
        ...r,
        'server_updated_at': '2030-01-01T00:00:${_clock.toString().padLeft(6, '0')}Z',
      };
    }
  }

  @override
  Future<List<Map<String, dynamic>>> changedSince(String table, String? cursor, int limit) async {
    final rows =
        (tables[table]?.values ?? const <Map<String, dynamic>>[])
            .where((r) => cursor == null || (r['server_updated_at'] as String).compareTo(cursor) > 0)
            .toList()
          ..sort((a, b) => (a['server_updated_at'] as String).compareTo(b['server_updated_at'] as String));
    return rows.take(limit).toList();
  }
}

void main() {
  test('two devices converge; newer edit wins; deletes propagate', () async {
    final remote = FakeRemote();
    final a = AppDatabase.memory(NativeDatabase.memory());
    final b = AppDatabase.memory(NativeDatabase.memory());
    final la = Ledger(a);
    final lb = Ledger(b);

    // Device A logs an expense and syncs.
    final id = await la.addTransaction(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: Scope.household,
        amountCents: 5420,
        accountId: seedId('acct:checking'),
        occurredOn: Day.today(),
        note: const Value('Spinneys'),
      ),
    );
    await SyncCore(a, remote).run();
    expect(remote.tables['transactions']!.containsKey(id), isTrue);

    // Device B syncs: same seeded categories (no duplicates) plus A's entry.
    await SyncCore(b, remote).run();
    final bCats = await b.select(b.categories).get();
    final aCats = await a.select(a.categories).get();
    expect(bCats.length, aCats.length);
    final onB = await lb.transactions(const TxQuery());
    expect(onB.single.note, 'Spinneys');
    expect(onB.single.dirty, isFalse);

    // B edits later than A → B's edit wins on both.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await lb.updateTransaction(id, const TransactionsCompanion(note: Value('Spinneys Achrafieh')));
    await SyncCore(b, remote).run();
    await SyncCore(a, remote).run();
    expect((await la.transactions(const TxQuery())).single.note, 'Spinneys Achrafieh');

    // A stale remote copy never overwrites a newer local row.
    final stale = Map<String, dynamic>.from(remote.tables['transactions']![id]!)
      ..['note'] = 'old'
      ..['updated_at'] = '2000-01-01T00:00:00.000Z';
    final info = a.allTables.firstWhere((t) => t.actualTableName == 'transactions');
    await SyncCore(a, remote).mergeRow('transactions', {for (final c in info.$columns) c.name: c}, stale);
    expect((await la.transactions(const TxQuery())).single.note, 'Spinneys Achrafieh');

    // A deletes → gone on B after sync.
    await la.deleteTransaction(id);
    await SyncCore(a, remote).run();
    await SyncCore(b, remote).run();
    expect(await lb.transactions(const TxQuery()), isEmpty);

    await a.close();
    await b.close();
  });
}
