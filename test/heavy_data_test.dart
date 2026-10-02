// Every screen with years of real data: LBP billions, $100k months, long
// and Arabic names, many categories, accounts, budgets, goals and rules —
// on a 320px phone at 100% and 160% text, and a larger phone at 200%. Any
// layout error (overflow, clipped flex) anywhere fails the test.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/app/router.dart';
import 'package:juno/features/add/entry_sheet.dart';

import 'support/harness.dart';
import 'support/heavy_world.dart';

String _summary(FlutterErrorDetails d) => d.exceptionAsString().split('\n').first;

void main() {
  setUpAll(loadFonts);

  for (final (size, scale) in const [(Size(320, 640), 1.0), (Size(320, 640), 1.6), (Size(393, 852), 2.0)]) {
    testWidgets('years of real data: every screen at ${size.width.toInt()}px ×$scale', (tester) async {
      final errors = <String>[];
      var where = '';
      final original = FlutterError.onError;
      FlutterError.onError = (d) => errors.add('[$where] ${_summary(d)}');
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      try {
        final h = await boot(tester, size: size, demo: false, setup: (db) => heavyWorld(db, txCount: 4000));
        for (final r in const [
          '/home',
          '/activity',
          '/insights',
          '/plan',
          '/settings',
          '/settings/accounts',
          '/settings/categories',
          '/settings/currencies',
          '/insights/review',
          '/assistant',
        ]) {
          where = r;
          await h.go(r);
        }
        await h.go('/plan');
        for (final tab in ['GOALS', 'RECURRING', 'CASH FLOW', 'BUDGETS']) {
          where = 'plan $tab';
          await tester.tap(find.text(tab));
          await h.settle(3);
        }
        await h.go('/home');
        where = 'new entry';
        unawaited(showEntrySheet(h.ctx));
        await h.settle();
        rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
        await h.settle(2);
        final big = (await tester.runAsync(
          () => (h.db.select(h.db.transactions)..where((t) => t.amountCents.equals(450000000000))).get(),
        ))!;
        if (big.isNotEmpty) {
          where = 'edit LBP 4.5B';
          unawaited(showEntrySheet(h.ctx, edit: big.first));
          await h.settle();
        }
        await h.dispose();
      } finally {
        FlutterError.onError = original;
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      }
      final unique = errors.toSet().toList();
      expect(unique, isEmpty, reason: unique.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}
