import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/insights/health.dart';

/// Insights → Money health: runway, savings rate, fixed bills and card debt
/// from the last three full months, across both scopes (income isn't split
/// by scope, so a per-scope rate wouldn't mean anything).
class MoneyHealthCard extends ConsumerWidget {
  const MoneyHealthCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    ref.watch(todayProvider); // redraw when the day changes
    final now = clock.now();
    final txs = ref.watch(
      txQueryProvider(
        TxQuery(
          from: Day.firstOfMonth(DateTime(now.year, now.month - 3)),
          to: Day.lastOfMonth(DateTime(now.year, now.month - 1)),
        ),
      ),
    );
    final balances = ref.watch(balancesProvider).value;
    if (txs.value == null || balances == null) return const SizedBox.shrink();
    final h = moneyHealth(
      accounts: ref.watch(allAccountsProvider).value ?? const [],
      balances: balances,
      rules: ref.watch(recurringProvider).value ?? const <RecurringRule>[],
      txs: txs.value!,
      rates: ref.watch(ratesProvider),
      now: now,
    );
    if (!h.enough) {
      return JCard(
        title: 'Money health',
        child: Text(
          'After your first full month, this shows how many months your money would last, how much of your '
          'income you keep, and how much goes to fixed bills.',
          style: JType.body.copyWith(color: c.inkMuted),
        ),
      );
    }
    String pct(double v) => '${(v * 100).round()}%';
    final range = h.months == 1 ? Day.month(h.to) : '${Day.monthShort(h.from)}–${Day.monthShort(h.to)}';
    return JCard(
      title: 'Money health',
      trailing: JPill(range),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Row(
            label: 'Months covered',
            value: '${h.runway!.toStringAsFixed(h.runway! < 10 ? 1 : 0)} mo',
            verdict: h.runwayVerdict,
            words: const {Verdict.good: 'Strong', Verdict.ok: 'Building', Verdict.weak: 'Thin'},
            detail: 'Everything you have, less card debt, against ${Money.whole(h.avgSpend)} a month of spending.',
          ),
          _Row(
            label: 'You keep',
            value: h.savingsRate == null ? '—' : pct(h.savingsRate!),
            verdict: h.savingsVerdict,
            words: {
              Verdict.good: 'Strong',
              Verdict.ok: 'OK',
              Verdict.weak: (h.savingsRate ?? 0) < 0 ? 'Spending more than earned' : 'Low',
            },
            detail: 'Of ${Money.whole(h.avgIncome)} a month coming in.',
          ),
          _Row(
            label: 'Fixed bills',
            value: h.fixedShare == null ? Money.whole(h.monthlyBills) : pct(h.fixedShare!),
            verdict: h.fixedVerdict,
            words: const {Verdict.good: 'Comfortable', Verdict.ok: 'Tight', Verdict.weak: 'Heavy'},
            detail:
                '${Money.whole(h.monthlyBills)} a month of recurring bills${h.fixedShare == null ? '' : ' out of income'}.',
          ),
          _Row(
            label: 'Card debt',
            value: h.cardDebt == 0 ? 'None' : Money.whole(h.cardDebt),
            verdict: h.debtVerdict,
            words: const {Verdict.good: 'Clear', Verdict.ok: 'Manageable', Verdict.weak: 'High'},
            detail: 'Owed on cards today.',
            last: true,
          ),
          if (!h.complete)
            Padding(
              padding: const EdgeInsets.only(top: JSpace.sm),
              child: Text(
                'Some accounts or bills are left out because an exchange rate is missing.',
                style: JType.body.copyWith(fontSize: 12, color: c.inkFaint),
              ),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    required this.verdict,
    required this.words,
    required this.detail,
    this.last = false,
  });

  final String label;
  final String value;
  final Verdict? verdict;
  final Map<Verdict, String> words;
  final String detail;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final color = switch (verdict) {
      Verdict.good => c.income,
      Verdict.ok => c.warn,
      Verdict.weak => c.expense,
      null => c.inkFaint,
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: JType.rowTitle.copyWith(color: c.ink)),
              ),
              Text(value, style: JType.rowMetric.copyWith(color: c.ink)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(detail, style: JType.body.copyWith(fontSize: 12, color: c.inkFaint)),
              ),
              if (verdict != null) ...[const SizedBox(width: JSpace.sm), JPill(words[verdict]!, color: color)],
            ],
          ),
        ],
      ),
    );
  }
}
