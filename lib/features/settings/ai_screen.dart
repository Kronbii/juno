import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';

/// Stable for the app's life (the assistant keeps its conversation); it reads
/// prefs and the sign-in state on every call, so it never goes stale.
final aiAssistProvider = Provider<AiAssist>(
  (ref) => AiAssist(ref.watch(prefsProvider), cloud: SyncEngine.configured ? const SupabaseAiCloud() : null),
);

class AiScreen extends ConsumerStatefulWidget {
  const AiScreen({super.key});

  @override
  ConsumerState<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends ConsumerState<AiScreen> {
  late AiProvider _provider = ref.read(aiAssistProvider).chosenProvider;
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
    final ai = ref.read(aiAssistProvider);
    showToast(
      k.isNotEmpty
          ? 'Using your ${_provider.label} key on this device, up to ${_budgets[_budget]} a month'
          : ai.usingCloud
          ? 'Using Juno cloud'
          : 'AI off on this device',
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    ref.watch(syncEngineProvider.select((s) => s.phase));
    final ai = ref.watch(aiAssistProvider);
    final spent = ai.spentMicros / 1e6;
    final cloudReady = ai.cloud?.available ?? false;
    return JScreen(
      eyebrow: 'Settings · AI assist',
      title: 'A little *extra* help',
      subtitle: 'The assistant, receipt reading and the monthly read. Juno works fully on-device without them.',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              JCard(
                accent: cloudReady ? JAccent.income : JAccent.warn,
                title: cloudReady ? 'On — Juno cloud' : 'Sign in to turn it on',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cloudReady
                          ? 'Works on every device you’re signed in to, with no key to enter. Juno sends receipt '
                                'text, a month’s totals, or the figures the assistant looked up — never photos or '
                                'your whole history.'
                          : 'AI runs through your Juno account. Sign in under Cloud sync and it works here and on '
                                'your other devices, with no key to enter.',
                      style: JType.body.copyWith(fontSize: 13.5, color: c.ink),
                    ),
                    if (cloudReady && ai.usingCloud) ...[
                      const SizedBox(height: JSpace.md),
                      Text(
                        '\$${spent.toStringAsFixed(2)} of \$${(ai.budgetCents / 100).toStringAsFixed(0)} this month · '
                        '${ai.callsThisMonth} requests here · ${ai.model}',
                        style: JType.chipLabel.copyWith(color: c.inkMuted),
                      ),
                    ],
                    if (!cloudReady) ...[
                      const SizedBox(height: JSpace.md),
                      JButton(label: 'Cloud sync', dense: true, onPressed: () => context.go('/settings/sync')),
                    ],
                  ],
                ),
              ),
              const JSectionLabel('Your own key (optional)'),
              Padding(
                padding: const EdgeInsets.only(bottom: JSpace.lg),
                child: Text(
                  'Overrides Juno cloud on this device only. API keys need API billing at ${_provider.keysAt} — chat '
                  'subscriptions such as ChatGPT Plus don’t include it. The key stays on this device.',
                  style: JType.body.copyWith(fontSize: 13, color: c.inkMuted),
                ),
              ),
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
                label: 'Monthly limit for your own key',
                child: JSegmentBar<int>(
                  segments: _budgets,
                  selected: _budgets.containsKey(_budget) ? _budget : AiAssist.defaultBudgetCents,
                  onChanged: (v) => setState(() => _budget = v),
                ),
              ),
              if (ai.apiKey != null)
                Text(
                  '\$${spent.toStringAsFixed(2)} of \$${(ai.budgetCents / 100).toStringAsFixed(0)} used this '
                  'month · ${ai.callsThisMonth} requests · ${ai.provider.label} ${ai.model}',
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
