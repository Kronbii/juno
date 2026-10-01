import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/insights/analytics.dart';

String budgetName(Budget b, Map<String, Category> cats) {
  final what = b.categoryId == null ? 'All spending' : cats[b.categoryId]?.name ?? 'Category';
  return b.scope == null ? what : '$what · ${b.scope!.label}';
}

/// Name, spent/limit, a 3px bar, and a status word. Status is never colour
/// alone: the label says "over" / "close" in text.
class BudgetLine extends ConsumerWidget {
  const BudgetLine({required this.status, this.onTap, super.key});

  final BudgetStatus status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final cats = ref.watch(categoryMapProvider);
    final b = status.budget;
    final cat = cats[b.categoryId];
    final stateText = status.over
        ? '${Money.whole(-status.remaining)} over'
        : status.near
        ? '${Money.whole(status.remaining)} left · close'
        : '${Money.whole(status.remaining)} left';
    final stateColor = status.over
        ? c.expense
        : status.near
        ? c.warn
        : c.inkFaint;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              JDot(cat == null ? c.inkMuted : seriesColor(c, cat.colorIndex)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  budgetName(b, cats),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: JType.bodyStrong.copyWith(color: c.ink, fontSize: 14),
                ),
              ),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: Money.whole(status.spent),
                      style: JType.rowMetric.copyWith(color: c.ink, fontSize: 13),
                    ),
                    TextSpan(
                      text: ' / ${Money.whole(b.limitCents)}',
                      style: JType.rowMetric.copyWith(color: c.inkFaint, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          JProgress(value: status.ratio),
          const SizedBox(height: 6),
          Row(
            children: [
              if (status.over) ...[
                Icon(Icons.error_outline_rounded, size: 12, color: stateColor),
                const SizedBox(width: 4),
              ],
              Text(stateText.toUpperCase(), style: JType.microLabel.copyWith(color: stateColor)),
            ],
          ),
        ],
      ),
    );
  }
}
