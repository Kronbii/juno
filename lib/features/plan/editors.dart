import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/add/entry_sheet.dart' show ScopeToggle;
import 'package:juno/features/plan/recurrence.dart';

/// A money text field that parses to cents.
class MoneyField extends StatelessWidget {
  const MoneyField({
    required this.controller,
    this.hint = '0.00',
    this.autofocus = false,
    this.allowNegative = false,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  final bool allowNegative;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: autofocus,
    keyboardType: TextInputType.numberWithOptions(decimal: true, signed: allowNegative),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(allowNegative ? r'[0-9.,\-]' : '[0-9.,]'))],
    style: JType.cardMetric.copyWith(color: context.jc.ink),
    decoration: InputDecoration(prefixText: r'$ ', hintText: hint),
  );
}

/// Dropdown of categories (optionally with an "all" option).
class CategoryPicker extends ConsumerWidget {
  const CategoryPicker({
    required this.value,
    required this.onChanged,
    this.kind = CategoryKind.expense,
    this.allowAll = false,
    this.allLabel = 'All spending',
    super.key,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final CategoryKind kind;
  final bool allowAll;
  final String allLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final cats = (ref.watch(categoriesProvider).value ?? const <Category>[]).where((k) => k.kind == kind);
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      dropdownColor: c.raised,
      borderRadius: BorderRadius.circular(JRadius.chip),
      style: JType.body.copyWith(fontSize: 15, color: c.ink),
      items: [
        if (allowAll) DropdownMenuItem(child: Text(allLabel)),
        for (final k in cats)
          DropdownMenuItem(
            value: k.id,
            child: Row(
              children: [
                Icon(categoryIcon(k.icon), size: 16, color: seriesColor(c, k.colorIndex)),
                const SizedBox(width: 10),
                Text(k.name),
              ],
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

class AccountPicker extends ConsumerWidget {
  const AccountPicker({required this.value, required this.onChanged, super.key});

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    return DropdownButtonFormField<String>(
      initialValue: value ?? accounts.firstOrNull?.id,
      isExpanded: true,
      dropdownColor: c.raised,
      borderRadius: BorderRadius.circular(JRadius.chip),
      style: JType.body.copyWith(fontSize: 15, color: c.ink),
      items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
      onChanged: onChanged,
    );
  }
}

class _DateButton extends StatelessWidget {
  const _DateButton({required this.day, required this.onChanged, this.placeholder = 'Pick a date', this.onClear});

  final String? day;
  final ValueChanged<String> onChanged;
  final String placeholder;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      JChip(
        label: day == null ? placeholder : Day.relative(day!),
        selected: day != null,
        leading: Icon(Icons.calendar_today_outlined, size: 14, color: context.jc.inkFaint),
        onTap: () async {
          final p = await showDatePicker(
            context: context,
            initialDate: day == null ? DateTime.now() : Day.parse(day!),
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
          );
          if (p != null) onChanged(Day.of(p));
        },
      ),
      if (day != null && onClear != null) ...[
        const SizedBox(width: 4),
        JIconButton(icon: Icons.close_rounded, size: 34, onPressed: onClear, tooltip: 'Clear'),
      ],
    ],
  );
}

// ------------------------------------------------------------------ budget

Future<void> editBudget(BuildContext context, {Budget? budget}) => showJSheet<void>(
  context,
  title: budget == null ? 'New *budget*' : 'Edit *budget*',
  child: _BudgetForm(budget: budget),
);

class _BudgetForm extends ConsumerStatefulWidget {
  const _BudgetForm({this.budget});

  final Budget? budget;

  @override
  ConsumerState<_BudgetForm> createState() => _BudgetFormState();
}

class _BudgetFormState extends ConsumerState<_BudgetForm> {
  late String? _cat = widget.budget?.categoryId;
  late Scope? _scope = widget.budget?.scope;
  late final _limit = TextEditingController(
    text: widget.budget == null ? '' : Money.plain(widget.budget!.limitCents).replaceAll(',', ''),
  );

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.read(ledgerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JField(
          label: 'Category',
          child: CategoryPicker(value: _cat, allowAll: true, onChanged: (v) => setState(() => _cat = v)),
        ),
        JField(
          label: 'Applies to',
          child: JSegmentBar<String>(
            segments: const {'both': 'Both', 'personal': 'Personal', 'household': 'Household'},
            selected: _scope?.name ?? 'both',
            accentOf: (k) => k == 'household' ? JAccent.household : JAccent.brand,
            onChanged: (k) => setState(() => _scope = Scope.values.where((s) => s.name == k).firstOrNull),
          ),
        ),
        JField(
          label: 'Monthly limit',
          child: MoneyField(controller: _limit, autofocus: widget.budget == null),
        ),
        Row(
          children: [
            if (widget.budget != null) ...[
              JButton(
                label: 'Delete',
                kind: JButtonKind.secondary,
                accent: JAccent.expense,
                onPressed: () async {
                  await ledger.deleteBudget(widget.budget!.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              const SizedBox(width: JSpace.sm),
            ],
            Expanded(
              child: ListenableBuilder(
                listenable: _limit,
                builder: (context, _) => JButton(
                  label: 'Save budget',
                  expand: true,
                  onPressed: (Money.parse(_limit.text) ?? 0) <= 0
                      ? null
                      : () async {
                          await ledger.upsertBudget(
                            BudgetsCompanion(
                              id: widget.budget == null ? const Value.absent() : Value(widget.budget!.id),
                              categoryId: Value(_cat),
                              scope: Value(_scope),
                              limitCents: Value(Money.parse(_limit.text)!),
                            ),
                          );
                          if (context.mounted) Navigator.of(context).pop();
                        },
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------- goal

Future<void> editGoal(BuildContext context, {Goal? goal}) => showJSheet<void>(
  context,
  title: goal == null ? 'New *goal*' : 'Edit *goal*',
  child: _GoalForm(goal: goal),
);

class _GoalForm extends ConsumerStatefulWidget {
  const _GoalForm({this.goal});

  final Goal? goal;

  @override
  ConsumerState<_GoalForm> createState() => _GoalFormState();
}

class _GoalFormState extends ConsumerState<_GoalForm> {
  late final _name = TextEditingController(text: widget.goal?.name ?? '');
  late final _target = TextEditingController(
    text: widget.goal == null ? '' : Money.plain(widget.goal!.targetCents).replaceAll(',', ''),
  );
  late String? _date = widget.goal?.targetDate;
  late int _color = widget.goal?.colorIndex ?? 0;

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final ledger = ref.read(ledgerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JField(
          label: 'Name',
          child: TextField(
            controller: _name,
            autofocus: widget.goal == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Emergency fund, new laptop…'),
          ),
        ),
        JField(
          label: 'Target',
          child: MoneyField(controller: _target),
        ),
        JField(
          label: 'By (optional)',
          child: _DateButton(
            day: _date,
            placeholder: 'No deadline',
            onChanged: (d) => setState(() => _date = d),
            onClear: () => setState(() => _date = null),
          ),
        ),
        JField(
          label: 'Colour',
          child: Wrap(
            spacing: 10,
            children: [
              for (var i = 0; i < seriesCount; i++)
                GestureDetector(
                  onTap: () => setState(() => _color = i),
                  child: Container(
                    width: 30,
                    height: 30,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: i == _color ? c.ink : Colors.transparent, width: 1.5),
                    ),
                    child: JDot(seriesColor(c, i), size: 22),
                  ),
                ),
            ],
          ),
        ),
        Row(
          children: [
            if (widget.goal != null) ...[
              JButton(
                label: 'Delete',
                kind: JButtonKind.secondary,
                accent: JAccent.expense,
                onPressed: () async {
                  await ledger.deleteGoal(widget.goal!.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              const SizedBox(width: JSpace.sm),
            ],
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([_name, _target]),
                builder: (context, _) {
                  final cents = Money.parse(_target.text) ?? 0;
                  return JButton(
                    label: 'Save goal',
                    expand: true,
                    onPressed: _name.text.trim().isEmpty || cents <= 0
                        ? null
                        : () async {
                            await ledger.upsertGoal(
                              GoalsCompanion(
                                id: widget.goal == null ? const Value.absent() : Value(widget.goal!.id),
                                name: Value(_name.text.trim()),
                                targetCents: Value(cents),
                                targetDate: Value(_date),
                                colorIndex: Value(_color),
                              ),
                            );
                            if (context.mounted) Navigator.of(context).pop();
                          },
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Add money to (or take it out of) a goal.
Future<void> contribute(BuildContext context, WidgetRef ref, Goal goal, {bool withdraw = false}) async {
  final ctrl = TextEditingController();
  final cents = await showJSheet<int>(
    context,
    title: withdraw ? 'Take from *${goal.name}*' : 'Add to *${goal.name}*',
    child: Builder(
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          JField(
            label: 'Amount',
            child: MoneyField(controller: ctrl, autofocus: true),
          ),
          ListenableBuilder(
            listenable: ctrl,
            builder: (context, _) {
              final v = Money.parse(ctrl.text) ?? 0;
              return JButton(
                label: withdraw ? 'Withdraw' : 'Add',
                accent: withdraw ? JAccent.expense : JAccent.income,
                expand: true,
                onPressed: v <= 0 ? null : () => Navigator.of(context).pop(v),
              );
            },
          ),
        ],
      ),
    ),
  );
  ctrl.dispose();
  if (cents != null) {
    await ref.read(ledgerProvider).addContribution(goal.id, withdraw ? -cents : cents);
  }
}

// --------------------------------------------------------------- recurring

Future<void> editRecurring(BuildContext context, {RecurringRule? rule}) => showJSheet<void>(
  context,
  title: rule == null ? 'New *recurring*' : 'Edit *recurring*',
  child: _RecurringForm(rule: rule),
);

class _RecurringForm extends ConsumerStatefulWidget {
  const _RecurringForm({this.rule});

  final RecurringRule? rule;

  @override
  ConsumerState<_RecurringForm> createState() => _RecurringFormState();
}

class _RecurringFormState extends ConsumerState<_RecurringForm> {
  late TxType _type = widget.rule?.type ?? TxType.expense;
  late Scope _scope = widget.rule?.scope ?? Scope.personal;
  late String? _cat = widget.rule?.categoryId;
  late String? _account = widget.rule?.accountId;
  late Frequency _freq = widget.rule?.frequency ?? Frequency.monthly;
  late String _start = widget.rule?.nextDue ?? Day.today();
  late String? _end = widget.rule?.endDate;
  late bool _active = widget.rule?.active ?? true;
  late final _amount = TextEditingController(
    text: widget.rule == null ? '' : Money.plain(widget.rule!.amountCents).replaceAll(',', ''),
  );
  late final _note = TextEditingController(text: widget.rule?.note ?? '');

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.read(ledgerProvider);
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JField(
          label: 'Type',
          child: JSegmentBar<TxType>(
            segments: const {TxType.expense: 'Expense', TxType.income: 'Income'},
            selected: _type,
            accentOf: (t) => t == TxType.income ? JAccent.income : JAccent.expense,
            onChanged: (t) => setState(() {
              _type = t;
              _cat = null;
            }),
          ),
        ),
        JField(
          label: 'Name',
          child: TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Rent, Netflix, salary…'),
          ),
        ),
        JField(
          label: 'Amount',
          child: MoneyField(controller: _amount),
        ),
        JField(
          label: 'Category',
          child: CategoryPicker(
            value: _cat,
            kind: _type == TxType.income ? CategoryKind.income : CategoryKind.expense,
            allowAll: true,
            allLabel: 'None',
            onChanged: (v) => setState(() => _cat = v),
          ),
        ),
        JField(
          label: 'Account',
          child: AccountPicker(value: _account, onChanged: (v) => setState(() => _account = v)),
        ),
        JField(
          label: 'Scope',
          child: Align(
            alignment: Alignment.centerLeft,
            child: ScopeToggle(value: _scope, onChanged: (s) => setState(() => _scope = s)),
          ),
        ),
        JField(
          label: 'Repeats',
          child: JSegmentBar<Frequency>(
            segments: const {Frequency.weekly: 'Weekly', Frequency.monthly: 'Monthly', Frequency.yearly: 'Yearly'},
            selected: _freq,
            onChanged: (f) => setState(() => _freq = f),
          ),
        ),
        JField(
          label: widget.rule == null ? 'First on' : 'Next on',
          child: _DateButton(day: _start, onChanged: (d) => setState(() => _start = d)),
        ),
        JField(
          label: 'Ends (optional)',
          child: _DateButton(
            day: _end,
            placeholder: 'Never',
            onChanged: (d) => setState(() => _end = d),
            onClear: () => setState(() => _end = null),
          ),
        ),
        if (widget.rule != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Active', style: JType.rowTitle.copyWith(color: context.jc.ink)),
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
        const SizedBox(height: JSpace.sm),
        Row(
          children: [
            if (widget.rule != null) ...[
              JButton(
                label: 'Delete',
                kind: JButtonKind.secondary,
                accent: JAccent.expense,
                onPressed: () async {
                  await ledger.deleteRecurring(widget.rule!.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              const SizedBox(width: JSpace.sm),
            ],
            Expanded(
              child: ListenableBuilder(
                listenable: _amount,
                builder: (context, _) {
                  final cents = Money.parse(_amount.text) ?? 0;
                  final account = _account ?? accounts.firstOrNull?.id;
                  return JButton(
                    label: 'Save',
                    expand: true,
                    onPressed: cents <= 0 || account == null
                        ? null
                        : () async {
                            final r = widget.rule;
                            await ledger.upsertRecurring(
                              RecurringRulesCompanion(
                                id: r == null ? const Value.absent() : Value(r.id),
                                type: Value(_type),
                                scope: Value(_scope),
                                amountCents: Value(cents),
                                accountId: Value(account),
                                categoryId: Value(_cat),
                                note: Value(_note.text.trim()),
                                frequency: Value(_freq),
                                // Changing the next date re-anchors the rule.
                                anchorDate: Value(r == null || r.nextDue != _start ? _start : r.anchorDate),
                                nextDue: Value(_start),
                                endDate: Value(_end),
                                active: Value(_active),
                              ),
                            );
                            // Post anything already due (e.g. a rule that started last week).
                            await materializeRecurring(ref.read(databaseProvider));
                            if (context.mounted) Navigator.of(context).pop();
                          },
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
