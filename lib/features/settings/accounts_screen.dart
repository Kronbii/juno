import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/plan/editors.dart' show MoneyField;
import 'package:juno/features/settings/balance_check.dart';

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  static IconData iconFor(AccountKind k) => switch (k) {
    AccountKind.cash => Icons.payments_outlined,
    AccountKind.checking => Icons.account_balance_outlined,
    AccountKind.savings => Icons.savings_outlined,
    AccountKind.credit => Icons.credit_card_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final accounts = ref.watch(allAccountsProvider).value ?? const <Account>[];
    final balances = ref.watch(balancesProvider).value ?? const <String, int>{};
    return JScreen(
      eyebrow: 'Settings · Accounts',
      title: 'Where money *lives*',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
        JIconButton(icon: Icons.add_rounded, tooltip: 'New account', onPressed: () => _edit(context, ref)),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: JGroup(
            children: [
              for (final a in accounts)
                JSettingRow(
                  icon: iconFor(a.kind),
                  title: a.archived ? '${a.name} (archived)' : a.name,
                  subtitle: [
                    '${a.kind.name[0].toUpperCase()}${a.kind.name.substring(1)} · ${a.currency}',
                    if (BalanceChecks.last(ref.watch(prefsProvider), a.id) case final at?)
                      'checked ${Day.short(Day.of(at))}',
                  ].join(' · '),
                  trailing: Text(
                    Fx.format(balances[a.id] ?? a.openingBalanceCents, a.currency),
                    style: JType.rowMetric.copyWith(color: (balances[a.id] ?? 0) < 0 ? c.expense : c.ink),
                  ),
                  onTap: () => _edit(context, ref, account: a),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, {Account? account}) => showJSheet<void>(
    context,
    title: account == null ? 'New *account*' : 'Edit *account*',
    child: _AccountForm(account: account),
  );
}

class _AccountForm extends ConsumerStatefulWidget {
  const _AccountForm({this.account});

  final Account? account;

  @override
  ConsumerState<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends ConsumerState<_AccountForm> {
  late final _name = TextEditingController(text: widget.account?.name ?? '');
  late final _opening = TextEditingController(
    text: widget.account == null ? '' : Money.plain(widget.account!.openingBalanceCents).replaceAll(',', ''),
  );
  late AccountKind _kind = widget.account?.kind ?? AccountKind.checking;
  late bool _archived = widget.account?.archived ?? false;
  late String _currency = widget.account?.currency ?? baseCurrency;

  /// An account's currency is fixed once it has entries: changing it would
  /// re-read every past amount in the new currency (LBP 1,000 → $1,000).
  bool _currencyLocked = false;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    if (a != null) {
      final db = ref.read(databaseProvider);
      db
          .customSelect(
            'SELECT COUNT(*) AS n FROM transactions WHERE deleted_at IS NULL AND (account_id = ? OR to_account_id = ?)',
            variables: [Variable.withString(a.id), Variable.withString(a.id)],
          )
          .getSingle()
          .then((r) {
            if (mounted && r.read<int>('n') > 0) setState(() => _currencyLocked = true);
          });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _opening.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.read(ledgerProvider);
    final account = widget.account;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (account != null && !account.archived) ...[
          JButton(
            label: 'Check balance',
            icon: Icons.fact_check_outlined,
            kind: JButtonKind.secondary,
            expand: true,
            onPressed: () {
              // This sheet closes first: the check opens on the same navigator.
              final nav = Navigator.of(context);
              final root = nav.context;
              nav.pop();
              showBalanceCheck(root, account);
            },
          ),
          const SizedBox(height: JSpace.lg),
        ],
        JField(
          label: 'Name',
          child: TextField(controller: _name, autofocus: widget.account == null),
        ),
        JField(
          label: 'Kind',
          child: Wrap(
            spacing: JSpace.sm,
            runSpacing: JSpace.sm,
            children: [
              for (final k in AccountKind.values)
                JChip(
                  label: '${k.name[0].toUpperCase()}${k.name.substring(1)}',
                  selected: k == _kind,
                  leading: Icon(AccountsScreen.iconFor(k), size: 15, color: context.jc.inkFaint),
                  onTap: () => setState(() => _kind = k),
                ),
            ],
          ),
        ),
        JField(
          label: 'Currency',
          child: Wrap(
            spacing: JSpace.sm,
            runSpacing: JSpace.sm,
            children: [
              for (final code in ref.watch(ratesProvider).keys)
                if (!_currencyLocked || code == _currency)
                  JChip(
                    label: code,
                    selected: code == _currency,
                    onTap: _currencyLocked ? () {} : () => setState(() => _currency = code),
                  ),
            ],
          ),
        ),
        if (_currencyLocked)
          Padding(
            padding: const EdgeInsets.only(bottom: JSpace.lg),
            child: Text(
              'Currency is fixed because this account has entries. Create a new account for another currency.',
              style: JType.body.copyWith(fontSize: 12, color: context.jc.inkFaint),
            ),
          ),
        JField(
          label: 'Opening balance',
          child: MoneyField(controller: _opening, hint: '0.00 — negative for card debt', allowNegative: true),
        ),
        if (widget.account != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Archived', style: JType.rowTitle.copyWith(color: context.jc.ink)),
            subtitle: Text('Hidden from pickers, history kept', style: JType.body.copyWith(color: context.jc.inkFaint)),
            value: _archived,
            onChanged: (v) => setState(() => _archived = v),
          ),
        const SizedBox(height: JSpace.sm),
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => JButton(
            label: 'Save account',
            expand: true,
            onPressed: _name.text.trim().isEmpty
                ? null
                : () async {
                    await ledger.upsertAccount(
                      AccountsCompanion(
                        id: widget.account == null ? const Value.absent() : Value(widget.account!.id),
                        name: Value(_name.text.trim()),
                        kind: Value(_kind),
                        openingBalanceCents: Value(Money.parse(_opening.text) ?? 0),
                        archived: Value(_archived),
                        // New accounts go to the end of the list.
                        sort: widget.account == null
                            ? Value(ref.read(allAccountsProvider).value?.length ?? 0)
                            : const Value.absent(),
                        currency: Value(_currency),
                      ),
                    );
                    if (context.mounted) Navigator.of(context).pop();
                  },
          ),
        ),
      ],
    );
  }
}
