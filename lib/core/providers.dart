import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/notify/reminder_runner.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/features/plan/recurrence.dart' show postingRules;
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden in `main` with the opened database.
final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError('databaseProvider'));

/// Overridden in `main`.
final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('prefsProvider'));

/// Called after every local write: asks the sync engine for a debounced push.
final writeHookProvider = Provider<void Function()>(
  (ref) => () {
    ref.read(syncEngineProvider.notifier).schedule();
    ref.read(reminderRunnerProvider.notifier).schedule();
  },
);

final ledgerProvider = Provider<Ledger>(
  (ref) => Ledger(ref.watch(databaseProvider), onWrite: () => ref.read(writeHookProvider)()),
);

// ----------------------------------------------------------------- settings

class ThemeModeSetting extends Notifier<ThemeMode> {
  static const _key = 'themeMode';

  @override
  ThemeMode build() {
    final v = ref.watch(prefsProvider).getString(_key);
    return ThemeMode.values.firstWhere((m) => m.name == v, orElse: () => ThemeMode.system);
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(prefsProvider).setString(_key, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeSetting, ThemeMode>(ThemeModeSetting.new);

/// The app-wide scope lens: null = everything, otherwise personal/household.
/// Home, Activity and Insights all read it so switching it once re-frames the
/// whole app.
class ScopeFilter extends Notifier<Scope?> {
  static const _key = 'scopeFilter';

  @override
  Scope? build() {
    final v = ref.watch(prefsProvider).getString(_key);
    return Scope.values.where((s) => s.name == v).firstOrNull;
  }

  Future<void> set(Scope? scope) async {
    state = scope;
    await ref.read(prefsProvider).setString(_key, scope?.name ?? 'all');
  }
}

final scopeFilterProvider = NotifierProvider<ScopeFilter, Scope?>(ScopeFilter.new);

/// Today's date (midnight), kept current while the app stays open: checked
/// every minute and on resume, so a desktop window left open rolls into the
/// new day and month — and a laptop that slept through midnight catches up
/// on wake. Widgets whose output depends on the date watch this to redraw.
class Today extends Notifier<DateTime> {
  Timer? _timer;

  @override
  DateTime build() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => refresh());
    ref.onDispose(() => _timer?.cancel());
    return _date(clock.now());
  }

  static DateTime _date(DateTime t) => DateTime(t.year, t.month, t.day);

  /// Re-reads the clock (on resume, or each minute).
  void refresh() {
    final d = _date(clock.now());
    if (d != state) state = d;
  }
}

final todayProvider = NotifierProvider<Today, DateTime>(Today.new);

/// The month Home and Insights are looking at (first day of month). It
/// follows the current month — rolling over at month end — until you pick
/// another one; picking the current month again follows it once more.
class SelectedMonth extends Notifier<DateTime> {
  DateTime? _picked;

  @override
  DateTime build() {
    final today = ref.watch(todayProvider);
    return _picked ?? DateTime(today.year, today.month);
  }

  DateTime get _current {
    final t = ref.read(todayProvider);
    return DateTime(t.year, t.month);
  }

  void set(DateTime m) {
    final month = DateTime(m.year, m.month);
    _picked = month == _current ? null : month;
    state = month;
  }

