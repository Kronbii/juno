import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';

final aiAssistProvider = Provider<AiAssist>((ref) => AiAssist(ref.watch(prefsProvider)));

class AiScreen extends ConsumerStatefulWidget {
  const AiScreen({super.key});

  @override
  ConsumerState<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends ConsumerState<AiScreen> {
  late AiProvider _provider = ref.read(aiAssistProvider).provider;
  late final _key = TextEditingController(text: _stored(AiAssist.keyPrefFor(_provider)));
  late final _model = TextEditingController(text: _stored(AiAssist.modelPrefFor(_provider)));
  late int _budget = ref.read(aiAssistProvider).budgetCents;
  bool _show = false;

  static const _budgets = {100: r'$1', 200: r'$2', 500: r'$5', 1000: r'$10'};

  String _stored(String key) => ref.read(prefsProvider).getString(key) ?? '';

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  void _pick(AiProvider p) => setState(() {
    _provider = p;
    _key.text = _stored(AiAssist.keyPrefFor(p));
    _model.text = _stored(AiAssist.modelPrefFor(p));
  });

  Future<void> _save() async {
    final prefs = ref.read(prefsProvider);
    Future<void> put(String key, String v) => v.isEmpty ? prefs.remove(key) : prefs.setString(key, v);
    final k = _key.text.trim();
    await put(AiAssist.keyPrefFor(_provider), k);
    await put(AiAssist.modelPrefFor(_provider), _model.text.trim());
    await prefs.setString(AiAssist.providerPref, _provider.name);
    await prefs.setInt(AiAssist.budgetPref, _budget);
    showToast(k.isEmpty ? 'AI assist off' : 'AI assist on — ${_provider.label}, up to ${_budgets[_budget]} a month');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final ai = ref.watch(aiAssistProvider);
    final spent = ai.spentMicros / 1e6;
    return JScreen(
      eyebrow: 'Settings · AI assist',
      title: 'A little *extra* help',
      subtitle:
          'Optional. Juno works fully on-device; with your own API key it can also answer questions about your '
          'money, read messy receipts and write a short monthly read.',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              JCard(
                accent: JAccent.warn,
                title: 'Before you add a key',
                child: Text(
                  'Chat subscriptions such as ChatGPT Plus don’t include API access — the key needs API billing '
                  'at ${_provider.keysAt} (a few dollars of credit lasts a long time here). Juno sends receipt '
                  'text, a month’s totals, or — when you ask the assistant — the figures and matching entries it '
                  'looked up. Never photos or your whole history. The key stays on this device.',
                  style: JType.body.copyWith(fontSize: 13.5, color: c.ink),
                ),
              ),
              const SizedBox(height: JSpace.lg),
              JField(
                label: 'Provider',
                child: DropdownButtonFormField<AiProvider>(
                  initialValue: _provider,
                  isExpanded: true,
                  dropdownColor: c.raised,
                  borderRadius: BorderRadius.circular(JRadius.chip),
                  style: JType.body.copyWith(fontSize: 15, color: c.ink),
                  items: [
                    for (final p in AiProvider.values)
                      DropdownMenuItem(
                        value: p,
                        child: Text(p == AiProvider.openai ? '${p.label} (recommended)' : p.label),
                      ),
                  ],
                  onChanged: (p) => p == null ? null : _pick(p),
                ),
              ),
              if (_provider.chinaBased)
                Padding(
                  padding: const EdgeInsets.only(bottom: JSpace.lg),
                  child: Text(
                    '${_provider.label} is run by a company based in China; what Juno sends is handled under '
                    'Chinese law.',
                    style: JType.body.copyWith(fontSize: 13, color: c.warn),
                  ),
                ),
              JField(
                label: '${_provider.label} API key',
                child: TextField(
                  controller: _key,
                  obscureText: !_show,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: JType.chipLabel.copyWith(fontSize: 14, color: c.ink),
                  decoration: InputDecoration(
                    hintText: _provider.keyHint,
                    suffixIcon: IconButton(
                      tooltip: _show ? 'Hide' : 'Show',
                      icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                      onPressed: () => setState(() => _show = !_show),
                    ),
                  ),
                ),
              ),
              JField(
                label: 'Model',
                child: TextField(
                  controller: _model,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: JType.chipLabel.copyWith(fontSize: 14, color: c.ink),
                  decoration: InputDecoration(hintText: '${_provider.defaultModel} (default)'),
                ),
              ),
              JField(
                label: 'Monthly limit',
                child: JSegmentBar<int>(
                  segments: _budgets,
                  selected: _budgets.containsKey(_budget) ? _budget : AiAssist.defaultBudgetCents,
                  onChanged: (v) => setState(() => _budget = v),
                ),
              ),
              Text(
                ai.enabled
                    ? '\$${spent.toStringAsFixed(2)} of \$${(ai.budgetCents / 100).toStringAsFixed(0)} used this '
                          'month · ${ai.callsThisMonth} requests · ${ai.provider.label} ${ai.model}'
                    : 'Off — no requests are made.',
                style: JType.chipLabel.copyWith(color: c.inkMuted),
              ),
              const SizedBox(height: JSpace.lg),
              JButton(label: 'Save', expand: true, onPressed: _save),
            ],
          ),
        ),
      ],
    );
  }
}
