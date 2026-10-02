import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/notify/reminders.dart';
import 'package:juno/features/plan/recurrence.dart';

RecurringRule rule(
  String id,
  Frequency f,
  String anchor, {
  String? next,
  String? end,
  bool active = true,
  TxType type = TxType.expense,
}) => RecurringRule(
  id: id,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  dirty: false,
  type: type,
  scope: Scope.personal,
  amountCents: 1000,
  accountId: 'a',
  note: id,
  frequency: f,
  interval: 1,
  anchorDate: anchor,
  nextDue: next ?? anchor,
  endDate: end,
  active: active,
);

void main() {
  test('opening the app early on a due day keeps that morning’s reminder', () {
    // Rent due today; opening at 7:00 posted it, so nextDue moved to next month.
    final rent = rule('rent', Frequency.monthly, '2026-01-02', next: '2026-11-02');
    final early = Reminders.billDates([rent], DateTime(2026, 10, 2, 7));
    expect(early.map((e) => e.$1), ['2026-10-02', '2026-11-02'], reason: 'today at 9:00 still rings');
    final late = Reminders.billDates([rent], DateTime(2026, 10, 2, 11));
    expect(late.map((e) => e.$1), ['2026-11-02'], reason: 'past 9:00: not scheduled in the past');
  });

  test('a weekly bill is reminded every week, not just once', () {
    final gym = rule('gym', Frequency.weekly, '2026-09-07');
    expect(Reminders.billDates([gym], DateTime(2026, 10, 2, 12)).map((e) => e.$1), [
      '2026-10-05',
      '2026-10-12',
      '2026-10-19',
      '2026-10-26',
      '2026-11-02',
    ]);
  });

  test('ended, paused and income rules are never reminded; the soonest come first, capped', () {
    final rules = [
      rule('ended', Frequency.monthly, '2026-01-05', end: '2026-09-30'),
      rule('paused', Frequency.monthly, '2026-01-05', active: false),
      rule('salary', Frequency.monthly, '2026-01-05', type: TxType.income),
      for (var i = 0; i < 20; i++) rule('w$i', Frequency.weekly, '2026-09-${(i % 7 + 1).toString().padLeft(2, '0')}'),
    ];
    final dates = Reminders.billDates(rules, DateTime(2026, 10, 2, 12));
    expect(dates.length, 60);
    expect(dates.map((e) => e.$2.id).toSet().intersection({'ended', 'paused', 'salary'}), isEmpty);
    expect(dates.map((e) => e.$1).toList(), [...dates.map((e) => e.$1)]..sort());
  });

  test('a schedule keeps month-end anchors and the end date', () {
    final ins = rule('ins', Frequency.monthly, '2026-01-31', end: '2026-12-31');
    expect(scheduleBetween(ins, '2026-10-01', '2027-03-31'), ['2026-10-31', '2026-11-30', '2026-12-31']);
  });
}
