import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/notify/reminders.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/widget/home_widget_sync.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/plan/recurrence.dart' show postingRules;

final remindersProvider = Provider<Reminders>((ref) => Reminders(ref.watch(prefsProvider)));

/// Re-plans bills, checks budgets and refreshes the home-screen widget on launch, resume and (debounced) after
/// writes. Reads the database directly so it works before any screen has
/// subscribed to the streams.
class ReminderRunner extends Notifier<void> {
  Timer? _debounce;

  @override
  void build() => ref.onDispose(() => _debounce?.cancel());

  void schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), run);
  }

  Future<void> run() async {
    final reminders = ref.read(remindersProvider);
    final db = ref.read(databaseProvider);
    final ledger = ref.read(ledgerProvider);
    final accounts = {for (final a in await db.select(db.accounts).get()) a.id: a};
    final cats = {for (final c in await db.select(db.categories).get()) c.id: c};
    final rules = postingRules(
      await (db.select(db.recurringRules)..where((r) => r.deletedAt.isNull())).get(),
      accounts,
    );
    await reminders.planBills(rules, accounts, cats);

    final now = clock.now();
    final month = DateTime(now.year, now.month);
    final budgets = await (db.select(db.budgets)..where((b) => b.deletedAt.isNull())).get();
    final txs = await ledger.transactions(TxQuery(from: Day.firstOfMonth(month), to: Day.lastOfMonth(month)));
    await reminders.checkBudgets(budgetStatuses(budgets, txs), cats);
    await HomeWidgetSync.push(db);
  }
}

final reminderRunnerProvider = NotifierProvider<ReminderRunner, void>(ReminderRunner.new);
