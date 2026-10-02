import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/add/entry_sheet.dart';

/// One transaction. Swipe left to delete (with undo), right to duplicate to
/// today; tap to edit.
class TxRow extends ConsumerWidget {
  const TxRow({required this.tx, this.showDate = false, super.key});

  final Transaction tx;
  final bool showDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final cat = ref.watch(categoryMapProvider)[tx.categoryId];
    final accounts = ref.watch(accountMapProvider);
    final account = accounts[tx.accountId];
    final ledger = ref.read(ledgerProvider);

    final isTransfer = tx.type == TxType.transfer;
    final title = tx.note.isNotEmpty
        ? tx.note
        : tx.merchant.isNotEmpty
        ? tx.merchant
        : isTransfer
        ? 'Transfer'
        : cat?.name ?? 'Uncategorised';
    final subtitle = [
      if (showDate) Day.relative(tx.occurredOn),
      if (isTransfer) '${account?.name ?? '?'} → ${accounts[tx.toAccountId]?.name ?? '?'}',
      if (!isTransfer && (tx.note.isNotEmpty || tx.merchant.isNotEmpty)) cat?.name ?? 'Uncategorised',
      if (!isTransfer) account?.name,
      for (final t in tx.tagList) EntryTags.label(t),
      if (tx.splitGroup != null) 'split',
    ].whereType<String>().join(' · ');

    final iconColor = isTransfer
        ? c.inkMuted
        : cat == null
        ? c.inkFaint
        : seriesColor(c, cat.colorIndex);
    final money = Fx.format(tx.amountCents, tx.currency);
    final amount = switch (tx.type) {
      TxType.income => '+$money',
      TxType.expense => '\u2212$money',
      TxType.transfer => money,
    };
    final foreign = tx.currency != baseCurrency;
    final clips = ref.watch(attachmentCountsProvider).value?[tx.id] ?? 0;
    final amountColor = switch (tx.type) {
      TxType.income => c.income,
      TxType.expense => c.ink,
      TxType.transfer => c.inkMuted,
    };

    return Slidable(
      key: ValueKey(tx.id),
      groupTag: 'tx',
      startActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: 0.26,
        children: [
          SlidableAction(
            onPressed: (_) async {
              final id = await ledger.duplicateTransaction(tx);
              showToast('Copied to today', onUndo: () => ledger.deleteTransaction(id));
            },
            backgroundColor: c.tint(c.household),
            foregroundColor: c.household,
            icon: Icons.copy_rounded,
            label: 'Again',
          ),
        ],
      ),
      endActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: 0.26,
        dismissible: DismissiblePane(
          onDismissed: () {
            ledger.deleteTransaction(tx.id);
            showToast('Entry deleted', onUndo: () => ledger.restoreTransaction(tx.id));
          },
        ),
        children: [
          SlidableAction(
            onPressed: (_) {
              ledger.deleteTransaction(tx.id);
              showToast('Entry deleted', onUndo: () => ledger.restoreTransaction(tx.id));
            },
            backgroundColor: c.tint(c.expense),
            foregroundColor: c.expense,
            icon: Icons.delete_outline_rounded,
            label: 'Delete',
          ),
        ],
      ),
      child: InkWell(
        onTap: () => showEntrySheet(context, edit: tx),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.tint(iconColor),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: iconColor.withValues(alpha: 0.25)),
                ),
                child: Icon(
                  isTransfer ? Icons.swap_horiz_rounded : categoryIcon(cat?.icon),
                  size: 19,
                  color: iconColor,
                ),
              ),
              const SizedBox(width: JSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: JType.rowTitle.copyWith(fontSize: 14.5, color: c.ink),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (!isTransfer) ...[
                          JDot(tx.scope == Scope.household ? c.household : c.brand, size: 6),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: JType.body.copyWith(fontSize: 12, color: c.inkFaint),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: JSpace.md),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (clips > 0) ...[
                        Icon(Icons.attach_file_rounded, size: 13, color: c.inkFaint),
                        const SizedBox(width: 4),
                      ],
                      Text(amount, style: JType.rowMetric.copyWith(color: amountColor)),
                    ],
                  ),
                  if (foreign) ...[
                    const SizedBox(height: 3),
                    Text('~${Money.format(tx.usd)}', style: JType.microLabel.copyWith(color: c.inkFaint)),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated figure that counts from its previous value to [cents].
class CountUpMoney extends StatelessWidget {
  const CountUpMoney(this.cents, {this.style, this.whole = false, super.key});

  final int cents;
  final TextStyle? style;
  final bool whole;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: cents.toDouble()),
    duration: JMotion.reduced(context) ? Duration.zero : const Duration(milliseconds: 900),
    curve: JMotion.ease,
    builder: (_, v, _) => Text(
      whole ? Money.whole(v.round()) : Money.format(v.round()),
      maxLines: 1,
      style: style,
    ),
  );
}