  void shift(int months) => set(DateTime(state.year, state.month + months));
}

final selectedMonthProvider = NotifierProvider<SelectedMonth, DateTime>(SelectedMonth.new);

// -------------------------------------------------------------------- data

final accountsProvider = StreamProvider<List<Account>>((ref) => ref.watch(ledgerProvider).watchAccounts());

final allAccountsProvider = StreamProvider<List<Account>>(
  (ref) => ref.watch(ledgerProvider).watchAccounts(includeArchived: true),
);

final categoriesProvider = StreamProvider<List<Category>>(
  (ref) => ref.watch(ledgerProvider).watchCategories(),
);

final allCategoriesProvider = StreamProvider<List<Category>>(
  (ref) => ref.watch(ledgerProvider).watchCategories(includeArchived: true),
);

/// id → category, including archived ones so old rows still render.
final categoryMapProvider = Provider<Map<String, Category>>((ref) {
  final list = ref.watch(allCategoriesProvider).value ?? const [];
  return {for (final c in list) c.id: c};
});

final accountMapProvider = Provider<Map<String, Account>>((ref) {
  final list = ref.watch(allAccountsProvider).value ?? const [];
  return {for (final a in list) a.id: a};
});

/// Balances as of today; re-queried when the day changes, so an entry dated
/// today counts from midnight.
final balancesProvider = StreamProvider<Map<String, int>>(
  (ref) => ref.watch(ledgerProvider).watchBalances(asOf: Day.of(ref.watch(todayProvider))),
);

/// Entries matching a query. Released when nothing watches it any more:
/// every search keystroke, page size and month browsed is its own query,
/// and kept alive they piled up for as long as the app stayed open.
final txQueryProvider = StreamProvider.autoDispose.family<List<Transaction>, TxQuery>(
  (ref, q) => ref.watch(ledgerProvider).watchTransactions(q),
);

/// Transactions in [month] under the current scope lens.
final monthTxProvider = StreamProvider.family<List<Transaction>, DateTime>((ref, month) {
  final scope = ref.watch(scopeFilterProvider);
  return ref
      .watch(ledgerProvider)
      .watchTransactions(
        TxQuery(from: Day.firstOfMonth(month), to: Day.lastOfMonth(month), scope: scope),
      );
});

/// Transactions in [month] across both scopes (for the split tile).
final monthTxAllScopesProvider = StreamProvider.family<List<Transaction>, DateTime>(
  (ref, month) => ref
      .watch(ledgerProvider)
      .watchTransactions(
        TxQuery(from: Day.firstOfMonth(month), to: Day.lastOfMonth(month)),
      ),
);

/// The [n] months ending at [last], under the scope lens.
final trailingTxProvider = StreamProvider.family<List<Transaction>, (DateTime, int)>((ref, arg) {
  final (last, n) = arg;
  final scope = ref.watch(scopeFilterProvider);
  return ref
      .watch(ledgerProvider)
      .watchTransactions(
        TxQuery(
          from: Day.firstOfMonth(DateTime(last.year, last.month - n + 1)),
          to: Day.lastOfMonth(last),
          scope: scope,
        ),
      );
});

/// Your first entry's day, null before any (see Ledger.watchFirstEntryDay).
final firstEntryDayProvider = StreamProvider<String?>((ref) => ref.watch(ledgerProvider).watchFirstEntryDay());

/// The three full months before today's, under the scope lens — the history
/// month-end estimates are made from.
final usualHistoryProvider = Provider<AsyncValue<List<Transaction>>>((ref) {
  final t = ref.watch(todayProvider);
  return ref.watch(trailingTxProvider((DateTime(t.year, t.month - 1), 3)));
});

final budgetsProvider = StreamProvider<List<Budget>>((ref) => ref.watch(ledgerProvider).watchBudgets());

final goalsProvider = StreamProvider<List<Goal>>((ref) => ref.watch(ledgerProvider).watchGoals());

/// A goal's deposits and withdrawals, newest first.
final goalContributionsProvider = StreamProvider.family<List<GoalContribution>, String>(
  (ref, id) => ref.watch(ledgerProvider).watchContributions(id),
);

final goalSavedProvider = StreamProvider<Map<String, int>>((ref) => ref.watch(ledgerProvider).watchGoalSaved());

final recurringProvider = StreamProvider<List<RecurringRule>>(
  (ref) => ref.watch(ledgerProvider).watchRecurring(),
);

/// The recurring rules that will post: live, on an open account. Every
/// plan and total reads these; only the Recurring list shows all rules.
final postingRulesProvider = Provider<List<RecurringRule>>((ref) {
  final rules = ref.watch(recurringProvider).value ?? const <RecurringRule>[];
  return postingRules(rules, ref.watch(accountMapProvider));
});

final importsProvider = StreamProvider<List<ImportBatche>>((ref) => ref.watch(ledgerProvider).watchImports());

extension ScopeLabel on Scope {
  String get label => switch (this) {
    Scope.personal => 'Personal',
    Scope.household => 'Household',
  };
}

// ------------------------------------------------------------------- v2

final ratesListProvider = StreamProvider<List<CurrencyRate>>((ref) => ref.watch(ledgerProvider).watchRates());

/// code → units per USD, always including USD = 1.
final ratesProvider = Provider<Map<String, double>>((ref) {
  final list = ref.watch(ratesListProvider).value ?? const <CurrencyRate>[];
  return {'USD': 1, for (final r in list) r.code: r.perUsd};
});

final tagsProvider = StreamProvider<List<(String, int)>>((ref) => ref.watch(ledgerProvider).watchTags());

final attachmentCountsProvider = StreamProvider<Map<String, int>>(
  (ref) => ref.watch(ledgerProvider).watchAttachmentCounts(),
);

final attachmentsProvider = StreamProvider.family<List<Attachment>, String>(
  (ref, txId) => ref.watch(ledgerProvider).watchAttachments(txId),
);

/// Every live transaction (for net worth history).
final allTxProvider = StreamProvider<List<Transaction>>(
  (ref) => ref.watch(ledgerProvider).watchTransactions(const TxQuery()),
);

/// Totals over everything a query matches (limit ignored).
final txTotalsProvider = StreamProvider.autoDispose.family<TxTotals, TxQuery>(
  (ref, q) => ref.watch(ledgerProvider).watchTotals(q),
);

final entryHistoryProvider = StreamProvider.family<List<EntryHistoryData>, String>(
  (ref, id) => ref.watch(ledgerProvider).watchHistory(id),
);
