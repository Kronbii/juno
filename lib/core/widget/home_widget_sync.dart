import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:home_widget/home_widget.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/insights/analytics.dart';

/// Pushes this month's figures to the iOS home-screen widget through the
/// shared App Group. The Swift side is in ios/JunoWidget (see
/// docs/ios-widget.md for adding the target in Xcode).
abstract final class HomeWidgetSync {
  static const appGroup = 'group.com.kronbii.juno';
  static const iOSName = 'JunoWidget';

  static bool get supported => !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST') && Platform.isIOS;

  static Future<void> push(AppDatabase db) async {
    if (!supported) return;
    final now = DateTime.now();
    final month = DateTime(now.year, now.month);
    final txs = await Ledger(db).transactions(TxQuery(from: Day.firstOfMonth(month), to: Day.lastOfMonth(month)));
    final s = PeriodSummary.of(txs);
    final budgets = await (db.select(db.budgets)..where((b) => b.deletedAt.isNull())).get();
    final top = budgetStatuses(budgets, txs).firstOrNull;
    final pace = MonthPace(month: month, expense: s.expense);

    await HomeWidget.setAppGroupId(appGroup);
    await Future.wait([
      HomeWidget.saveWidgetData<String>('month', Day.month(month).toUpperCase()),
      HomeWidget.saveWidgetData<String>('spent', Money.whole(s.expense)),
      HomeWidget.saveWidgetData<String>('personal', Money.whole(s.byScope[Scope.personal]!)),
      HomeWidget.saveWidgetData<String>('household', Money.whole(s.byScope[Scope.household]!)),
      HomeWidget.saveWidgetData<String>('pace', '${Money.whole(pace.avgDaily)}/day'),
      HomeWidget.saveWidgetData<double>('budgetRatio', top?.ratio ?? 0),
      HomeWidget.saveWidgetData<String>(
        'budgetText',
        top == null ? 'No budgets' : '${(top.ratio * 100).round()}% of a budget used',
      ),
    ]);
    await HomeWidget.updateWidget(iOSName: iOSName);
  }
}
