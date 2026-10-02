import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/add/entry_sheet.dart';
import 'package:juno/features/assistant/assistant.dart';
import 'package:juno/features/assistant/assistant_tools.dart';
import 'package:juno/features/settings/ai_screen.dart' show aiAssistProvider;

/// Lives as long as the app, so leaving the screen keeps the conversation.
final assistantProvider = Provider<Assistant>(
  (ref) => Assistant(ref.watch(aiAssistProvider), ref.watch(ledgerProvider)),
);

const _starters = [
  'How am I doing this month?',
  'Log 12 coffee and 40 groceries for the house',
  'What can I still spend this month?',
  'Where did most of my money go last month?',
  'Personal vs household so far this year',
  'Which subscriptions and bills do I have?',
];

const _lookupLabels = {
  'summary': 'totals',
  'category_spending': 'categories',
  'find_entries': 'entries',
  'top_merchants': 'merchants',
  'budgets': 'budgets',
  'accounts': 'accounts',
  'goals': 'goals',
  'recurring': 'recurring',
  'safe_to_spend': 'month plan',
  'draft_entry': 'new entry',
};

class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!_scroll.hasClients) return;
    unawaited(_scroll.animateTo(_scroll.position.maxScrollExtent, duration: JMotion.medium, curve: JMotion.ease));
  });

  Future<void> _send([String? text]) async {
    final a = ref.read(assistantProvider);
    final q = (text ?? _input.text).trim();
    if (q.isEmpty || a.busy) return;
    _input.clear();
    final asking = a.ask(q);
    setState(() {});
    _toEnd();
    await asking;
    if (!mounted) return;
    setState(() {});
    _toEnd();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    ref.watch(syncEngineProvider.select((s) => s.phase));
    final ai = ref.watch(aiAssistProvider);
    final a = ref.watch(assistantProvider);
    final wide = MediaQuery.sizeOf(context).width >= JSize.wideBreakpoint;
    final hPad = wide ? JSpace.pageWide : JSpace.page;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(hPad - 8, JSpace.sm, hPad - 8, 0),
      child: Row(
        children: [
          JIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back',
            onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
          ),
          const Spacer(),
          if (a.lines.isNotEmpty)
            JIconButton(
              icon: Icons.add_comment_outlined,
              tooltip: 'New conversation',
              onPressed: a.busy ? null : () => setState(a.reset),
            ),
        ],
      ),
    );

    final intro = ListView(
      padding: EdgeInsets.fromLTRB(hPad, JSpace.md, hPad, JSpace.lg),
      children: [
        const JEyebrow('Assistant'),
        const SizedBox(height: 10),
        const JTitle('Ask about your *money*', style: JType.screenTitle),
        const SizedBox(height: 10),
        Text(
          'Juno looks up the answer on this device and sends ${ai.provider.label} only the figures it needs — '
          'totals, and matching entries when you ask about specific ones. It can read, never change anything.',
          style: JType.body.copyWith(fontSize: 14.5, color: c.inkMuted),
        ),
        const SizedBox(height: JSpace.xl),
        if (!ai.enabled)
          JCard(
            accent: JAccent.warn,
            title: 'Sign in to use the assistant',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The assistant runs through your Juno account. Sign in under Cloud sync and it works here '
                  'and on your other devices.',
                  style: JType.body.copyWith(fontSize: 13.5, color: c.ink),
                ),
                const SizedBox(height: JSpace.md),
                JButton(label: 'Cloud sync', dense: true, onPressed: () => context.go('/settings/sync')),
              ],
            ),
          )
        else
          Wrap(
            spacing: JSpace.sm,
            runSpacing: JSpace.sm,
            children: [
              for (final s in _starters) JChip(label: s, selected: false, onTap: () => _send(s)),
            ],
          ),
      ],
    );

    final transcript = ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(hPad, JSpace.md, hPad, JSpace.lg),
      itemCount: a.lines.length + (a.busy ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == a.lines.length) return const _Thinking();
        return _Bubble(line: a.lines[i]);
      },
    );

    final composer = Padding(
      padding: EdgeInsets.fromLTRB(hPad, JSpace.sm, hPad, JSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              enabled: ai.enabled,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              style: JType.body.copyWith(fontSize: 15, color: c.ink),
              decoration: const InputDecoration(hintText: 'Ask anything about your money'),
            ),
          ),
          const SizedBox(width: JSpace.sm),
          JIconButton(
            icon: Icons.arrow_upward_rounded,
            tooltip: 'Send',
            color: c.brand,
            onPressed: ai.enabled && !a.busy ? _send : null,
          ),
        ],
      ),
    );

    final meter = Padding(
      padding: EdgeInsets.fromLTRB(hPad, 0, hPad, JSpace.sm),
      child: Text(
        ai.enabled
            ? '${ai.sourceLabel} · ${ai.model} · ${_usd(ai.spentMicros)} of ${_usd(ai.budgetCents * 10000)} this month'
            : 'Off — no requests are made',
        style: JType.microLabel.copyWith(color: c.inkFaint),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                header,
                Expanded(child: a.lines.isEmpty && !a.busy ? intro : transcript),
                Container(height: 1, color: c.hairline),
                composer,
                meter,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dollars from micro-dollars, with cents shown below a dollar.
String _usd(int micros) {
  final d = micros / 1e6;
  return d < 10 ? '\$${d.toStringAsFixed(2)}' : '\$${d.round()}';
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.line});

  final ChatLine line;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final user = line.fromUser;
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: user ? c.tint(c.brand) : c.surface,
        borderRadius: BorderRadius.circular(JRadius.row),
        border: Border.all(color: line.failed ? c.warn.withValues(alpha: 0.5) : c.hairline),
      ),
      child: SelectableText(line.text, style: JType.body.copyWith(fontSize: 15, color: c.ink, height: 1.45)),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: JSpace.md),
      child: Column(
        crossAxisAlignment: user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          FractionallySizedBox(
            widthFactor: 0.86,
            alignment: user ? Alignment.centerRight : Alignment.centerLeft,
            child: Align(alignment: user ? Alignment.centerRight : Alignment.centerLeft, child: bubble),
          ),
          for (final d in line.drafts) _DraftCard(draft: d),
          if (line.looked.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                'LOOKED AT · ${line.looked.map((t) => _lookupLabels[t] ?? t).join(' · ')}'.toUpperCase(),
                style: JType.microLabel.copyWith(color: c.inkFaint),
              ),
            ),
        ],
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return Padding(
      padding: const EdgeInsets.only(bottom: JSpace.md, left: 4),
      child: Row(
        children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: c.brand)),
          const SizedBox(width: 10),
          Text('LOOKING IT UP', style: JType.microLabel.copyWith(color: c.inkMuted)),
        ],
      ),
    );
  }
}

