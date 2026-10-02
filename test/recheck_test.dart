// Re-check after v4–v6: every figure the new features show (cash flow
// forecast, money health, "for whom", the week so far, the assistant's
// lookups) recomputed by an independent oracle — raw SQL or plain date
// stepping — over random worlds built through the real write path.
import 'dart:math';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/assistant/assistant_tools.dart';
import 'package:juno/features/home/weekly_read.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/insights/health.dart';
import 'package:juno/features/plan/forecast.dart';

import 'support/world.dart';

const rate = 89500.0;

/// Balance of each account by replaying live rows up to today, straight
/// from the table.
Future<Map<String, int>> sqlBalances(AppDatabase db, String today) async {
  final accounts = await db.customSelect('SELECT id, opening_balance_cents AS o FROM accounts').get();
  final out = {for (final a in accounts) a.read<String>('id'): a.read<int>('o')};
  final rows = await db
      .customSelect(
        'SELECT type, account_id, to_account_id, amount_cents, to_amount_cents FROM transactions '
        "WHERE deleted_at IS NULL AND occurred_on <= '$today'",
      )
      .get();
  for (final r in rows) {
    final from = r.read<String>('account_id');
    final amount = r.read<int>('amount_cents');
    switch (r.read<String>('type')) {
      case 'income':
        out[from] = out[from]! + amount;
      case 'expense':
        out[from] = out[from]! - amount;
      case 'transfer':
        final to = r.read<String>('to_account_id');
        out[from] = out[from]! - amount;
        out[to] = out[to]! + (r.readNullable<int>('to_amount_cents') ?? amount);
    }
  }
  return out;
}

int usdOf(int cents, String currency) => currency == 'USD' ? cents : (cents / rate).round();

/// Due dates of a rule, stepped by hand from its next due date: monthly and
/// yearly land on the anchor's day, clamped to short months; weekly adds
/// whole weeks on the calendar.
List<String> oracleDates(RecurringRule r, String after, String until) {
  final anchor = Day.parse(r.anchorDate);
  final start = Day.parse(r.nextDue);
  final out = <String>[];
  for (var k = 0; k < 2000; k++) {
    final DateTime d;
    if (k == 0) {
      d = start;
    } else {
      switch (r.frequency) {
        case Frequency.weekly:
          d = DateTime(start.year, start.month, start.day + 7 * r.interval * k);
        case Frequency.monthly:
          final m = DateTime(start.year, start.month + r.interval * k);
          d = DateTime(m.year, m.month, min(anchor.day, DateTime(m.year, m.month + 1, 0).day));
        case Frequency.yearly:
          final y = start.year + r.interval * k;
          d = DateTime(y, anchor.month, min(anchor.day, DateTime(y, anchor.month + 1, 0).day));
      }
    }
    final s = Day.of(d);
    if (s.compareTo(until) > 0) break;
    if (r.endDate != null && s.compareTo(r.endDate!) > 0) break;
    if (s.compareTo(after) > 0) out.add(s);
  }
  return out;
}

/// Adds random recurring rules (month-end anchors, intervals, ended and
/// paused ones, on every account) and person tags on random household
/// expenses.
Future<void> enrich(World w, int seed, DateTime now) async {
  final rnd = Random(seed * 31 + 7);
  for (var i = 0; i < 14; i++) {
    final a = w.accounts[rnd.nextInt(w.accounts.length)];
    final freq = Frequency.values[rnd.nextInt(3)];
    final anchor = DateTime(now.year, now.month - rnd.nextInt(14), [1, 15, 28, 29, 30, 31][rnd.nextInt(6)]);
    final type = rnd.nextDouble() < 0.25 ? TxType.income : TxType.expense;
    await w.db
        .into(w.db.recurringRules)
        .insert(
          RecurringRulesCompanion.insert(
            type: type,
            scope: rnd.nextBool() ? Scope.personal : Scope.household,
            amountCents: a.currency == 'LBP' ? (rnd.nextInt(50) + 1) * 10000000 : rnd.nextInt(200000) + 100,
            accountId: a.id,
            note: Value('rule $i'),
            frequency: freq,
            interval: Value(rnd.nextInt(3) + 1),
            anchorDate: Day.of(anchor),
            // Next due somewhere from last month to two months ahead.
            nextDue: Day.of(DateTime(now.year, now.month - 1 + rnd.nextInt(4), anchor.day)),
            endDate: Value(
              rnd.nextDouble() < 0.2 ? Day.of(DateTime(now.year, now.month, now.day + (rnd.nextInt(50)))) : null,
            ),
            active: Value(rnd.nextDouble() > 0.1),
          ),
        );
  }
  final people = ['@mom', '@karim', '@lea', '@grandpa'];
  final expenses = await (w.db.select(
    w.db.transactions,
  )..where((t) => t.type.equalsValue(TxType.expense) & t.deletedAt.isNull())).get();
  for (final t in expenses.where((_) => rnd.nextDouble() < 0.3)) {
    final picked = {for (var k = 0; k < rnd.nextInt(3) + 1; k++) people[rnd.nextInt(people.length)]};
    await w.ledger.updateTransaction(
      t.id,
      TransactionsCompanion(tags: Value(EntryTags.store([...EntryTags.parse(t.tags), ...picked]))),
    );
  }
}

