import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';

/// Exchange rates against USD. Juno never fetches rates on its own — in
/// Lebanon the rate that matters is the one you actually get, so you set it.
class CurrenciesScreen extends ConsumerWidget {
  const CurrenciesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final rates = ref.watch(ratesListProvider).value ?? const <CurrencyRate>[];
    final used = rates.map((r) => r.code).toSet();
    return JScreen(
      eyebrow: 'Settings · Currencies',
      title: 'What a dollar *buys*',
      subtitle: 'Totals are in USD. Accounts in other currencies convert at these rates when you log an entry.',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
        JIconButton(
          icon: Icons.add_rounded,
          tooltip: 'Add currency',
          onPressed: () =>
              _edit(context, ref, codes: currencies.keys.where((k) => k != baseCurrency && !used.contains(k))),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: JGroup(
            children: [
              const JSettingRow(icon: Icons.attach_money_rounded, title: 'USD', subtitle: 'Base currency', value: '1'),
              for (final r in rates)
                JSettingRow(
                  icon: Icons.currency_exchange_rounded,
                  title: r.code,
                  subtitle: currencyInfo(r.code).name,
                  trailing: Text(
                    '${_fmt(r.perUsd)} / \$1',
                    style: JType.rowMetric.copyWith(color: c.ink),
                  ),
                  onTap: () => _edit(context, ref, code: r.code, current: r.perUsd),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static String _fmt(double v) => v >= 100
      ? v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',')
      : v.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, {
    String? code,
    double? current,
    Iterable<String> codes = const [],
  }) async {
    var selected = code ?? codes.firstOrNull;
    if (selected == null) return;
    final ctrl = TextEditingController(text: current == null ? '' : _fmt(current).replaceAll(',', ''));
    await showJSheet<void>(
      context,
      title: code == null ? 'Add a *currency*' : 'Rate for *$code*',
      child: StatefulBuilder(
        builder: (context, setState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (code == null)
              JField(
                label: 'Currency',
                child: Wrap(
                  spacing: JSpace.sm,
                  runSpacing: JSpace.sm,
                  children: [
                    for (final k in codes)
                      JChip(label: k, selected: k == selected, onTap: () => setState(() => selected = k)),
                  ],
                ),
              ),
            JField(
              label: '$selected per 1 USD',
              child: TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9.]'))],
                style: JType.cardMetric.copyWith(color: context.jc.ink),
              ),
            ),
            ListenableBuilder(
              listenable: ctrl,
              builder: (context, _) {
                final v = double.tryParse(ctrl.text);
                return JButton(
                  label: 'Save rate',
                  expand: true,
                  onPressed: v == null || v <= 0
                      ? null
                      : () async {
                          await ref.read(ledgerProvider).setRate(selected!, v);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                );
              },
            ),
            const SizedBox(height: JSpace.sm),
            Text(
              'Changing a rate affects new entries only; past entries keep the USD value they were logged with.',
              style: JType.body.copyWith(fontSize: 12, color: context.jc.inkFaint),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
  }
}
