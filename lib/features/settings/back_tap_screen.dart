import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/deeplink/deep_link_handler.dart';
import 'package:juno/core/deeplink/quick_add.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';

/// How to wire iPhone Back Tap → Shortcut → `juno://add`, plus a tester that
/// fires a link inside the app (handy on desktop, where the OS can't).
class BackTapScreen extends ConsumerStatefulWidget {
  const BackTapScreen({super.key});

  @override
  ConsumerState<BackTapScreen> createState() => _BackTapScreenState();
}

class _BackTapScreenState extends ConsumerState<BackTapScreen> {
  final _link = TextEditingController(text: 'juno://add?amount=4.50&note=Kalei%20coffee&scope=personal');

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    // Loaded while you're here, so "Run link" saves at once.
    ref
      ..watch(categoriesProvider)
      ..watch(accountsProvider);

    Widget step(int n, String title, String body, {Widget? extra}) => Padding(
      padding: const EdgeInsets.only(bottom: JSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.hairlineStrong),
            ),
            child: Text('$n', style: JType.chipLabel.copyWith(color: c.ink)),
          ),
          const SizedBox(width: JSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: JType.rowTitle.copyWith(color: c.ink)),
                const SizedBox(height: 4),
                Text(body, style: JType.body.copyWith(color: c.inkMuted, fontSize: 13.5)),
                if (extra != null) ...[const SizedBox(height: JSpace.sm), extra],
              ],
            ),
          ),
        ],
      ),
    );

    Widget code(String s) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.hairline),
      ),
      child: SelectableText(s, style: JType.chipLabel.copyWith(color: c.ink, height: 1.5)),
    );

    return JScreen(
      eyebrow: 'Settings · Back Tap',
      title: 'Double-tap, *logged*',
      subtitle:
          'Your iPhone can run a Shortcut when you double-tap its back. Point it at Juno and an expense takes four seconds.',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              JCard(
                title: 'Fastest: no app opening',
                accent: JAccent.income,
                child: Text(
                  'Juno adds its own “Log expense” action to the Shortcuts app. Make a shortcut with just that '
                  'action, attach it to Back Tap (Settings → Accessibility → Touch → Back Tap), and a double tap '
                  'asks for the amount and category and logs it — Juno stays closed and imports it next time you '
                  'open it. Siri works too: “Log an expense in Juno”.',
                  style: JType.body.copyWith(fontSize: 13.5, color: c.inkMuted),
                ),
              ),
              const SizedBox(height: JSpace.gap),
              JCard(
                title: 'The link Shortcut: you say what, Juno files it',
                accent: JAccent.brand,
                child: Column(
                  children: [
                    step(1, 'New Shortcut', 'Open Shortcuts → + → name it “Log expense”.'),
                    step(2, 'Ask for Input — amount', 'Add “Ask for Input”, type Number, prompt “Amount”.'),
                    step(
                      3,
                      'Ask for Input — what was it',
                      'Add another “Ask for Input”, type Text, prompt “What was it?”. Type or dictate a few '
                          'words, like “kalei coffee” or “spinneys”.',
                    ),
                    step(
                      4,
                      'Choose from List — who for',
                      'Add a “List” with Personal, Household and Other, then “Choose from List”.',
                    ),
                    step(5, 'URL Encode', 'Add “URL Encode” on the text from step 3, so spaces survive the link.'),
                    step(
                      6,
                      'Open the link',
                      'Add “URL” with the text below, inserting the three variables, then “Open URLs”.',
                      extra: code('juno://add?amount=[Provided Input]&note=[URL Encoded Text]&scope=[Chosen Item]'),
                    ),
                    step(
                      7,
                      'Attach to Back Tap',
                      'Settings → Accessibility → Touch → Back Tap → Double Tap → “Log expense”.',
                    ),
                    Text(
                      'Juno picks the category from what you wrote: the same words filed before go where they '
                      'went last time (and follow your corrections), common words are matched on the phone, and '
                      'only new ones go to the AI. Offline, the entry is saved and filed once you are back online.',
                      style: JType.body.copyWith(color: c.inkMuted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: JSpace.gap),
              JCard(
                title: 'Link reference',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    code(
                      'juno://add\n'
                      '  ?amount=12.50        number, saved directly\n'
                      '  &note=Spinneys       what it was\n'
                      '  &scope=household     personal | household | other\n'
                      '  &category=Groceries  optional: fuzzy-matched by name;\n'
                      '                       leave out to file it from the note\n'
                      '  &account=Cash        optional, else first account\n'
                      '  &type=income         optional, else from category\n'
                      '  &date=2026-10-01     optional, or "yesterday"\n'
                      '  &confirm=1           open the sheet instead of saving',
                    ),
                    const SizedBox(height: JSpace.md),
                    Text(
                      'No amount opens the add sheet so you can type it in the app. Each save shows a toast with Undo.',
                      style: JType.body.copyWith(color: c.inkMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: JSpace.gap),
              JCard(
                title: 'Try a link',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _link,
                      style: JType.chipLabel.copyWith(color: c.ink, fontSize: 13),
                    ),
                    const SizedBox(height: JSpace.md),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: JButton(
                        label: 'Run link',
                        icon: Icons.play_arrow_rounded,
                        dense: true,
                        onPressed: () {
                          final uri = Uri.tryParse(_link.text.trim());
                          if (uri == null || QuickAdd.parse(uri) == null) {
                            showToast('Not a quick-add link — it must start with juno://add');
                            return;
                          }
                          handleQuickAdd(ref, uri);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
