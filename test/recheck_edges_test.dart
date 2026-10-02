// Re-check after v4–v6: failure points and edges for the new features —
// stale drafts, calendar edges (leap day, month ends, year turn, DST when
// run with TZ set), an app with no accounts, corrupt local state, and volume.
//   TZ=Asia/Beirut flutter test test/recheck_edges_test.dart
import 'dart:math';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/assistant/assistant.dart';
import 'package:juno/features/assistant/assistant_tools.dart';
import 'package:juno/features/home/weekly_read.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/insights/health.dart';
import 'package:juno/features/plan/forecast.dart';
import 'package:juno/features/plan/goal_pace.dart';
import 'package:juno/features/settings/balance_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _t0 = DateTime.utc(2026);

Account acct(String id, {AccountKind kind = AccountKind.checking, int opening = 0}) => Account(
  id: id,
  createdAt: _t0,
  updatedAt: _t0,
  dirty: false,
  name: id,
  kind: kind,
  openingBalanceCents: opening,
  currency: 'USD',
  archived: false,
  sort: 0,
);

RecurringRule rule(String id, Frequency f, String anchor, {int cents = 1000, int interval = 1}) => RecurringRule(
  id: id,
  createdAt: _t0,
  updatedAt: _t0,
  dirty: false,
  type: TxType.expense,
  scope: Scope.personal,
  amountCents: cents,
  accountId: 'chk',
  note: id,
  frequency: f,
  interval: interval,
  anchorDate: anchor,
  nextDue: anchor,
  active: true,
);

var _n = 0;
Transaction tx(String day, int cents, {TxType type = TxType.expense, String tags = ''}) => Transaction(
  id: 'e${_n++}',
  createdAt: _t0,
  updatedAt: _t0,
  dirty: false,
  type: type,
  scope: Scope.household,
  amountCents: cents,
  accountId: 'chk',
  occurredOn: day,
  note: '',
  merchant: '',
  currency: 'USD',
  tags: tags,
);

