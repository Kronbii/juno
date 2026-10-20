import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/insights/analytics.dart';

import 'support/harness.dart';

void main() {
  TransactionsCompanion spend(Scope scope, int cents) => TransactionsCompanion.insert(
    type: TxType.expense,
    scope: scope,
    amountCents: cents,
    accountId: seedId('acct:cash'),
    categoryId: Value(seedId('cat:Gifts')),
    occurredOn: Day.today(),
  );

  testWidgets('home: Other joins the split once used, and the lens filters to it', (tester) async {
    final h = await boot(
      tester,
      demo: false,
      setup: (db) async {
        final l = Ledger(db);
        await l.addTransaction(spend(Scope.personal, 6000));
        await l.addTransaction(spend(Scope.household, 3000));
        await l.addTransaction(spend(Scope.other, 1000));
      },
    );
    await h.go('/home');
    expect(find.text('PERSONAL, HOUSEHOLD, OTHER'), findsOneWidget);
    expect(find.text('OTHER'), findsOneWidget);
    expect(find.text('10% of spend'), findsOneWidget);
    // Tapping Other in the split filters the app to it.
    await tester.tap(find.text('OTHER'));
    await h.settle();
    expect(find.textContaining('SPENT THIS MONTH · OTHER'), findsOneWidget);
    // The lens row scrolls to its Other chip, which is selected now.
    await tester.dragUntilVisible(find.text('Other'), find.byType(ListView).first, const Offset(-120, 0));
    expect(find.text('Other'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await h.dispose();
  });

  testWidgets('home: without Other spending the split stays two-way', (tester) async {
    final h = await boot(tester, demo: false, setup: (db) => Ledger(db).addTransaction(spend(Scope.household, 100)));
    await h.go('/home');
    expect(find.text('PERSONAL VS HOUSEHOLD'), findsOneWidget);
    expect(find.text('OTHER'), findsNothing);
    await h.dispose();
  });

  test('summaries and monthly points count Other on its own', () {
    Transaction t(Scope s, int cents) => Transaction(
      id: '$s$cents',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      dirty: false,
      type: TxType.expense,
      scope: s,
      amountCents: cents,
      accountId: 'a',
      occurredOn: '2026-10-05',
      note: '',
      merchant: '',
      currency: 'USD',
      tags: '',
    );
    final txs = [t(Scope.personal, 500), t(Scope.other, 250), t(Scope.other, 50)];
    final s = PeriodSummary.of(txs);
    expect(s.byScope[Scope.other], 300);
    expect(s.expense, 800);
    final p = monthlySeries(txs, DateTime(2026, 10), 1).single;
    expect(p.byScope[Scope.other], 300);
    expect(p.personal, 500);
  });
}
