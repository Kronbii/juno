import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/plan/editors.dart' show MoneyField;

/// Shown once on a fresh install: starting balances, LBP, and how to log
/// fast. Everything is optional and editable later in Settings.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  static const doneKey = 'onboarded';

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _page = PageController();
  int _index = 0;
  final _balances = <String, TextEditingController>{};
  bool _addLbp = true;
  final _lbpBalance = TextEditingController();
  final _rate = TextEditingController(text: '89500');

  @override
  void dispose() {
    _page.dispose();
    for (final c in _balances.values) {
      c.dispose();
    }
    _lbpBalance.dispose();
    _rate.dispose();
    super.dispose();
  }

  TextEditingController _ctrl(String id) => _balances.putIfAbsent(id, TextEditingController.new);

  Future<void> _finish() async {
    final ledger = ref.read(ledgerProvider);
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    for (final a in accounts) {
      final cents = Money.parse(_ctrl(a.id).text);
      if (cents != null && cents != a.openingBalanceCents) {
        await ledger.upsertAccount(
          AccountsCompanion(
            id: Value(a.id),
            name: Value(a.name),
            kind: Value(a.kind),
            currency: Value(a.currency),
            openingBalanceCents: Value(cents),
          ),
        );
      }
    }
    final rate = double.tryParse(_rate.text);
    if (rate != null && rate > 0) await ledger.setRate('LBP', rate);
    if (_addLbp && !accounts.any((a) => a.currency == 'LBP')) {
      await ledger.upsertAccount(
        AccountsCompanion.insert(
          id: Value(seedId('acct:cash-lbp-user')),
          name: 'Cash LBP',
          kind: AccountKind.cash,
          currency: const Value('LBP'),
          openingBalanceCents: Value(Money.parse(_lbpBalance.text) ?? 0),
          sort: Value(accounts.length),
        ),
      );
    }
    await ref.read(prefsProvider).setBool(OnboardingScreen.doneKey, true);
    if (mounted) Navigator.of(context).pop();
  }

  void _next() {
    if (_index == 2) {
      _finish();
      return;
    }
    _page.nextPage(duration: JMotion.medium, curve: JMotion.ease);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    Widget page(String eyebrow, String title, String body, List<Widget> children) => ListView(
      padding: const EdgeInsets.fromLTRB(JSpace.page + 4, JSpace.xl, JSpace.page + 4, JSpace.xl),
      children: [
        JEyebrow(eyebrow),
        const SizedBox(height: 10),
        JTitle(title, style: JType.screenTitle.copyWith(fontSize: 32)),
        const SizedBox(height: 10),
        Text(body, style: JType.body.copyWith(fontSize: 15, color: c.inkMuted)),
        const SizedBox(height: JSpace.xl),
        ...children,
      ],
    );

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Expanded(
                  child: PageView(
                    controller: _page,
                    onPageChanged: (i) => setState(() => _index = i),
                    children: [
                      page(
                        '01 — Welcome',
                        'Your money, *clearly*',
                        'Juno tracks what you spend on yourself and on the household, in dollars and pounds, '
                            'and tells you what it means. It all lives on this device first; sync is optional.',
                        [
                          const JWordmark(size: 56),
                          const SizedBox(height: JSpace.xl),
                          for (final (icon, text) in const [
                            (Icons.home_outlined, 'Personal and household, side by side'),
                            (Icons.currency_exchange_rounded, 'USD and LBP accounts, one total'),
                            (Icons.auto_awesome_outlined, 'Safe-to-spend, forecasts and gentle alerts'),
                            (Icons.touch_app_outlined, 'Log in seconds — Back Tap, Siri, or a sentence'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Row(
                                children: [
                                  Icon(icon, size: 20, color: c.brand),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(text, style: JType.rowTitle.copyWith(color: c.ink)),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      page(
                        '02 — Starting point',
                        'What’s in your *accounts*?',
                        'Today’s balances, so totals and net worth start right. Leave any blank for zero.',
                        [
                          for (final a in accounts.where((a) => a.currency == 'USD'))
                            JField(
                              label: a.name,
                              child: MoneyField(controller: _ctrl(a.id), allowNegative: a.kind == AccountKind.credit),
                            ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('I also keep cash in LBP', style: JType.rowTitle.copyWith(color: c.ink)),
                            value: _addLbp,
                            onChanged: (v) => setState(() => _addLbp = v),
                          ),
                          if (_addLbp && !accounts.any((a) => a.currency == 'LBP')) ...[
                            const SizedBox(height: JSpace.sm),
                            JField(
                              label: 'Cash LBP balance',
                              child: TextField(
                                controller: _lbpBalance,
                                keyboardType: TextInputType.number,
                                style: JType.cardMetric.copyWith(color: c.ink),
                                decoration: const InputDecoration(prefixText: 'LBP ', hintText: '0'),
                              ),
                            ),
                          ],
                          JField(
                            label: 'LBP per 1 USD',
                            child: TextField(
                              controller: _rate,
                              keyboardType: TextInputType.number,
                              style: JType.cardMetric.copyWith(color: c.ink),
                            ),
                          ),
                        ],
                      ),
                      page(
                        '03 — Logging fast',
                        'Three *ways* to log',
                        'Pick whichever is closest when you pay.',
                        [
                          for (final (title, body) in const [
                            (
                              'Type it',
                              'In a new entry, write “12 coffee kalei” or “40k taxi yesterday” — Juno fills in the rest.',
                            ),
                            (
                              'Back Tap or Siri',
                              'On iPhone: double-tap the back of the phone, or say “Log an expense in Juno”. Juno stays closed.',
                            ),
                            ('Snap the receipt', 'Attach a photo and Juno reads the total and the shop for you.'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(bottom: JSpace.lg),
                              child: JCard(
                                title: title,
                                child: Text(body, style: JType.body.copyWith(fontSize: 14, color: c.inkMuted)),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(JSpace.page + 4, 0, JSpace.page + 4, JSpace.lg),
                  child: Row(
                    children: [
                      for (var i = 0; i < 3; i++)
                        AnimatedContainer(
                          duration: JMotion.fast,
                          margin: const EdgeInsets.only(right: 6),
                          width: i == _index ? 22 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: i == _index ? c.brand : c.hairlineStrong,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      const Spacer(),
                      if (_index < 2)
                        JButton(
                          label: 'Skip',
                          kind: JButtonKind.ghost,
                          onPressed: () async {
                            await ref.read(prefsProvider).setBool(OnboardingScreen.doneKey, true);
                            if (context.mounted) Navigator.of(context).pop();
                          },
                        ),
                      const SizedBox(width: JSpace.sm),
                      JButton(label: _index == 2 ? 'Start' : 'Next', onPressed: _next),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
