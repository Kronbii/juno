import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/plan/recurrence.dart';
import 'package:juno/features/smart/advisor.dart';

/// "Make this recurring?" and "Set a budget?" — each one tap, each undoable,
/// each dismissable for good.
class SuggestionsCard extends ConsumerStatefulWidget {
  const SuggestionsCard({required this.subscriptions, required this.budgets, super.key});

  final List<SubscriptionSuggestion> subscriptions;
  final List<BudgetSuggestion> budgets;

  @override
  ConsumerState<SuggestionsCard> createState() => _SuggestionsCardState();
}

class _SuggestionsCardState extends ConsumerState<SuggestionsCard> {
  static const _key = 'dismissed.suggestions';

  Set<String> get _dismissed => (ref.read(prefsProvider).getStringList(_key) ?? const []).toSet();

  Future<void> _dismiss(String id) async {
    await ref.read(prefsProvider).setStringList(_key, [..._dismissed, id]);
    setState(() {});
  }

  static String _subId(SubscriptionSuggestion s) => 'sub:${s.label.toLowerCase()}';
  static String _budgetId(BudgetSuggestion b) => 'budget:${b.categoryId}';

  Future<void> _makeRecurring(SubscriptionSuggestion s) async {
    final last = Day.parse(s.lastDay);
    final next = nextOccurrence(
      anchor: DateTime(last.year, last.month, s.dayOfMonth),
      from: last,
      frequency: Frequency.monthly,
    );
    final ledger = ref.read(ledgerProvider);
    final id = await ledger.upsertRecurring(
      RecurringRulesCompanion.insert(
        type: TxType.expense,
        scope: s.scope,
        amountCents: s.amountCents,
        accountId: s.accountId,
        categoryId: Value(s.categoryId),
        note: Value(s.label),
        frequency: Frequency.monthly,
        anchorDate: Day.of(next),
        nextDue: Day.of(next),
      ),
    );
    showToast(
      '${s.label} is now recurring — next on ${Day.short(Day.of(next))}',
      onUndo: () => ledger.deleteRecurring(id),
    );
  }

  Future<void> _setBudget(BudgetSuggestion b) async {
    final ledger = ref.read(ledgerProvider);
    final id = await ledger.upsertBudget(
      BudgetsCompanion.insert(categoryId: Value(b.categoryId), limitCents: b.limitCents),
    );
    final name = ref.read(categoryMapProvider)[b.categoryId]?.name ?? 'Category';
    showToast('Budget set: $name ${Money.whole(b.limitCents)} a month', onUndo: () => ledger.deleteBudget(id));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final cats = ref.watch(categoryMapProvider);
    final dismissed = _dismissed;
    final subs = widget.subscriptions.where((s) => !dismissed.contains(_subId(s))).toList();
    final budgets = widget.budgets.where((b) => !dismissed.contains(_budgetId(b))).toList();
    if (subs.isEmpty && budgets.isEmpty) return const SizedBox.shrink();

    Widget row({
      required IconData icon,
      required String text,
      required String action,
      required VoidCallback onAction,
      required VoidCallback onDismiss,
    }) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 17, color: c.inkMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: JType.body.copyWith(fontSize: 13.5, color: c.ink)),
          ),
          const SizedBox(width: 8),
          JButton(label: action, kind: JButtonKind.secondary, dense: true, onPressed: onAction),
          IconButton(
            tooltip: 'Not now',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded, size: 16, color: c.inkFaint),
            onPressed: onDismiss,
          ),
        ],
      ),
    );

    return JCard(
      title: 'Suggestions',
      accent: JAccent.household,
      child: Column(
        children: [
          for (final s in subs)
            row(
              icon: Icons.autorenew_rounded,
              text:
                  '${s.label}: ${Fx.format(s.amountCents, s.currency)} around the ${_ordinal(s.dayOfMonth)}, '
                  '${s.months} months running.',
              action: 'Make recurring',
              onAction: () async {
                await _makeRecurring(s);
                await _dismiss(_subId(s));
              },
              onDismiss: () => _dismiss(_subId(s)),
            ),
          for (final b in budgets)
            row(
              icon: Icons.donut_large_outlined,
              text: '${cats[b.categoryId]?.name ?? 'A category'} averages ${Money.whole(b.averageCents)} a month.',
              action: 'Budget ${Money.whole(b.limitCents)}',
              onAction: () async {
                await _setBudget(b);
                await _dismiss(_budgetId(b));
              },
              onDismiss: () => _dismiss(_budgetId(b)),
            ),
        ],
      ),
    );
  }

  static String _ordinal(int d) {
    if (d >= 11 && d <= 13) return '${d}th';
    return switch (d % 10) {
      1 => '${d}st',
      2 => '${d}nd',
      3 => '${d}rd',
      _ => '${d}th',
    };
  }
}
