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
  late final _key = TextEditingController(text: ref.read(prefsProvider).getString(AiAssist.keyPref) ?? '');
  late int _cap = ref.read(aiAssistProvider).cap;
  bool _show = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final prefs = ref.read(prefsProvider);
    final k = _key.text.trim();
    if (k.isEmpty) {
      await prefs.remove(AiAssist.keyPref);
    } else {
      await prefs.setString(AiAssist.keyPref, k);
    }
    await prefs.setInt(AiAssist.capPref, _cap);
    showToast(k.isEmpty ? 'AI assist off' : 'AI assist on — up to $_cap requests a month');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final ai = ref.watch(aiAssistProvider);
    return JScreen(
      eyebrow: 'Settings · AI assist',
      title: 'A little *extra* help',
      subtitle:
          'Optional. Juno works fully on-device; with your own OpenAI API key it can also read messy receipts and write a short monthly read.',
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
                  'ChatGPT Plus doesn’t include API access — the key needs API billing at platform.openai.com '
                  '(a few dollars of prepaid credit lasts a long time here). Juno only ever sends receipt text or '
                  'a month’s totals, never your entries, notes or photos. The key stays on this device.',
                  style: JType.body.copyWith(fontSize: 13.5, color: c.ink),
                ),
              ),
              const SizedBox(height: JSpace.lg),
              JField(
                label: 'OpenAI API key',
                child: TextField(
                  controller: _key,
                  obscureText: !_show,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: JType.chipLabel.copyWith(fontSize: 14, color: c.ink),
                  decoration: InputDecoration(
                    hintText: 'sk-…',
                    suffixIcon: IconButton(
                      tooltip: _show ? 'Hide' : 'Show',
                      icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                      onPressed: () => setState(() => _show = !_show),
                    ),
                  ),
                ),
              ),
              JField(
                label: 'Monthly limit',
                child: JSegmentBar<int>(
                  segments: const {25: '25', 50: '50', 100: '100', 250: '250'},
                  selected: const [25, 50, 100, 250].contains(_cap) ? _cap : 100,
                  onChanged: (v) => setState(() => _cap = v),
                ),
              ),
              Text(
                ai.enabled
                    ? '${ai.usedThisMonth} of ${ai.cap} used this month · model ${ai.model}'
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
