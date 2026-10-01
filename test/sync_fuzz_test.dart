// Sync fuzz: three devices make random edits, deletes and restores to shared
// rows, syncing at random moments (some go "offline" for a while). After a
// final round everyone must hold identical data, no row ever created may be
// missing anywhere, and each row must equal its most recent write.
import 'dart:math';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/sync/sync_engine.dart';

import 'support/fake_remote.dart';

/// Canonical content of every synced table (minus local-only columns).
Future<Map<String, Map<String, Map<String, Object?>>>> dump(AppDatabase db) async {
  final out = <String, Map<String, Map<String, Object?>>>{};
  for (final t in SyncCore.tables) {
    final rows = await db.customSelect('SELECT * FROM $t').get();
    out[t] = {
      for (final r in rows)
        r.data['id'] as String: {
          for (final e in r.data.entries)
            if (e.key != 'dirty' && e.key != 'user_id')
              e.key: e.value is String && (e.key.endsWith('_at'))
                  ? DateTime.parse(e.value! as String).toUtc().microsecondsSinceEpoch
                  : e.value,
        },
    };
  }
  return out;
}

Future<void> trySync(AppDatabase db, FakeRemote remote) async {
  try {
    await SyncCore(db, remote).run();
  } on Exception {
    // Offline: the next round must catch up.
  }
}

void main() {
  for (final seed in [11, 23, 57, 101]) {
    test('three devices converge under random edits and outages (seed $seed)', () async {
      final rnd = Random(seed);
      final remote = FakeRemote();
      final devices = [for (var i = 0; i < 3; i++) AppDatabase.memory(NativeDatabase.memory())];
      final ledgers = [for (final d in devices) Ledger(d)];
      final created = <String>{};
      // The last write each device made to each row, in wall-clock order.
      final lastWrite = <String, (DateTime, String?)>{}; // id -> (at, note) ; null note = deleted

      Future<void> step(int dev) async {
        final l = ledgers[dev];
        final live = await l.transactions(const TxQuery());
        final all = await devices[dev].select(devices[dev].transactions).get();
        final op = rnd.nextInt(10);
        // Keep timestamps strictly increasing across devices.
        await Future<void>.delayed(const Duration(microseconds: 200));
        if (op < 4 || all.isEmpty) {
          final note = 'n${rnd.nextInt(1 << 20)}';
          final id = await l.addTransaction(
            TransactionsCompanion.insert(
              type: TxType.expense,
              scope: Scope.personal,
              amountCents: rnd.nextInt(9999) + 1,
              accountId: seedId('acct:checking'),
              occurredOn: Day.today(),
              note: Value(note),
            ),
          );
          created.add(id);
          lastWrite[id] = (DateTime.now(), note);
        } else if (op < 7 && live.isNotEmpty) {
          final t = live[rnd.nextInt(live.length)];
          final note = 'e${rnd.nextInt(1 << 20)}';
          await l.updateTransaction(t.id, TransactionsCompanion(note: Value(note)));
          lastWrite[t.id] = (DateTime.now(), note);
        } else if (op < 9 && live.isNotEmpty) {
          final t = live[rnd.nextInt(live.length)];
          await l.deleteTransaction(t.id);
          lastWrite[t.id] = (DateTime.now(), null);
        } else {
          final dead = all.where((t) => t.deletedAt != null).toList();
          if (dead.isNotEmpty) {
            final t = dead[rnd.nextInt(dead.length)];
            await l.restoreTransaction(t.id);
            lastWrite[t.id] = (DateTime.now(), t.note);
          }
        }
        // Edits to shared seeded rows too (category names) — concurrent LWW.
        if (rnd.nextDouble() < 0.15) {
          await devices[dev].customStatement('SELECT 1');
          await l.upsertCategory(
            CategoriesCompanion(
              id: Value(seedId('cat:Coffee')),
              name: Value('Coffee ${rnd.nextInt(1000)}'),
              icon: const Value('coffee'),
              colorIndex: const Value(4),
              kind: const Value(CategoryKind.expense),
            ),
          );
        }
      }

      for (var round = 0; round < 120; round++) {
        final dev = rnd.nextInt(3);
        await step(dev);
        remote.down = rnd.nextDouble() < 0.1;
        if (rnd.nextDouble() < 0.4) await trySync(devices[rnd.nextInt(3)], remote);
      }
      remote.down = false;
      for (var pass = 0; pass < 2; pass++) {
        for (final d in devices) {
          await SyncCore(d, remote).run();
        }
      }

      final dumps = [for (final d in devices) await dump(d)];
      for (final t in SyncCore.tables) {
        expect(dumps[1][t], dumps[0][t], reason: 'device 1 differs on $t');
        expect(dumps[2][t], dumps[0][t], reason: 'device 2 differs on $t');
      }
      final ids = dumps[0]['transactions']!.keys.toSet();
      expect(ids.containsAll(created), isTrue, reason: 'a created row vanished');

      // Each row holds its latest write (LWW by wall clock).
      final rows = await devices[0].select(devices[0].transactions).get();
      for (final r in rows) {
        final w = lastWrite[r.id]!;
        if (w.$2 == null) {
          expect(r.deletedAt, isNotNull, reason: '${r.id} should be deleted');
        } else {
          expect(r.deletedAt, isNull, reason: '${r.id} should be live');
          expect(r.note, w.$2, reason: '${r.id} lost its latest edit');
        }
      }
      // Nothing left unpushed anywhere.
      for (final d in devices) {
        final dirty = await d.customSelect('SELECT COUNT(*) AS n FROM transactions WHERE dirty = 1').getSingle();
        expect(dirty.read<int>('n'), 0);
      }
      for (final d in devices) {
        await d.close();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
