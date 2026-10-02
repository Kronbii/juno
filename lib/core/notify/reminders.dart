import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Day;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/plan/budget_widgets.dart' show budgetName;
import 'package:juno/features/plan/recurrence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Bill reminders and budget alerts.
///
/// iOS: bills are scheduled ahead with the OS (they fire even if Juno is
/// closed). Linux can't schedule, so when Juno comes to the foreground it
/// posts any reminder that is due — once per bill per due date.
/// Budget alerts fire when a budget first crosses 80% and again at 100%,
/// once per budget per month.
class Reminders {
  Reminders(this.prefs);

  final SharedPreferences prefs;
  final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const billsKey = 'notify.bills';
  static const budgetsKey = 'notify.budgets';
  static const _billIdBase = 10000;

  bool get billsOn => prefs.getBool(billsKey) ?? true;
  bool get budgetsOn => prefs.getBool(budgetsKey) ?? true;

  static bool get supported =>
      !kIsWeb &&
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      (Platform.isIOS || Platform.isMacOS || Platform.isLinux);
  static bool get canSchedule => supported && (Platform.isIOS || Platform.isMacOS);

  Future<void> init() async {
    if (_ready || !supported) return;
    await _plugin.initialize(
      const InitializationSettings(
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(),
        linux: LinuxInitializationSettings(defaultActionName: 'Open Juno'),
      ),
    );
    if (canSchedule) {
      tzdata.initializeTimeZones();
      try {
        final zone = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(zone.identifier));
      } on Object {
        tz.setLocalLocation(tz.UTC);
      }
    }
    _ready = true;
  }

  /// Asks iOS for permission. Returns whether alerts are allowed.
  Future<bool> requestPermission() async {
    await init();
    if (!canSchedule) return true;
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    return await ios?.requestPermissions(alert: true, sound: true) ?? false;
  }

  static const _details = NotificationDetails(
    iOS: DarwinNotificationDetails(threadIdentifier: 'juno'),
    macOS: DarwinNotificationDetails(threadIdentifier: 'juno'),
    linux: LinuxNotificationDetails(),
  );

  String _billText(RecurringRule r, Map<String, Account> accounts, Map<String, Category> cats) {
    final name = r.note.isNotEmpty ? r.note : cats[r.categoryId]?.name ?? 'Recurring payment';
    final amount = Fx.format(r.amountCents, accounts[r.accountId]?.currency ?? baseCurrency);
    return '$name · $amount';
  }

  /// Re-plans every bill reminder from the current rules.
  Future<void> planBills(List<RecurringRule> rules, Map<String, Account> accounts, Map<String, Category> cats) async {
    await init();
    if (!supported) return;
    final bills = rules.where((r) => r.isLive && r.type == TxType.expense).toList();

    if (canSchedule) {
      for (var i = 0; i < 64; i++) {
        await _plugin.cancel(_billIdBase + i);
      }
      if (!billsOn) return;
      final now = tz.TZDateTime.now(tz.local);
      var i = 0;
      // iOS keeps at most 64 pending; the soonest bills go first.
      for (final r in bills..sort((a, b) => a.nextDue.compareTo(b.nextDue))) {
        final d = Day.parse(r.nextDue);
        final at = tz.TZDateTime(tz.local, d.year, d.month, d.day, 9);
        if (at.isBefore(now) || i >= 60) continue;
        await _plugin.zonedSchedule(
          _billIdBase + i++,
          'Due today',
          _billText(r, accounts, cats),
          at,
          _details,
          androidScheduleMode: AndroidScheduleMode.inexact,
        );
      }
      return;
    }

    // Linux: post what is due today or tomorrow, once per due date.
    if (!billsOn) return;
    final tomorrow = Day.of(Day.shift(clock.now(), 1));
    var id = _billIdBase;
    for (final r in bills.where((r) => r.nextDue.compareTo(tomorrow) <= 0)) {
      final key = 'notified.bill.${r.id}.${r.nextDue}';
      if (prefs.getBool(key) ?? false) continue;
      await _plugin.show(
        id++,
        r.nextDue == Day.today() ? 'Due today' : 'Due tomorrow',
        _billText(r, accounts, cats),
        _details,
      );
      await prefs.setBool(key, true);
    }
  }

  /// Alerts for budgets that have newly crossed 80% or 100% this month.
  Future<void> checkBudgets(List<BudgetStatus> statuses, Map<String, Category> cats) async {
    await init();
    if (!supported || !budgetsOn) return;
    final month = Day.today().substring(0, 7);
    var id = 20000;
    for (final s in statuses) {
      final level = s.over
          ? 'over'
          : s.near
          ? 'near'
          : null;
      if (level == null) continue;
      final key = 'notified.budget.${s.budget.id}.$month.$level';
      if (prefs.getBool(key) ?? false) continue;
      final name = budgetName(s.budget, cats);
      await _plugin.show(
        id++,
        s.over ? 'Over budget' : 'Close to your budget',
        s.over
            ? '$name is ${Money.whole(-s.remaining)} over its ${Money.whole(s.budget.limitCents)} limit.'
            : '$name has ${Money.whole(s.remaining)} left this month (${(s.ratio * 100).round()}% used).',
        _details,
      );
      await prefs.setBool(key, true);
    }
  }
}
