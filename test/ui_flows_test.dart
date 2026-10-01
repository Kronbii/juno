// UI regression flows: each audit finding re-run as a real interaction on
// the full app (in-memory database + demo data). Any exception — overflow,
// assertion, disposed controller — fails the test via takeException.
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/app/app.dart';
import 'package:juno/app/router.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/demo.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/features/add/entry_sheet.dart';
import 'package:juno/features/plan/editors.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _fonts() async {
  Future<void> family(String name, String match) async {
    final l = FontLoader(name);
    for (final f in Directory('assets/fonts').listSync().whereType<File>().where((f) => f.path.contains(match))) {
      l.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await l.load();
  }

  await family('Manrope', 'Manrope');
  await family('JetBrainsMono', 'JetBrainsMono');
  await family('InstrumentSerif', 'InstrumentSerif');
}

class Harness {
  Harness(this.tester, this.db);

  final WidgetTester tester;
  final AppDatabase db;
  Ledger get ledger => Ledger(db);

  Future<void> settle([int rounds = 5]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> go(String route) async {
    router.go(route);
    await settle();
  }

  BuildContext get ctx => rootNavigatorKey.currentContext!;

  Future<void> dispose() async {
    // Close any sheet or dialog, unmount, let drift's timers fire, close.
    rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  }
}

Future<Harness> boot(
  WidgetTester tester, {
  Size size = const Size(393, 852),
  bool demo = true,
  bool onboarded = true,
  Future<void> Function(AppDatabase db)? setup,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'onboarded': onboarded});
  final prefs = await SharedPreferences.getInstance();
  final db = AppDatabase.memory(NativeDatabase.memory());
  await tester.runAsync(() async {
    await db.customSelect('SELECT 1').get();
    if (demo) await seedDemo(db);
    // Setup writes happen before the app watches anything: a write while
    // the app's streams are live would queue behind queries that run in the
    // test's fake clock.
    if (setup != null) await setup(db);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db), prefsProvider.overrideWithValue(prefs)],
      child: const JunoApp(),
    ),
  );
  final h = Harness(tester, db);
  if (onboarded) await h.go('/home');
  return h;
}

Future<int> count(Harness h, String sql) async {
  final r = await h.tester.runAsync(() => h.db.customSelect(sql).getSingle());
  return r!.read<int>('n');
}

