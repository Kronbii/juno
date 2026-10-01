import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/add/entry_sheet.dart' show ScopeToggle;
import 'package:juno/features/plan/editors.dart' show CategoryPicker, MoneyField;

/// Split one payment into parts that must add up to it.
Future<void> showSplitSheet(BuildContext context, Transaction t) => showJSheet<void>(
  context,
  title: 'Split *${Fx.format(t.amountCents, t.currency)}*',
  child: _SplitForm(tx: t),
);

class _Part {
  _Part(this.categoryId, this.scope, String amount) : amount = TextEditingController(text: amount);

  String? categoryId;
  Scope scope;
  final TextEditingController amount;
}

class _SplitForm extends ConsumerStatefulWidget {
  const _SplitForm({required this.tx});

  final Transaction tx;

  @override
  ConsumerState<_SplitForm> createState() => _SplitFormState();
}

class _SplitFormState extends ConsumerState<_SplitForm> {
  late final List<_Part> _parts = [
    _Part(widget.tx.categoryId, widget.tx.scope, ''),
    _Part(null, widget.tx.scope == Scope.personal ? Scope.household : Scope.personal, ''),
  ];

  @override
  void dispose() {
    for (final p in _parts) {
      p.amount.dispose();
    }
    super.dispose();
  }

  int get _assigned => _parts.fold(0, (a, p) => a + (Money.parse(p.amount.text) ?? 0));
  int get _left => widget.tx.amountCents - _assigned;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final cur = widget.tx.currency;
    final kind = widget.tx.type == TxType.income ? CategoryKind.income : CategoryKind.expense;
    final valid = _left == 0 && _parts.every((p) => (Money.parse(p.amount.text) ?? 0) > 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _parts.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: JSpace.lg),
            child: JCard(
              title: 'Part ${i + 1}',
              trailing: _parts.length > 2
                  ? IconButton(
                      tooltip: 'Remove part',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close_rounded, size: 16, color: c.inkFaint),
                      onPressed: () => setState(() => _parts.removeAt(i).amount.dispose()),
                    )
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MoneyField(controller: _parts[i].amount, autofocus: i == 0),
                  const SizedBox(height: JSpace.sm),
                  CategoryPicker(
                    value: _parts[i].categoryId,
                    kind: kind,
                    allowAll: true,
                    allLabel: 'No category',
                    onChanged: (v) => setState(() => _parts[i].categoryId = v),
                  ),
                  const SizedBox(height: JSpace.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ScopeToggle(value: _parts[i].scope, onChanged: (s) => setState(() => _parts[i].scope = s)),
                  ),
                ],
              ),
            ),
          ),
        Row(
          children: [
            JButton(
              label: 'Add part',
              icon: Icons.add_rounded,
              kind: JButtonKind.ghost,
              dense: true,
              onPressed: () => setState(() => _parts.add(_Part(null, Scope.personal, ''))),
            ),
            const Spacer(),
            ListenableBuilder(
              listenable: Listenable.merge([for (final p in _parts) p.amount]),
              builder: (context, _) => Text(
                _left == 0
                    ? 'Adds up'
                    : _left > 0
                    ? '${Fx.format(_left, cur)} left'
                    : '${Fx.format(-_left, cur)} too much',
                style: JType.chipLabel.copyWith(color: _left == 0 ? c.income : c.warn),
              ),
            ),
          ],
        ),
        const SizedBox(height: JSpace.lg),
        ListenableBuilder(
          listenable: Listenable.merge([for (final p in _parts) p.amount]),
          builder: (context, _) => JButton(
            label: 'Split into ${_parts.length}',
            expand: true,
            onPressed: !valid
                ? null
                : () async {
                    try {
                      await ref.read(ledgerProvider).splitTransaction(widget.tx.id, [
                        for (final p in _parts) (p.categoryId, p.scope, Money.parse(p.amount.text)!),
                      ]);
                      if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                      showToast('Split into ${_parts.length} entries');
                    } on Object catch (e) {
                      showToast(e is ArgumentError ? '${e.message}' : 'Couldn’t split: $e');
                    }
                  },
          ),
        ),
      ],
    );
  }
}
