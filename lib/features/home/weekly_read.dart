import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/settings/ai_screen.dart' show aiAssistProvider;

/// This week so far against the same days of last week, from raw rows.
class WeekFacts {
  const WeekFacts({
    required this.monday,
    required this.daysIn,
    required this.spent,
    required this.lastWeek,
    required this.top,
    required this.entries,
  });

  /// `YYYY-MM-DD` of this week's Monday.
  final String monday;

  /// Days of the week so far, including today (1 on Monday … 7 on Sunday).
  final int daysIn;
  final int spent;

  /// Spending over the same [daysIn] days of last week.
  final int lastWeek;

  /// Biggest categories this week: (name, cents), at most three.
  final List<(String, int)> top;
  final int entries;

  static const uncategorised = 'Uncategorised';

  int get delta => spent - lastWeek;

  /// The plain on-device read, always available.
  String get text {
    if (spent == 0 && lastWeek == 0) return 'Nothing spent yet this week.';
    final b = StringBuffer('You’ve spent ${Money.whole(spent)} this week');
    if (lastWeek > 0 && delta != 0) {
      b.write(', ${Money.whole(delta.abs())} ${delta > 0 ? 'more' : 'less'} than by this point last week');
    } else if (lastWeek > 0) {
      b.write(', the same as by this point last week');
    }
    b.write('.');
    final lead = top.where((t) => t.$1 != uncategorised).firstOrNull;
    if (lead != null && lead == top.first) b.write(' Most of it went to ${lead.$1} (${Money.whole(lead.$2)}).');
    return b.toString();
  }

  /// What the AI is given: totals only, never entries or notes.
  String get facts => [
    'Day $daysIn of 7 this week.',
    'Spent so far: ${Money.whole(spent)} over $entries entries.',
    'Same days last week: ${Money.whole(lastWeek)}.',
    if (top.isNotEmpty) 'Top categories: ${top.map((t) => '${t.$1} ${Money.whole(t.$2)}').join(', ')}.',
  ].join('\n');
}

WeekFacts weekFacts(Iterable<Transaction> txs, Map<String, Category> categories, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final monday = today.subtract(Duration(days: today.weekday - 1));
  final daysIn = today.weekday;
  final from = Day.of(monday);
  final to = Day.of(today);
  final lastFrom = Day.of(monday.subtract(const Duration(days: 7)));
  final lastTo = Day.of(monday.subtract(Duration(days: 7 - daysIn + 1)));
  var spent = 0;
  var last = 0;
  var entries = 0;
  final byCat = <String?, int>{};
  for (final t in txs) {
    if (t.type != TxType.expense) continue;
    final d = t.occurredOn;
    if (d.compareTo(from) >= 0 && d.compareTo(to) <= 0) {
      spent += t.usd;
      entries++;
      byCat[t.categoryId] = (byCat[t.categoryId] ?? 0) + t.usd;
    } else if (d.compareTo(lastFrom) >= 0 && d.compareTo(lastTo) <= 0) {
      last += t.usd;
    }
  }
  final top = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return WeekFacts(
    monday: from,
    daysIn: daysIn,
    spent: spent,
    lastWeek: last,
    top: [for (final e in top.take(3)) (categories[e.key]?.name ?? WeekFacts.uncategorised, e.value)],
    entries: entries,
  );
}

/// "This week" on Home: the on-device read, replaced by a short AI read
/// when AI is on — written at most once a day and kept on this device.
class WeeklyCard extends ConsumerStatefulWidget {
  const WeeklyCard({super.key});

  /// One read per day and scope lens.
  static String cacheKey(String day, Scope? lens) => 'weekly.read.$day.${lens?.name ?? 'all'}';

  @override
  ConsumerState<WeeklyCard> createState() => _WeeklyCardState();
}

class _WeeklyCardState extends ConsumerState<WeeklyCard> {
  final _asked = <String>{};

  Future<void> _maybeAsk(WeekFacts f, String key) async {
    final ai = ref.read(aiAssistProvider);
    if (_asked.contains(key) || !ai.enabled || f.spent == 0 || ref.read(prefsProvider).getString(key) != null) return;
    _asked.add(key);
    final text = await ai.weekly(f.facts);
    if (text == null || text.isEmpty) return;
    final prefs = ref.read(prefsProvider);
    // Keep only today's: yesterday's reads are stale.
    final today = 'weekly.read.${Day.today()}.';
    for (final k in prefs.getKeys().where((k) => k.startsWith('weekly.read.') && !k.startsWith(today)).toList()) {
      await prefs.remove(k);
    }
    await prefs.setString(key, text);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = Day.of(today.subtract(Duration(days: today.weekday - 1 + 7)));
    final lens = ref.watch(scopeFilterProvider);
    final txs = ref.watch(txQueryProvider(TxQuery(from: from, to: Day.of(today), scope: lens)));
    final list = txs.value;
    if (list == null) return const SizedBox.shrink();
    final f = weekFacts(list, ref.watch(categoryMapProvider), now);
    final key = WeeklyCard.cacheKey(Day.today(), lens);
    final ai = ref.read(prefsProvider).getString(key);
    if (ai == null) unawaited(_maybeAsk(f, key));
    return JCard(
      accent: JAccent.household,
      title: 'This week',
      trailing: ai != null ? const JPill('AI') : JPill('Day ${f.daysIn}/7'),
      child: Text(ai ?? f.text, style: JType.body.copyWith(fontSize: 14.5, color: c.ink, height: 1.45)),
    );
  }
}