void main() {
  setUpAll(_fonts);

  testWidgets('every screen renders at phone, narrow and desktop sizes without errors', (tester) async {
    for (final size in const [Size(320, 640), Size(393, 852), Size(1440, 920)]) {
      final h = await boot(tester, size: size);
      for (final r in const [
        '/home',
        '/activity',
        '/insights',
        '/plan',
        '/settings',
        '/settings/accounts',
        '/settings/categories',
        '/settings/currencies',
        '/settings/import',
        '/settings/back-tap',
        '/settings/sync',
        '/settings/backups',
        '/insights/review',
      ]) {
        await h.go(r);
        expect(tester.takeException(), isNull, reason: '$r at $size');
      }
      await h.dispose();
    }
  });

  testWidgets('large text (160%): every screen and the entry sheet without overflow', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final h = await boot(tester);
    for (final r in const ['/home', '/activity', '/insights', '/plan', '/settings', '/insights/review', '/settings/backups']) {
      await h.go(r);
      final e = tester.takeException();
      expect(e, isNull, reason: '$r at 160% text');
    }
    unawaitedFuture(showEntrySheet(h.ctx));
    await h.settle();
    expect(tester.takeException(), isNull, reason: 'entry sheet at 160% text');
    await h.dispose();
  });

  testWidgets('entry sheet: double tap on Log saves once and never throws', (tester) async {
    final h = await boot(tester, demo: false);
    unawaitedFuture(showEntrySheet(h.ctx));
    await h.settle();
    await tester.tap(find.text('7').last);
    await h.settle(1);
    final log = find.text(r'Log $7.00');
    await tester.tap(log.first);
    await tester.tap(log.first, warnIfMissed: false);
    await h.settle();
    expect(tester.takeException(), isNull);
    expect(await count(h, 'SELECT COUNT(*) AS n FROM transactions'), 1);
    await h.dispose();
  });

  testWidgets('entry sheet: a far-future date opens the picker safely', (tester) async {
    final h = await boot(tester, demo: false);
    unawaitedFuture(showEntrySheet(h.ctx, prefill: const EntryPrefill(amountCents: 500, day: '2031-06-01')));
    await h.settle();
    await tester.tap(find.byIcon(Icons.calendar_today_outlined).first);
    await h.settle();
    expect(tester.takeException(), isNull);
    await h.dispose();
  });

  testWidgets('entry sheet: transfer chips fit at 320px', (tester) async {
    final h = await boot(tester, size: const Size(320, 640));
    unawaitedFuture(showEntrySheet(h.ctx, prefill: const EntryPrefill(type: TxType.transfer, amountCents: 500)));
    await h.settle();
    expect(tester.takeException(), isNull);
    await h.dispose();
  });

  testWidgets('goal: add money and withdraw are capped, and the sheet closes cleanly', (tester) async {
    late String id;
    final h = await boot(
      tester,
      demo: false,
      setup: (db) async => id = await Ledger(db).upsertGoal(GoalsCompanion.insert(name: 'Trip', targetCents: 100000)),
    );
    await h.go('/plan/goal/$id');
    await tester.tap(find.text('Add money'));
    await h.settle();
    await tester.enterText(find.byType(TextField).last, '25');
    await h.settle(1);
    await tester.tap(find.text('Add'));
    await h.settle();
    expect(tester.takeException(), isNull, reason: 'disposed controller during close');
    expect(await count(h, 'SELECT SUM(amount_cents) AS n FROM goal_contributions'), 2500);

    await tester.tap(find.text('Withdraw'));
    await h.settle();
    await tester.enterText(find.byType(TextField).last, '100');
    await h.settle(1);
    expect(find.text('More than the goal holds'), findsOneWidget);
    await h.dispose();
  });

  testWidgets('goal deleted while open: back button, no dead end', (tester) async {
    final h = await boot(tester, demo: false);
    await h.go('/plan/goal/does-not-exist');
    expect(find.text('This goal was deleted'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    await h.dispose();
  });

  testWidgets('editors open for a rule/budget pointing at archived account/category', (tester) async {
    final h = await boot(
      tester,
      demo: false,
      setup: (db) async {
        final l = Ledger(db);
        await l.upsertRecurring(
          RecurringRulesCompanion.insert(
            type: TxType.expense,
            scope: Scope.personal,
            amountCents: 1000,
            accountId: seedId('acct:cash'),
            categoryId: Value(seedId('cat:Coffee')),
            frequency: Frequency.monthly,
            anchorDate: Day.today(),
            nextDue: Day.today(),
          ),
        );
        await l.upsertBudget(BudgetsCompanion.insert(categoryId: Value(seedId('cat:Coffee')), limitCents: 5000));
        await (db.update(db.accounts)..where((a) => a.id.equals(seedId('acct:cash')))).write(
          const AccountsCompanion(archived: Value(true)),
        );
        await (db.update(db.categories)..where((c) => c.id.equals(seedId('cat:Coffee')))).write(
          const CategoriesCompanion(archived: Value(true)),
        );
      },
    );
    final rule = (await tester.runAsync(() => h.db.select(h.db.recurringRules).get()))!.single;
    final budget = (await tester.runAsync(() => h.db.select(h.db.budgets).get()))!.single;
    unawaitedFuture(editRecurring(h.ctx, rule: rule));
    await h.settle();
    expect(tester.takeException(), isNull, reason: 'recurring editor with archived account');
    expect(find.text('Cash (archived)'), findsOneWidget);
    rootNavigatorKey.currentState!.pop();
    await h.settle();
    unawaitedFuture(editBudget(h.ctx, budget: budget));
    await h.settle();
    expect(tester.takeException(), isNull, reason: 'budget editor with archived category');
    await h.dispose();
  });

  testWidgets('currency rate sheet saves and closes cleanly', (tester) async {
    final h = await boot(tester, demo: false);
    await h.go('/settings/currencies');
    await tester.tap(find.text('LBP'));
    await h.settle();
    await tester.enterText(find.byType(TextField).last, '90000');
    await h.settle(1);
    await tester.tap(find.text('Save rate'));
    await h.settle();
    expect(tester.takeException(), isNull);
    final rates = await tester.runAsync(() => h.ledger.rates());
    expect(rates!['LBP'], 90000);
    await h.dispose();
  });

  testWidgets('quick text fills the entry sheet', (tester) async {
    final h = await boot(tester, demo: false);
    unawaitedFuture(showEntrySheet(h.ctx));
    await h.settle();
    await tester.enterText(find.byType(TextField).first, '12 coffee kalei');
    await h.settle(1);
    await tester.tap(find.textContaining(r'Log $12.00').first);
    await h.settle();
    final t = (await tester.runAsync(() => h.ledger.transactions(const TxQuery())))!.single;
    expect(t.amountCents, 1200);
    expect(t.categoryId, seedId('cat:Coffee'));
    expect(t.note, 'Kalei');
    await h.dispose();
  });

  testWidgets('first launch: onboarding sets balances, LBP account and rate', (tester) async {
    final h = await boot(tester, demo: false, onboarded: false);
    await h.settle();
    expect(find.textContaining('clearly'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await h.settle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '1250'); // Checking
    await tester.enterText(find.widgetWithText(TextField, 'LBP ').first, '2000000');
    await h.settle(1);
    await tester.tap(find.text('Next'));
    await h.settle();
    await tester.tap(find.text('Start'));
    await h.settle();
    expect(tester.takeException(), isNull);
    final accounts = (await tester.runAsync(() => h.db.select(h.db.accounts).get()))!;
    expect(accounts.firstWhere((a) => a.id == seedId('acct:checking')).openingBalanceCents, 125000);
    final lbp = accounts.firstWhere((a) => a.currency == 'LBP');
    expect(lbp.openingBalanceCents, 200000000);
    await h.dispose();
  });
}

/// Fire-and-forget without the unawaited lint noise in tests.
void unawaitedFuture(Future<void> f) {}
