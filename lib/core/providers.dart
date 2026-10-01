import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/notify/reminder_runner.dart';
import 'package:juno/core/sync/sync_engine.dart';
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

/// The month Home and Insights are looking at (first day of month).
class SelectedMonth extends Notifier<DateTime> {
  @override
  DateTime build() {
    final now = DateTime.now();
    return DateTime(now.year, now.month);
  }

  void set(DateTime m) => state = DateTime(m.year, m.month);
  void shift(int months) => state = DateTime(state.year, state.month + months);
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

final balancesProvider = StreamProvider<Map<String, int>>((ref) => ref.watch(ledgerProvider).watchBalances());

final txQueryProvider = StreamProvider.family<List<Transaction>, TxQuery>(
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

final budgetsProvider = StreamProvider<List<Budget>>((ref) => ref.watch(ledgerProvider).watchBudgets());

final goalsProvider = StreamProvider<List<Goal>>((ref) => ref.watch(ledgerProvider).watchGoals());

final goalSavedProvider = StreamProvider<Map<String, int>>((ref) => ref.watch(ledgerProvider).watchGoalSaved());

final recurringProvider = StreamProvider<List<RecurringRule>>(
  (ref) => ref.watch(ledgerProvider).watchRecurring(),
);

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
final txTotalsProvider = StreamProvider.family<TxTotals, TxQuery>((ref, q) => ref.watch(ledgerProvider).watchTotals(q));
