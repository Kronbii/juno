import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/activity/tx_row.dart';
import 'package:juno/features/add/entry_sheet.dart';
import 'package:juno/features/home/home_screen.dart';

class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  static const _page = 200;

  final _search = TextEditingController();
  TxType? _type;
  Set<String> _categories = {};
  String? _accountId;
  DateTimeRange? _range;
  String? _tag;
  int _limit = _page;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  TxQuery get _query => TxQuery(
    scope: ref.watch(scopeFilterProvider),
    type: _type,
    categoryIds: _categories.isEmpty ? null : _categories,
    accountId: _accountId,
    from: _range == null ? null : Day.of(_range!.start),
    to: _range == null ? null : Day.of(_range!.end),
    search: _search.text,
    tag: _tag,
    limit: _limit,
  );

  bool get _filtered => _type != null || _categories.isNotEmpty || _accountId != null || _range != null || _tag != null;

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now.add(const Duration(days: 365)),
      initialDateRange: _range ?? DateTimeRange(start: DateTime(now.year, now.month), end: now),
    );
    if (r != null) setState(() => _range = r);
  }

  Future<void> _pickCategories() async {
    final cats = ref.read(categoriesProvider).value ?? const <Category>[];
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (_) => _CategoryFilterSheet(categories: cats, initial: _categories),
    );
    if (picked != null) setState(() => _categories = picked);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(txQueryProvider(_query));
    final totals = ref.watch(txTotalsProvider(_query.copyWith(limit: 0))).value ?? TxTotals.empty;
    final txs = async.value;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final tags = ref.watch(tagsProvider).value ?? const <(String, int)>[];

    return JScreen(
      eyebrow: '02 — Activity',
      title: 'Every *dollar*, logged',
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ScopeLens(),
          const SizedBox(height: JSpace.md),
          JSearchField(
            hint: 'Search notes and merchants',
            controller: _search,
            onChanged: (_) => setState(() => _limit = _page),
          ),
          const SizedBox(height: JSpace.md),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                JChip(
                  label: switch (_type) {
                    null => 'Any type',
                    TxType.expense => 'Expenses',
                    TxType.income => 'Income',
                    TxType.transfer => 'Transfers',
                  },
                  selected: _type != null,
                  accent: _type == TxType.income ? JAccent.income : JAccent.brand,
                  onTap: () => setState(() {
                    const order = [null, TxType.expense, TxType.income, TxType.transfer];
                    _type = order[(order.indexOf(_type) + 1) % order.length];
                  }),
                ),
                const SizedBox(width: JSpace.sm),
                JChip(
                  label: _categories.isEmpty ? 'Categories' : '${_categories.length} categories',
                  selected: _categories.isNotEmpty,
                  onTap: _pickCategories,
                ),
                const SizedBox(width: JSpace.sm),
                PopupMenuButton<String?>(
                  tooltip: 'Account',
                  onSelected: (id) => setState(() => _accountId = id == '' ? null : id),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: '', child: Text('All accounts')),
                    for (final a in accounts) PopupMenuItem(value: a.id, child: Text(a.name)),
                  ],
                  child: IgnorePointer(
                    child: JChip(
                      label: ref.watch(accountMapProvider)[_accountId]?.name ?? 'Account',
                      selected: _accountId != null,
                      onTap: () {},
                    ),
                  ),
                ),
                const SizedBox(width: JSpace.sm),
                JChip(
                  label: _range == null
                      ? 'Any date'
                      : '${Day.short(Day.of(_range!.start))} – ${Day.short(Day.of(_range!.end))}',
                  selected: _range != null,
                  onTap: _pickRange,
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(width: JSpace.sm),
                  PopupMenuButton<String>(
                    tooltip: 'Tag',
                    onSelected: (t) => setState(() => _tag = t.isEmpty ? null : t),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: '', child: Text('Any tag')),
                      for (final (t, n) in tags) PopupMenuItem(value: t, child: Text('#$t  ·  $n')),
                    ],
                    child: IgnorePointer(
                      child: JChip(label: _tag == null ? 'Tag' : '#$_tag', selected: _tag != null, onTap: () {}),
                    ),
                  ),
                ],
                if (_filtered) ...[
                  const SizedBox(width: JSpace.sm),
                  JButton(
                    label: 'Clear',
                    kind: JButtonKind.ghost,
                    dense: true,
                    onPressed: () => setState(() {
                      _type = null;
                      _categories = {};
                      _accountId = null;
                      _range = null;
                      _tag = null;
                      _search.clear();
                    }),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      slivers: [
        if (txs == null)
          const SliverToBoxAdapter(child: SizedBox(height: 200))
        else if (txs.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: JSpace.xl),
              child: JEmpty(
                icon: Icons.search_off_rounded,
                title: _filtered || _search.text.isNotEmpty ? 'Nothing matches' : 'No entries yet',
                message: _filtered || _search.text.isNotEmpty
                    ? 'Try a wider date range or clear the filters.'
                    : 'Add an entry or import a CSV from your bank.',
                action: JButton(
                  label: 'New entry',
                  icon: Icons.add_rounded,
                  dense: true,
                  onPressed: () => showEntrySheet(context),
                ),
              ),
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: _Totals(totals: totals, shown: txs.length),
          ),
          SliverSlidableGroup(txs: txs, dayTotals: totals.expenseByDay),
          if (txs.length >= _limit && totals.count > txs.length)
            SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: JSpace.lg),
                  child: JButton(
                    label: 'Load more',
                    kind: JButtonKind.secondary,
                    dense: true,
                    onPressed: () => setState(() => _limit += _page),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// Counts and sums over every matching entry — not just the loaded page.
class _Totals extends StatelessWidget {
  const _Totals({required this.totals, required this.shown});

  final TxTotals totals;
  final int shown;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return Padding(
      padding: const EdgeInsets.only(bottom: JSpace.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              shown < totals.count ? '${totals.count} ENTRIES · $shown SHOWN' : '${totals.count} ENTRIES',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: JType.microLabel.copyWith(color: c.inkFaint),
            ),
          ),
          const SizedBox(width: JSpace.sm),
          // Large text: the figures shrink before anything overflows.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              children: [
                Text('IN ', style: JType.microLabel.copyWith(color: c.inkFaint)),
                Text(Money.whole(totals.income), style: JType.chipLabel.copyWith(color: c.income)),
                const SizedBox(width: JSpace.md),
                Text('OUT ', style: JType.microLabel.copyWith(color: c.inkFaint)),
                Text(Money.whole(totals.expense), style: JType.chipLabel.copyWith(color: c.ink)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Day-grouped list: a caps date header with the day's net, then rows.
class SliverSlidableGroup extends StatelessWidget {
  const SliverSlidableGroup({required this.txs, this.dayTotals = const {}, super.key});

  final List<Transaction> txs;

  /// Each day's full money-out, so a day cut by the page edge still shows
  /// its real total.
  final Map<String, int> dayTotals;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Transaction>>{};
    for (final t in txs) {
      (groups[t.occurredOn] ??= []).add(t);
    }
    final days = groups.keys.toList();
    return SliverList.builder(
      itemCount: days.length,
      itemBuilder: (context, i) => SlidableAutoCloseBehavior(
        child: _DayGroup(day: days[i], txs: groups[days[i]]!, spentTotal: dayTotals[days[i]]),
      ),
    );
  }
}

class _DayGroup extends StatelessWidget {
  const _DayGroup({required this.day, required this.txs, this.spentTotal});

  final String day;
  final List<Transaction> txs;
  final int? spentTotal;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final spent = spentTotal ?? txs.where((t) => t.type == TxType.expense).fold<int>(0, (s, t) => s + t.usd);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: JSpace.lg, bottom: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  Day.relative(day).toUpperCase(),
                  style: JType.microLabel.copyWith(color: c.inkMuted),
                ),
              ),
              if (spent > 0)
                Text(
                  '−${Money.format(spent)}',
                  style: JType.microLabel.copyWith(color: c.inkFaint, letterSpacing: 0.4),
                ),
            ],
          ),
        ),
        Divider(color: c.hairline),
        for (var i = 0; i < txs.length; i++) ...[
          if (i > 0) Divider(color: c.hairline, indent: 52),
          TxRow(tx: txs[i]),
        ],
      ],
    );
  }
}

