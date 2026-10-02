import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/money.dart';

enum GoalStatus { reached, onTrack, behind, noPace }

/// How a goal is going: what you've been putting in lately, what the target
/// date needs, and when you'd get there at this pace.
class GoalPace {
  const GoalPace({required this.status, required this.perMonth, required this.left, this.needPerMonth, this.eta});

  final GoalStatus status;

  /// Average net saving per month lately (USD cents).
  final int perMonth;
  final int left;

  /// What the target date needs per month from now; null without a date.
  final int? needPerMonth;

  /// The month you'd reach it at [perMonth]; null when nothing is going in.
  final DateTime? eta;

  /// One line for the goal card.
  String get line => switch (status) {
    GoalStatus.reached => 'Reached — nice.',
    GoalStatus.onTrack when needPerMonth != null =>
      'On track · ${Money.whole(perMonth)}/mo, there by ${Day.monthYear(eta!)}',
    GoalStatus.onTrack => 'At ${Money.whole(perMonth)}/mo you’ll get there by ${Day.monthYear(eta!)}',
    GoalStatus.behind =>
      'Behind · needs ${Money.whole(needPerMonth!)}/mo, '
          '${perMonth > 0 ? 'putting in ${Money.whole(perMonth)}' : 'nothing going in lately'}',
    GoalStatus.noPace when needPerMonth != null => '${Money.whole(needPerMonth!)}/mo to hit the date',
    GoalStatus.noPace => '${Money.whole(left)} to go',
  };
}

/// [contributions] are the goal's (withdrawals negative). The pace is the
/// last [window] months' net saving, or the months since the first
/// contribution when the goal is newer.
GoalPace goalPace({
  required Goal goal,
  required int saved,
  required List<GoalContribution> contributions,
  DateTime? now,
  int window = 3,
}) {
  final n = now ?? clock.now();
  final left = math.max(0, goal.targetCents - saved);
  if (left == 0) return const GoalPace(status: GoalStatus.reached, perMonth: 0, left: 0);

  final today = Day.of(n);
  final live = contributions.where((c) => c.deletedAt == null && c.occurredOn.compareTo(today) <= 0).toList();
  // Whole calendar months: the last [window] of them, ending with this one
  // if you've already put money in this month, else with last month (this
  // month's deposit may simply not be due yet). A goal started more
  // recently averages over the months since its first deposit. Counting
  // days instead made two $500 deposits a month apart read as $1,000/mo.
  String monthOf(String day) => day.substring(0, 7);
  final thisMonth = monthOf(today);
  final endsNow = live.any((c) => monthOf(c.occurredOn) == thisMonth);
  final last = endsNow ? DateTime(n.year, n.month) : DateTime(n.year, n.month - 1);
  var start = DateTime(last.year, last.month - window + 1);
  if (live.isNotEmpty) {
    final first = Day.parse(live.map((c) => c.occurredOn).reduce((a, b) => a.compareTo(b) < 0 ? a : b));
    if (DateTime(first.year, first.month).isAfter(start)) start = DateTime(first.year, first.month);
  }
  final months = math.max(1, (last.year - start.year) * 12 + last.month - start.month + 1);
  final since = Day.firstOfMonth(start);
  final until = Day.lastOfMonth(last);
  final net = live
      .where((c) => c.occurredOn.compareTo(since) >= 0 && c.occurredOn.compareTo(until) <= 0)
      .fold(0, (s, c) => s + c.amountCents);
  // Unrounded for the arrival date: rounding to cents first can push it a
  // month late ($800 at $133.33/mo is 6 months, not 6.0002).
  final pace = live.isEmpty ? 0.0 : math.max(0, net / months).toDouble();
  final perMonth = pace.round();

  int? need;
  DateTime? deadline;
  if (goal.targetDate != null) {
    deadline = Day.parse(goal.targetDate!);
    final monthsLeft = math.max(1, (deadline.year - n.year) * 12 + deadline.month - n.month);
    need = (left / monthsLeft).ceil();
  }
  final eta = pace <= 0 ? null : DateTime(n.year, n.month + (left / pace - 1e-9).ceil());

  final GoalStatus status;
  if (eta == null) {
    status = deadline == null ? GoalStatus.noPace : GoalStatus.behind;
  } else if (deadline == null) {
    status = GoalStatus.onTrack;
  } else {
    final onTime = eta.year < deadline.year || (eta.year == deadline.year && eta.month <= deadline.month);
    status = onTime ? GoalStatus.onTrack : GoalStatus.behind;
  }
  return GoalPace(status: status, perMonth: perMonth, left: left, needPerMonth: need, eta: eta);
}