void main() {
  group('stale drafts', () {
    late AppDatabase db;
    late Ledger ledger;
    late Assistant chat;
    setUp(() async {
      db = AppDatabase.memory(NativeDatabase.memory());
      ledger = Ledger(db);
      await db.customSelect('SELECT 1').get();
      SharedPreferences.setMockInitialValues({});
      chat = Assistant(AiAssist(await SharedPreferences.getInstance()), ledger);
    });
    tearDown(() => db.close());

    Future<EntryDraft> draft(Map<String, Object> args) async {
      final tools = AssistantTools(ledger);
      expect((await tools.run('draft_entry', args))['error'], isNull);
      return tools.takeDrafts().single;
    }

    test('account archived or deleted after drafting: refused, nothing saved', () async {
      for (final archive in [true, false]) {
        final d = await draft({'amount': 5, 'account': 'cash'});
        final patch = archive
            ? const AccountsCompanion(archived: Value(true))
            : AccountsCompanion(deletedAt: Value(DateTime.now().toUtc()));
        await (db.update(db.accounts)..where((a) => a.id.equals(d.accountId))).write(patch);
        await expectLater(chat.log(d), throwsA(isA<DraftStale>()));
        expect(d.loggedId, isNull);
        expect(await db.select(db.transactions).get(), isEmpty);
        await (db.update(db.accounts)..where((a) => a.id.equals(d.accountId))).write(
          const AccountsCompanion(archived: Value(false), deletedAt: Value(null)),
        );
      }
    });

    test('category deleted after drafting: logged without it', () async {
      final d = await draft({'amount': 5, 'category': 'coffee'});
      expect(d.categoryId, seedId('cat:Coffee'));
      await (db.update(db.categories)..where((c) => c.id.equals(d.categoryId!))).write(
        CategoriesCompanion(deletedAt: Value(DateTime.now().toUtc())),
      );
      final id = await chat.log(d);
      final t = await (db.select(db.transactions)..where((x) => x.id.equals(id))).getSingle();
      expect(t.categoryId, isNull);
    });

    test('no accounts at all: drafting explains, lookups answer empty', () async {
      await db.update(db.accounts).write(AccountsCompanion(deletedAt: Value(DateTime.now().toUtc())));
      final tools = AssistantTools(ledger);
      expect((await tools.run('draft_entry', {'amount': 5}))['error'], contains('No USD account'));
      expect((await tools.run('accounts', {}))['accounts'], isEmpty);
      final f = forecastCash(
        accounts: await db.select(db.accounts).get(),
        balances: await ledger.watchBalances().first,
        rules: const [],
        recent: const [],
        rates: const {'USD': 1},
        ruleLabels: const {},
      );
      expect((f.start, f.end, f.firstBelowZero), (0, 0, null));
    });

    test('balance check on a corrupt or missing "last checked" record', () async {
      SharedPreferences.setMockInitialValues({'balance.checked.x': 'not a date'});
      final prefs = await SharedPreferences.getInstance();
      expect(BalanceChecks.last(prefs, 'x'), isNull);
      expect(BalanceChecks.last(prefs, 'y'), isNull);
      await BalanceChecks.mark(prefs, 'x', DateTime(2026, 10, 2, 9));
      expect(BalanceChecks.last(prefs, 'x'), DateTime(2026, 10, 2, 9));
    });

    test('an opening-balance fix on a deleted account fails loudly, not silently', () async {
      final cash = await (db.select(db.accounts)..where((a) => a.id.equals(seedId('acct:cash')))).getSingle();
      await (db.delete(db.accounts)..where((a) => a.id.equals(cash.id))).go();
      await expectLater(
        applyBalanceCheck(ledger, cash, actual: 100, current: 0, fix: BalanceFix.opening),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('calendar edges', () {
    test('forecast across a leap February: anchors on the 31st and 29th clamp, then return', () {
      final f = forecastCash(
        accounts: [acct('chk')],
        balances: const {'chk': 100000},
        rules: [rule('m31', Frequency.monthly, '2028-01-31'), rule('y29', Frequency.yearly, '2024-02-29')],
        recent: const [],
        rates: const {'USD': 1},
        ruleLabels: const {},
        now: DateTime(2028, 1, 20),
        days: 75,
      );
      expect(f.events.where((e) => e.ruleId == 'm31').map((e) => e.day), ['2028-01-31', '2028-02-29', '2028-03-31']);
      // A yearly bill on 29 Feb (next due long ago): its only date in the
      // window is the real 29 Feb 2028; the 28 Feb fallbacks of 2025–27
      // are in the past.
      expect(f.events.where((e) => e.ruleId == 'y29').map((e) => e.day), ['2028-02-29']);
      // Consecutive calendar days, no repeats (DST-safe when run with TZ set).
      for (var i = 1; i < f.series.length; i++) {
        final a = f.series[i - 1].$1;
        final b = f.series[i].$1;
        expect(DateTime(a.year, a.month, a.day + 1), b, reason: 'day $i');
      }
    });

    test('forecast series stays one point per calendar day through DST changes', () {
      for (final start in [
        DateTime(2026, 3, 20),
        DateTime(2026, 10, 15),
        DateTime(2026, 10, 30),
        DateTime(2027, 3, 25),
      ]) {
        final f = forecastCash(
          accounts: [acct('chk')],
          balances: const {'chk': 0},
          rules: [rule('w', Frequency.weekly, Day.of(start.add(const Duration(days: 3))))],
          recent: const [],
          rates: const {'USD': 1},
          ruleLabels: const {},
          now: start,
        );
        final days = f.series.map((p) => Day.of(p.$1)).toList();
        expect(days.toSet().length, days.length, reason: 'no repeated day from $start');
        for (var i = 1; i < f.series.length; i++) {
          expect(Day.between(f.series[i - 1].$1, f.series[i].$1), 1, reason: 'day $i from $start');
        }
        final weekly = f.events.map((e) => Day.parse(e.day).weekday).toSet();
        expect(weekly.length, 1, reason: 'a weekly bill keeps its weekday from $start');
      }
    });

    test('day counting ignores the clock: DST in spring and autumn (run with TZ=Asia/Beirut)', () {
      // Lebanon moves its clocks at midnight: 29 March 2026 starts at 01:00.
      expect(Day.between(DateTime(2026, 3, 29), DateTime(2026, 3, 30)), 1);
      expect(Day.between(DateTime(2026, 3, 28), DateTime(2026, 3, 29)), 1);
      expect(Day.between(DateTime(2026, 10, 24), DateTime(2026, 10, 26)), 2);
      expect(Day.between(DateTime(2026, 1, 10), DateTime(2026, 4, 10, 23, 59)), 90);
      expect(Day.between(DateTime(2026, 3, 30), DateTime(2026, 3, 29)), -1);
      expect(Day.relative('2026-03-29', now: DateTime(2026, 3, 30, 10)), 'Yesterday');
      expect(Day.relative('2026-03-30', now: DateTime(2026, 3, 30, 0, 30)), 'Today');
      expect(Day.relative('2026-10-26', now: DateTime(2026, 10, 25, 23)), 'Tomorrow');
      // The forecast's 90-day pace window across the spring change.
      final f = forecastCash(
        accounts: const [],
        balances: const {},
        rules: const [],
        recent: [tx('2026-01-01', 9000)],
        rates: const {'USD': 1},
        ruleLabels: const {},
        now: DateTime(2026, 4, 10, 12),
      );
      expect(f.paceDays, 90);
    });

    test('the week so far across a year turn', () {
      final f = weekFacts(
        [tx('2026-12-28', 100), tx('2027-01-01', 200), tx('2026-12-21', 50), tx('2026-12-25', 999)],
        const {},
        DateTime(2027, 1, 1, 23, 59),
      );
      // Friday: the same days last week are Mon 21 – Fri 25 Dec.
      expect((f.monday, f.daysIn, f.spent, f.lastWeek), ('2026-12-28', 5, 300, 50 + 999));
    });

    test('money health in January uses October to December', () {
      final h = moneyHealth(
        accounts: [acct('chk', opening: 100000)],
        balances: const {},
        rules: const [],
        txs: [tx('2026-10-05', 1000), tx('2026-12-31', 3000), tx('2026-09-30', 99999), tx('2027-01-02', 99999)],
        rates: const {'USD': 1},
        now: DateTime(2027, 1, 15),
      );
      expect((h.from, h.to, h.months, h.avgSpend), (DateTime(2026, 10), DateTime(2026, 12), 2, 2000));
    });

    test('goal whose date has passed: needs everything left this month', () {
      final p = goalPace(
        goal: Goal(
          id: 'g',
          createdAt: _t0,
          updatedAt: _t0,
          dirty: false,
          name: 'Late',
          targetCents: 100000,
          targetDate: '2026-06-30',
          colorIndex: 0,
          archived: false,
        ),
        saved: 40000,
        contributions: const [],
        now: DateTime(2026, 10, 2),
      );
      expect((p.status, p.needPerMonth), (GoalStatus.behind, 60000));
    });
  });

  group('volume', () {
    test('20,000 entries: every new computation stays fast', () {
      final rnd = Random(5);
      final now = DateTime(2026, 10, 2);
      final txs = [
        for (var i = 0; i < 20000; i++)
          tx(
            Day.of(now.subtract(Duration(days: rnd.nextInt(400)))),
            rnd.nextInt(50000) + 1,
            type: rnd.nextDouble() < 0.85 ? TxType.expense : TxType.income,
            tags: rnd.nextDouble() < 0.3 ? ',@mom,@karim,' : '',
          ),
      ];
      final rules = [
        for (var i = 0; i < 60; i++) rule('r$i', Frequency.values[i % 3], Day.of(DateTime(2026, 10, (i % 28) + 1))),
      ];
      final timings = <String, int>{};
      T time<T>(String name, T Function() f) {
        final sw = Stopwatch()..start();
        final out = f();
        timings[name] = sw.elapsedMilliseconds;
        return out;
      }

      time(
        'forecast',
        () => forecastCash(
          accounts: [acct('chk')],
          balances: const {'chk': 0},
          rules: rules,
          recent: txs,
          ahead: txs,
          rates: const {'USD': 1},
          ruleLabels: const {},
          now: now,
        ),
      );
      time(
        'health',
        () => moneyHealth(
          accounts: [acct('chk')],
          balances: const {},
          rules: rules,
          txs: txs,
          rates: const {'USD': 1},
          now: now,
        ),
      );
      time('people', () => spendByPerson(txs));
      time('week', () => weekFacts(txs, const {}, now));
      time('summary', () => PeriodSummary.of(txs));
      // ignore: avoid_print, the numbers are the point
      print('timings (ms, 20k entries): $timings');
      for (final e in timings.entries) {
        expect(e.value, lessThan(400), reason: '${e.key} took ${e.value} ms');
      }
    });
  });
}