void main() {
  for (final seed in seeds([1, 2, 3, 42, 777])) {
    test('new features reconcile with independent oracles (seed $seed)', () async {
      final w = await buildWorld(seed);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final todayStr = Day.of(today);
      await enrich(w, seed, now);
      final db = w.db;
      final accounts = await db.select(db.accounts).get();
      final rules = await db.select(db.recurringRules).get();
      final rates = await w.ledger.rates();
      final balances = await w.ledger.watchBalances().first;
      final sqlBal = await sqlBalances(db, todayStr);
      expect(balances, sqlBal, reason: 'balances');

      // ---------------------------------------------------------- forecast
      final recent = await w.ledger.transactions(
        TxQuery(from: Day.of(DateTime(today.year, today.month, today.day - 90)), to: todayStr),
      );
      final ahead = await w.ledger.transactions(
        TxQuery(
          from: Day.of(DateTime(today.year, today.month, today.day + 1)),
          to: Day.of(DateTime(today.year, today.month, today.day + 60)),
        ),
      );
      final f = forecastCash(
        accounts: accounts,
        balances: balances,
        rules: rules,
        recent: recent,
        ahead: ahead,
        rates: rates,
        ruleLabels: const {},
        now: now,
      );
      final spendable = {
        for (final a in accounts)
          if (!a.archived && a.deletedAt == null && a.kind != AccountKind.savings) a.id: a,
      };
      expect(f.start, spendable.values.fold(0, (s, a) => s + usdOf(sqlBal[a.id]!, a.currency)), reason: 'start');

      final paceFrom = Day.of(DateTime(today.year, today.month, today.day - 90));
      final firstRow = await db
          .customSelect(
            "SELECT MIN(occurred_on) AS d FROM transactions WHERE deleted_at IS NULL AND occurred_on BETWEEN '$paceFrom' AND '$todayStr'",
          )
          .getSingle();
      final first = firstRow.readNullable<String>('d');
      final from = first != null && first.compareTo(paceFrom) > 0 ? first : paceFrom;
      // Calendar days, counted on UTC dates so DST can't shorten a day.
      final f0 = Day.parse(from);
      final paceDays = first == null
          ? 0
          : DateTime.utc(today.year, today.month, today.day).difference(DateTime.utc(f0.year, f0.month, f0.day)).inDays;
      final ids = spendable.keys.map((k) => "'$k'").join(',');
      final unplanned = await sqlSum(
        db,
        "type = 'expense' AND recurring_id IS NULL AND account_id IN ($ids) AND occurred_on >= '$from' AND occurred_on < '$todayStr'",
      );
      expect(f.paceDays, paceDays);
      expect(f.dailyPace, paceDays == 0 ? 0 : (unplanned / paceDays).round(), reason: 'pace');

      final until = Day.of(DateTime(today.year, today.month, today.day + 60));
      final expectedEvents = <(String, int)>[
        for (final r in rules)
          if (r.active && r.type != TxType.transfer && spendable.containsKey(r.accountId))
            for (final d in oracleDates(r, todayStr, until))
              if (r.endDate == null || r.nextDue.compareTo(r.endDate!) <= 0)
                (d, (r.type == TxType.income ? 1 : -1) * usdOf(r.amountCents, spendable[r.accountId]!.currency)),
        for (final t in ahead)
          if (t.type != TxType.transfer && spendable.containsKey(t.accountId))
            (t.occurredOn, t.type == TxType.income ? t.usd : -t.usd),
      ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
      final got = [for (final e in f.events) (e.day, e.usd)]
        ..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
      expect(expectedEvents, isNotEmpty, reason: 'the oracle must have something to check');
      expect(got, expectedEvents, reason: 'events');
      // The line is the start, plus each day's events, minus the pace.
      var running = f.start;
      for (var i = 1; i < f.series.length; i++) {
        final d = Day.of(f.series[i].$1);
        running += expectedEvents.where((e) => e.$1 == d).fold(0, (s, e) => s + e.$2) - f.dailyPace;
        expect(f.series[i].$2, running, reason: 'series day $i');
      }
      expect(f.series.length, 61);
      expect(f.lowest.$2, f.series.map((p) => p.$2).reduce(min));

      // ------------------------------------------------------ money health
      final hTxs = await w.ledger.transactions(
        TxQuery(
          from: Day.firstOfMonth(DateTime(now.year, now.month - 3)),
          to: Day.lastOfMonth(DateTime(now.year, now.month - 1)),
        ),
      );
      final h = moneyHealth(accounts: accounts, balances: balances, rules: rules, txs: hTxs, rates: rates, now: now);
      final hFrom = Day.firstOfMonth(DateTime(now.year, now.month - 3));
      final hTo = Day.lastOfMonth(DateTime(now.year, now.month - 1));
      final months =
          (await db
                  .customSelect(
                    'SELECT COUNT(DISTINCT substr(occurred_on, 1, 7)) AS n FROM transactions '
                    "WHERE deleted_at IS NULL AND occurred_on BETWEEN '$hFrom' AND '$hTo'",
                  )
                  .getSingle())
              .read<int>('n');
      expect(h.months, months);
      final range = "occurred_on BETWEEN '$hFrom' AND '$hTo'";
      expect(h.avgSpend, months == 0 ? 0 : (await sqlSum(db, "type = 'expense' AND $range") / months).round());
      expect(h.avgIncome, months == 0 ? 0 : (await sqlSum(db, "type = 'income' AND $range") / months).round());
      final live = accounts.where((a) => !a.archived && a.deletedAt == null);
      expect(h.net, live.fold(0, (s, a) => s + usdOf(sqlBal[a.id]!, a.currency)), reason: 'net');
      expect(
        h.cardDebt,
        live
            .where((a) => a.kind == AccountKind.credit)
            .fold(0, (s, a) => s + max(0, -usdOf(sqlBal[a.id]!, a.currency))),
      );
      var bills = 0.0;
      for (final r in rules.where((r) => r.active && r.type == TxType.expense)) {
        if (r.endDate != null && r.nextDue.compareTo(r.endDate!) > 0) continue;
        final cur = accounts.firstWhere((a) => a.id == r.accountId).currency;
        final perYear = {Frequency.weekly: 52, Frequency.monthly: 12, Frequency.yearly: 1}[r.frequency]!;
        bills += usdOf(r.amountCents, cur) * perYear / 12 / r.interval;
      }
      expect(h.monthlyBills, bills.round());

      // --------------------------------------------------------- for whom
      for (final back in [0, 1, 2]) {
        final m = DateTime(now.year, now.month - back);
        final txs = await w.ledger.transactions(TxQuery(from: Day.firstOfMonth(m), to: Day.lastOfMonth(m)));
        final p = spendByPerson(txs);
        final mRange = "occurred_on BETWEEN '${Day.firstOfMonth(m)}' AND '${Day.lastOfMonth(m)}'";
        final tagged = await sqlSum(db, "type = 'expense' AND $mRange AND tags LIKE '%,@%'");
        expect(p.people.fold(0, (s, x) => s + x.$2), tagged, reason: 'people add up ($m)');
        expect(
          p.unassigned,
          await sqlSum(db, "type = 'expense' AND $mRange AND scope = 'household' AND tags NOT LIKE '%,@%'"),
        );
        // Each person within a cent per shared entry of an exact split.
        for (final (tag, cents) in p.people) {
          final rows = await db
              .customSelect(
                'SELECT COALESCE(base_cents, amount_cents) AS v, tags FROM transactions '
                "WHERE deleted_at IS NULL AND type = 'expense' AND $mRange AND tags LIKE ?",
                variables: [Variable('%,$tag,%')],
              )
              .get();
          // Each row's share: its value over the number of people on it.
          var exact = 0.0;
          for (final r in rows) {
            final people = r.read<String>('tags').split(',').where((t) => t.startsWith('@') && t.length > 1).length;
            exact += r.read<int>('v') / people;
          }
          expect((cents - exact).abs(), lessThanOrEqualTo(rows.length), reason: '$tag $m');
        }
      }

      // ------------------------------------------------------ week so far
      final week = await w.ledger.transactions(
        TxQuery(
          from: Day.of(DateTime(today.year, today.month, today.day - (today.weekday - 1 + 7))),
          to: todayStr,
        ),
      );
      final wf = weekFacts(week, {for (final c in await db.select(db.categories).get()) c.id: c}, now);
      final monday = DateTime(today.year, today.month, today.day - (today.weekday - 1));
      expect(
        wf.spent,
        await sqlSum(db, "type = 'expense' AND occurred_on BETWEEN '${Day.of(monday)}' AND '$todayStr'"),
      );
      final lastMon = DateTime(monday.year, monday.month, monday.day - 7);
      final lastSame = DateTime(lastMon.year, lastMon.month, lastMon.day + (today.weekday - 1));
      expect(
        wf.lastWeek,
        await sqlSum(db, "type = 'expense' AND occurred_on BETWEEN '${Day.of(lastMon)}' AND '${Day.of(lastSame)}'"),
      );

      // ------------------------------------------------ assistant lookups
      final tools = AssistantTools(w.ledger, clock: () => now);
      for (final back in [0, 1, 5]) {
        final m = DateTime(now.year, now.month - back);
        final a = Day.firstOfMonth(m);
        final b = Day.lastOfMonth(m);
        for (final scope in [null, 'personal', 'household']) {
          final r = await tools.run('summary', {'from': a, 'to': b, 'scope': ?scope});
          final s = scope == null ? '' : " AND scope = '$scope'";
          final spent = await sqlSum(db, "type = 'expense' AND occurred_on BETWEEN '$a' AND '$b'$s");
          final income = await sqlSum(db, "type = 'income' AND occurred_on BETWEEN '$a' AND '$b'$s");
          expect(r['spent'], spent / 100, reason: 'tool spent $a $scope');
          expect(r['income'], income / 100);
          expect(r['net'], (income - spent) / 100);
        }
      }
      final cats = await db.select(db.categories).get();
      for (final c in cats.where((c) => c.kind == CategoryKind.expense).take(6)) {
        final r = await tools.run('category_spending', {
          'category': c.name,
          'from': Day.of(DateTime(today.year, today.month, today.day - 120)),
          'to': todayStr,
        });
        final ids = (await db.select(db.categories).get())
            .where(
              (k) =>
                  k.name.toLowerCase().contains(c.name.toLowerCase()) ||
                  c.name.toLowerCase().contains(k.name.toLowerCase()),
            )
            .map((k) => "'${k.id}'")
            .join(',');
        expect(
          r['spent'],
          await sqlSum(
                db,
                "type = 'expense' AND category_id IN ($ids) AND occurred_on BETWEEN '${Day.of(DateTime(today.year, today.month, today.day - 120))}' AND '$todayStr'",
              ) /
              100,
          reason: 'category ${c.name}',
        );
      }
      final found = await tools.run('find_entries', {'search': 'taxi', 'type': 'expense', 'limit': 5});
      final n =
          (await db
                  .customSelect(
                    "SELECT COUNT(*) AS n FROM transactions WHERE deleted_at IS NULL AND type = 'expense' "
                    "AND occurred_on <= '$todayStr' AND (instr(lower(note), 'taxi') > 0 OR instr(lower(merchant), 'taxi') > 0)",
                  )
                  .getSingle())
              .read<int>('n');
      expect(found['matches'], n);
      expect((found['entries'] as List).length, min(5, n));
      final acc = await tools.run('accounts', {});
      expect(acc['net_worth'], live.fold(0, (s, a) => s + usdOf(sqlBal[a.id]!, a.currency)) / 100);
      await db.close();
    });
  }
}
