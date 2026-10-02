import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a balance difference is put right.
enum BalanceFix {
  /// Log it as an entry dated today: money that was spent (or received) and
  /// never logged. It counts in spending and income.
  entry,

  /// Move the opening balance: Juno started from the wrong number. History
  /// and spending stay as they are.
  opening,
}

/// Tag on balance-check entries, so they can be found and filtered.
const adjustmentTag = 'balance-check';

/// When an account was last checked, kept on this device.
abstract final class BalanceChecks {
  static String _key(String accountId) => 'balance.checked.$accountId';

  static DateTime? last(SharedPreferences prefs, String accountId) {
    final v = prefs.getString(_key(accountId));
    return v == null ? null : DateTime.tryParse(v);
  }

  static Future<void> mark(SharedPreferences prefs, String accountId, DateTime at) =>
      prefs.setString(_key(accountId), at.toIso8601String());
}

/// Makes Juno's balance for [account] equal [actual] (in the account's own
/// currency, cents). [current] is Juno's balance now. Returns the difference
/// that was applied (actual − current); 0 means nothing changed.
Future<int> applyBalanceCheck(
  Ledger ledger,
  Account account, {
  required int actual,
  required int current,
  required BalanceFix fix,
  DateTime? now,
}) async {
  final diff = actual - current;
  if (diff == 0) return 0;
  switch (fix) {
    case BalanceFix.entry:
      await ledger.addTransaction(
        TransactionsCompanion.insert(
          type: diff < 0 ? TxType.expense : TxType.income,
          scope: Scope.personal,
          amountCents: diff.abs(),
          accountId: account.id,
          occurredOn: Day.of(now ?? DateTime.now()),
          note: const Value('Balance check'),
          tags: Value(EntryTags.store([adjustmentTag])),
        ),
      );
    case BalanceFix.opening:
      // Only the opening balance, against the row as it is now — the sheet's
      // copy of [account] may be stale if sync brought changes meanwhile.
      await ledger.adjustOpeningBalance(account.id, diff);
  }
  return diff;
}

/// "What's really in it?" — enter the real balance, see the difference,
/// choose how to fix it.
class BalanceCheckSheet extends ConsumerStatefulWidget {
  const BalanceCheckSheet({required this.account, super.key});

  final Account account;

  @override
  ConsumerState<BalanceCheckSheet> createState() => _BalanceCheckSheetState();
}

class _BalanceCheckSheetState extends ConsumerState<BalanceCheckSheet> {
  final _actual = TextEditingController();
  late BalanceFix _fix = widget.account.kind == AccountKind.cash ? BalanceFix.entry : BalanceFix.opening;
  bool _busy = false;

  @override
  void dispose() {
    _actual.dispose();
    super.dispose();
  }

  Future<void> _apply(int current) async {
    final actual = Money.parse(_actual.text);
    if (actual == null || _busy) return;
    setState(() => _busy = true);
    final a = widget.account;
    final diff = await applyBalanceCheck(ref.read(ledgerProvider), a, actual: actual, current: current, fix: _fix);
    await BalanceChecks.mark(ref.read(prefsProvider), a.id, DateTime.now());
    if (!mounted) return;
    Navigator.of(context).pop();
    showToast(
      diff == 0
          ? '${a.name} matches — nothing to fix'
          : _fix == BalanceFix.entry
          ? 'Logged ${Fx.format(diff.abs(), a.currency)} ${diff < 0 ? 'of spending' : 'coming in'} on ${a.name}'
          : 'Starting balance of ${a.name} corrected by ${Fx.format(diff, a.currency)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final a = widget.account;
    final current = ref.watch(balancesProvider).value?[a.id] ?? a.openingBalanceCents;
    return ListenableBuilder(
      listenable: _actual,
      builder: (context, _) {
        final actual = Money.parse(_actual.text);
        final diff = actual == null ? null : actual - current;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Juno has ${Fx.format(current, a.currency)} in ${a.name}. Count what’s really there and enter it.',
              style: JType.body.copyWith(fontSize: 14, color: c.inkMuted),
            ),
            const SizedBox(height: JSpace.lg),
            JField(
              label: 'Real balance (${a.currency})',
              child: TextField(
                controller: _actual,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                style: JType.cardMetric.copyWith(color: c.ink),
                decoration: InputDecoration(hintText: Fx.format(current, a.currency)),
              ),
            ),
            if (diff != null && diff != 0) ...[
              Text(
                diff < 0
                    ? '${Fx.format(-diff, a.currency)} less than Juno expects'
                    : '${Fx.format(diff, a.currency)} more than Juno expects',
                style: JType.rowTitle.copyWith(color: diff < 0 ? c.expense : c.income),
              ),
              const SizedBox(height: JSpace.md),
              for (final (fix, title, body) in [
                (
                  BalanceFix.entry,
                  diff < 0 ? 'Log it as spending' : 'Log it as money in',
                  'An entry dated today, tagged #$adjustmentTag. Use this for cash spent without logging.',
                ),
                (
                  BalanceFix.opening,
                  'Correct the starting balance',
                  'Spending and income stay as they are. Use this if Juno started from the wrong number.',
                ),
              ])
                RadioListTile<BalanceFix>(
                  contentPadding: EdgeInsets.zero,
                  value: fix,
                  // ignore: deprecated_member_use, RadioGroup isn't in this Flutter's stable API yet
                  groupValue: _fix,
                  // ignore: deprecated_member_use, see above
                  onChanged: (v) => setState(() => _fix = v ?? _fix),
                  title: Text(title, style: JType.rowTitle.copyWith(color: c.ink)),
                  subtitle: Text(body, style: JType.body.copyWith(fontSize: 12.5, color: c.inkFaint)),
                ),
            ] else if (diff == 0)
              Text('Matches — nothing to fix.', style: JType.rowTitle.copyWith(color: c.income)),
            const SizedBox(height: JSpace.lg),
            JButton(
              label: diff == null || diff == 0 ? 'Mark as checked' : 'Fix the balance',
              expand: true,
              onPressed: actual == null || _busy ? null : () => _apply(current),
            ),
          ],
        );
      },
    );
  }
}

Future<void> showBalanceCheck(BuildContext context, Account account) => showJSheet<void>(
  context,
  title: 'Check *${account.name}*',
  child: BalanceCheckSheet(account: account),
);
