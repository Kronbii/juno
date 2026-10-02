// Reconciliation: build random ledgers through the real write path, then
// recompute every dashboard figure independently from raw SQL and compare.
// The oracle below shares no code with the app's analytics.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/insights/analytics.dart';

import 'support/world.dart';

void main() {
  for (final seed in seeds([1, 2, 3, 42, 777])) {
    test('dashboard figures reconcile with raw SQL (seed $seed)', () async {
      final w = await buildWorld(seed);
      final now = DateTime.now();
      for (var back = 0; back < 8; back++) {
        final m = DateTime(now.year, now.month - back);
        final from = Day.firstOfMonth(m);
        final to = Day.lastOfMonth(m);
        for (final scope in [null, Scope.personal, Scope.household]) {
          final txs = await w.ledger.transactions(TxQuery(from: from, to: to, scope: scope));
          final s = PeriodSummary.of(txs);
          final scopeSql = scope == null ? '1=1' : "scope = '${scope.name}'";
          final range = "occurred_on BETWEEN '$from' AND '$to' AND $scopeSql";
          expect(s.expense, await sqlSum(w.db, "type = 'expense' AND $range"), reason: 'expense $from $scope');
          expect(s.income, await sqlSum(w.db, "type = 'income' AND $range"), reason: 'income $from $scope');
          // Internal consistency: parts add up to the whole.
          expect(s.byScope.values.fold(0, (a, b) => a + b), s.expense);
          expect(s.byCategory.values.fold(0, (a, b) => a + b), s.expense);
          for (final e in s.byCategory.entries) {
            final where = e.key == null ? 'category_id IS NULL' : "category_id = '${e.key}'";
            expect(e.value, await sqlSum(w.db, "type = 'expense' AND $range AND $where"), reason: 'cat ${e.key}');
          }
          // Transfers never count.
          expect(
            txs
                .where((t) => t.type == TxType.transfer)
                .every((t) => !s.byCategory.containsKey(t.categoryId) || t.categoryId == null),
            isTrue,
          );
        }
        // Budgets against SQL.
        final monthTx = await w.ledger.transactions(TxQuery(from: from, to: to));
        final budgets = await w.ledger.watchBudgets().first;
        for (final st in budgetStatuses(budgets, monthTx)) {
          final b = st.budget;
          final where = [
            "type = 'expense'",
            "occurred_on BETWEEN '$from' AND '$to'",
            if (b.categoryId != null) "category_id = '${b.categoryId}'",
            if (b.scope != null) "scope = '${b.scope!.name}'",
          ].join(' AND ');
          expect(st.spent, await sqlSum(w.db, where), reason: 'budget ${b.id} $from');
        }
      }

      // Balances: replay every live row by hand, in each account's currency.
      final live = await (w.db.select(w.db.transactions)..where((t) => t.deletedAt.isNull())).get();
      final expected = {for (final a in w.accounts) a.id: a.openingBalanceCents};
      for (final t in live) {
        switch (t.type) {
          case TxType.income:
            expected[t.accountId] = expected[t.accountId]! + t.amountCents;
          case TxType.expense:
            expected[t.accountId] = expected[t.accountId]! - t.amountCents;
          case TxType.transfer:
            expected[t.accountId] = expected[t.accountId]! - t.amountCents;
            expected[t.toAccountId!] = expected[t.toAccountId!]! + (t.toAmountCents ?? t.amountCents);
        }
      }
      final balances = await w.ledger.watchBalances().first;
      for (final a in w.accounts) {
        expect(balances[a.id], expected[a.id], reason: 'balance ${a.name}');
      }

      // Net worth: this month's point equals today's balances at today's
      // rates (entries dated in the future excluded by construction).
      final rates = await w.ledger.rates();
      final series = netWorthSeries(
        accounts: w.accounts,
        txs: live,
        perUsd: rates,
        last: DateTime(now.year, now.month),
      );
      final nowWorth = w.accounts.fold(0, (s, a) => s + Fx.toUsd(balances[a.id]!, a.currency, rates));
      expect(series.last.$2, nowWorth);

      // Every stored USD value matches its own rate at the time (LBP) or is
      // the amount itself (USD).
      for (final t in live) {
        if (t.currency == 'USD') {
          expect(t.baseCents, isNull, reason: 'USD row with base ${t.id}');
        } else {
          expect(t.baseCents, (t.amountCents / 89500).round(), reason: 'LBP row ${t.id}');
        }
        final acct = w.accounts.firstWhere((a) => a.id == t.accountId);
        expect(t.currency, acct.currency, reason: 'currency follows account ${t.id}');
        if (t.type == TxType.transfer) {
          final dest = w.accounts.firstWhere((a) => a.id == t.toAccountId);
          if (dest.currency == acct.currency) {
            expect(t.toAmountCents, isNull);
          } else {
            expect(t.toAmountCents, Fx.convert(t.amountCents, acct.currency, dest.currency, rates));
          }
          expect(t.categoryId, isNull, reason: 'transfers are uncategorised');
        }
      }
      await w.db.close();
    });
  }
}
