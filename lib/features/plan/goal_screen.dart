import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/plan/editors.dart';
import 'package:juno/features/plan/plan_screen.dart';

class GoalScreen extends ConsumerWidget {
  const GoalScreen({required this.goalId, super.key});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final goal = (ref.watch(goalsProvider).value ?? const <Goal>[]).where((g) => g.id == goalId).firstOrNull;
    final saved = ref.watch(goalSavedProvider).value?[goalId] ?? 0;
    final history = ref.watch(goalContributionsProvider(goalId)).value ?? const <GoalContribution>[];

    if (goal == null) {
      // Deleted (here or on another device), or still loading: never a dead end.
      final loading = ref.watch(goalsProvider).isLoading;
      return JScreen(
        eyebrow: 'Goal',
        title: loading ? 'Loading…' : 'Goal *gone*',
        actions: [
          JIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
        slivers: [
          if (!loading)
            SliverToBoxAdapter(
              child: JEmpty(
                icon: Icons.flag_outlined,
                title: 'This goal was deleted',
                action: JButton(label: 'Back to goals', dense: true, onPressed: () => Navigator.of(context).maybePop()),
              ),
            ),
        ],
      );
    }
    final color = seriesColor(c, goal.colorIndex);

    return JScreen(
      eyebrow: 'Goal',
      title: '*${goal.name}*',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
        JIconButton(
          icon: Icons.edit_outlined,
          tooltip: 'Edit',
          onPressed: () => editGoal(context, goal: goal),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              JCard(
                padding: const EdgeInsets.all(JSpace.tile),
                child: Row(
                  children: [
                    GoalRing(ratio: goal.targetCents == 0 ? 0 : saved / goal.targetCents, color: color, size: 96),
                    const SizedBox(width: JSpace.xl),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('SAVED', style: JType.microLabel.copyWith(color: c.inkFaint)),
                          const SizedBox(height: 6),
                          FittedBox(
                            child: Text(Money.format(saved), style: JType.panelMetric.copyWith(color: c.ink)),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'of ${Money.format(goal.targetCents)}'
                            '${goal.targetDate == null ? '' : ' by ${Day.short(goal.targetDate!)}'}',
                            style: JType.body.copyWith(color: c.inkMuted),
                          ),
                          const SizedBox(height: 6),
                          GoalPaceLine(goal: goal, saved: saved),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: JSpace.gap),
              Row(
                children: [
                  Expanded(
                    child: JButton(
                      label: 'Add money',
                      icon: Icons.add_rounded,
                      accent: JAccent.income,
                      expand: true,
                      onPressed: () => contribute(context, ref, goal),
                    ),
                  ),
                  const SizedBox(width: JSpace.sm),
                  Expanded(
                    child: JButton(
                      label: 'Withdraw',
                      kind: JButtonKind.secondary,
                      expand: true,
                      onPressed: () => contribute(context, ref, goal, withdraw: true),
                    ),
                  ),
                ],
              ),
              const JSectionLabel('History'),
              if (history.isEmpty)
                Text('No contributions yet.', style: JType.body.copyWith(color: c.inkMuted))
              else
                JGroup(
                  children: [
                    for (final h in history)
                      JSettingRow(
                        icon: h.amountCents >= 0 ? Icons.south_west_rounded : Icons.north_east_rounded,
                        title: Day.relative(h.occurredOn),
                        subtitle: h.note.isEmpty ? null : h.note,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              Money.signed(h.amountCents),
                              style: JType.rowMetric.copyWith(color: h.amountCents >= 0 ? c.income : c.expense),
                            ),
                            IconButton(
                              tooltip: 'Remove',
                              icon: Icon(Icons.close_rounded, size: 16, color: c.inkFaint),
                              onPressed: () {
                                ref.read(ledgerProvider).deleteContribution(h.id);
                                showToast('Contribution removed');
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}