class _CategoryFilterSheet extends StatefulWidget {
  const _CategoryFilterSheet({required this.categories, required this.initial});

  final List<Category> categories;
  final Set<String> initial;

  @override
  State<_CategoryFilterSheet> createState() => _CategoryFilterSheetState();
}

class _CategoryFilterSheetState extends State<_CategoryFilterSheet> {
  late final Set<String> _sel = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(JSpace.page, 0, JSpace.page, JSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const JTitle('Filter by *category*', style: JType.panelTitle),
            const SizedBox(height: JSpace.lg),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: JSpace.sm,
                  runSpacing: JSpace.sm,
                  children: [
                    for (final k in widget.categories)
                      JChip(
                        label: k.name,
                        selected: _sel.contains(k.id),
                        leading: JDot(seriesColor(c, k.colorIndex), size: 7),
                        onTap: () => setState(() => _sel.contains(k.id) ? _sel.remove(k.id) : _sel.add(k.id)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: JSpace.lg),
            Row(
              children: [
                JButton(
                  label: 'Clear',
                  kind: JButtonKind.secondary,
                  onPressed: () => setState(_sel.clear),
                ),
                const SizedBox(width: JSpace.sm),
                Expanded(
                  child: JButton(
                    label: 'Apply',
                    expand: true,
                    onPressed: () => Navigator.of(context).pop(_sel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