/// An entry the assistant prepared. Nothing is saved until Log is tapped.
class _DraftCard extends ConsumerStatefulWidget {
  const _DraftCard({required this.draft});

  final EntryDraft draft;

  @override
  ConsumerState<_DraftCard> createState() => _DraftCardState();
}

class _DraftCardState extends ConsumerState<_DraftCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final d = widget.draft;
    final a = ref.read(assistantProvider);
    final cat = ref.watch(categoryMapProvider)[d.categoryId];
    final account = ref.watch(accountMapProvider)[d.accountId];
    final logged = d.loggedId != null;
    final income = d.type == TxType.income;
    return Padding(
      padding: const EdgeInsets.only(top: JSpace.sm),
      child: FractionallySizedBox(
        widthFactor: 0.86,
        alignment: Alignment.centerLeft,
        child: JCard(
          accent: logged ? JAccent.income : JAccent.brand,
          title: logged ? 'Logged' : 'New ${income ? 'income' : 'expense'} · not saved yet',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    categoryIcon(cat?.icon),
                    size: 18,
                    color: cat == null ? c.inkFaint : seriesColor(c, cat.colorIndex),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      d.note.isNotEmpty ? d.note : cat?.name ?? 'No category',
                      style: JType.rowTitle.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: JSpace.sm),
                  Text(
                    '${income ? '+' : ''}${Fx.format(d.amountCents, d.currency)}',
                    style: JType.rowMetric.copyWith(color: income ? c.income : c.ink),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                [
                  if (d.note.isNotEmpty) cat?.name ?? 'No category',
                  d.scope.label,
                  account?.name ?? 'Account',
                  Day.relative(d.day),
                ].join(' · '),
                style: JType.body.copyWith(fontSize: 13, color: c.inkMuted),
              ),
              const SizedBox(height: JSpace.md),
              Wrap(
                spacing: JSpace.sm,
                runSpacing: JSpace.sm,
                children: logged
                    ? [
                        JButton(
                          label: 'Undo',
                          kind: JButtonKind.ghost,
                          dense: true,
                          onPressed: _busy ? null : () => _run(() => a.unlog(d)),
                        ),
                      ]
                    : [
                        JButton(
                          label: 'Log',
                          icon: Icons.check_rounded,
                          dense: true,
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await a.log(d);
                                  unawaited(HapticFeedback.lightImpact());
                                }),
                        ),
                        JButton(
                          label: 'Edit',
                          kind: JButtonKind.ghost,
                          dense: true,
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  final since = DateTime.now().toUtc();
                                  await showEntrySheet(
                                    context,
                                    prefill: EntryPrefill(
                                      type: d.type,
                                      amountCents: d.amountCents,
                                      categoryId: d.categoryId,
                                      accountId: d.accountId,
                                      scope: d.scope,
                                      note: d.note,
                                      day: d.day,
                                    ),
                                  );
                                  await a.adoptEdited(d, since);
                                }),
                        ),
                      ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
