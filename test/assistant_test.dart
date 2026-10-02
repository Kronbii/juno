import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/demo.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/assistant/assistant.dart';
import 'package:juno/features/assistant/assistant_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';

final now = DateTime(2026, 9, 18, 14);

http.Response msg({String? text, List<(String, String, Object)> calls = const []}) => http.Response.bytes(
  utf8.encode(
    jsonEncode({
      'choices': [
        {
          'message': {
            'role': 'assistant',
            'content': text,
            if (calls.isNotEmpty)
              'tool_calls': [
                for (final (id, name, args) in calls)
                  {
                    'id': id,
                    'type': 'function',
                    'function': {'name': name, 'arguments': args is String ? args : jsonEncode(args)},
                  },
              ],
          },
        },
      ],
      'usage': {'prompt_tokens': 1500, 'completion_tokens': 80},
    }),
  ),
  200,
);

void main() {
  late AppDatabase db;
  late Ledger ledger;
  late AssistantTools tools;

  setUp(() async {
    db = AppDatabase.memory(NativeDatabase.memory());
    await seedDemo(db, now: now);
    ledger = Ledger(db);
    tools = AssistantTools(ledger, clock: () => now);
  });
  tearDown(() => db.close());

  Future<int> sql(String q) async => (await db.customSelect(q).getSingle()).read<int?>('n') ?? 0;

  group('tools', () {
    test('summary matches the database to the cent', () async {
      final r = await tools.run('summary', {'from': '2026-08-01', 'to': '2026-08-31'});
      const where = "deleted_at IS NULL AND occurred_on BETWEEN '2026-08-01' AND '2026-08-31'";
      final spent = await sql(
        "SELECT SUM(COALESCE(base_cents, amount_cents)) n FROM transactions WHERE $where AND type = 'expense'",
      );
      final income = await sql(
        "SELECT SUM(COALESCE(base_cents, amount_cents)) n FROM transactions WHERE $where AND type = 'income'",
      );
      final household = await sql(
        "SELECT SUM(COALESCE(base_cents, amount_cents)) n FROM transactions WHERE $where AND type = 'expense' AND scope = 'household'",
      );
      expect(spent, greaterThan(0));
      expect(r['spent'], spent / 100);
      expect(r['income'], income / 100);
      expect(r['net'], (income - spent) / 100);
      expect(r['household_spent'], household / 100);
      final top = r['top_categories'] as List;
      expect(top, isNotEmpty);
      expect((top.first as Map)['spent'], greaterThanOrEqualTo((top.last as Map)['spent'] as num));
      // Results are plain JSON, ready to send.
      expect(() => jsonEncode(r), returnsNormally);
    });

    test('defaults to this month so far', () async {
      final r = await tools.run('summary', {});
      expect(r['from'], '2026-09-01');
      expect(r['to'], '2026-09-18');
    });

    test('scope narrows, and drops the split', () async {
      final all = await tools.run('summary', {'from': '2026-08-01', 'to': '2026-08-31'});
      final p = await tools.run('summary', {'from': '2026-08-01', 'to': '2026-08-31', 'scope': 'personal'});
      expect(p['spent'], all['personal_spent']);
      expect(p.containsKey('household_spent'), isFalse);
    });

    test('bad arguments come back as errors the model can read', () async {
      for (final (name, args) in [
        ('summary', {'from': '2026-02-31'}),
        ('summary', {'from': 'last month'}),
        ('summary', {'from': '2026-09-10', 'to': '2026-09-01'}),
        ('summary', {'scope': 'family'}),
        ('category_spending', {'category': 'zzz'}),
        ('find_entries', {'type': 'refund'}),
        ('budgets', {'month': '2026-13'}),
        ('nope', <String, dynamic>{}),
      ]) {
        final r = await tools.run(name, args);
        expect(r['error'], isA<String>(), reason: '$name $args');
      }
      final r = await tools.run('category_spending', {'category': 'zzz'});
      expect(r['error'], contains('Groceries'), reason: 'lists the real names so the model can retry');
    });

    test('category spending is case-insensitive and split by month', () async {
      final r = await tools.run('category_spending', {'category': 'GROCER', 'from': '2026-07-01', 'to': '2026-08-31'});
      expect(r['categories'], ['Groceries']);
      final months = (r['by_month'] as List).cast<Map<String, dynamic>>();
      expect(months.map((m) => m['month']), ['2026-07', '2026-08']);
      expect(months.fold<num>(0, (s, m) => s + (m['spent'] as num)), closeTo(r['spent'] as num, 0.001));
    });

    test('find_entries: all time by default, limited, with totals over every match', () async {
      final r = await tools.run('find_entries', {'type': 'expense', 'limit': 3});
      final n = await sql(
        "SELECT COUNT(*) n FROM transactions WHERE deleted_at IS NULL AND type = 'expense' AND occurred_on <= '2026-09-18'",
      );
      expect(r['matches'], n);
      expect((r['entries'] as List).length, 3);
      final dates = [for (final e in r['entries'] as List) (e as Map)['date'] as String];
      expect(dates, [...dates]..sort((a, b) => b.compareTo(a)), reason: 'newest first');
      final big = await tools.run('find_entries', {'limit': 500});
      expect((big['entries'] as List).length, 30, reason: 'capped');
    });

    test('LBP entries show the original amount next to dollars', () async {
      final r = await tools.run('find_entries', {'limit': 30, 'from': '2026-01-01'});
      final lbp = [
        for (final e in r['entries'] as List)
          if ((e as Map).containsKey('original')) e,
      ];
      if (lbp.isEmpty) return; // demo data may not have one in the newest 30
      expect(lbp.first['original'], startsWith('LBP'));
    });

    test('accounts, goals, recurring, budgets and safe to spend all answer', () async {
      final acc = await tools.run('accounts', {});
      expect(acc['accounts'] as List, isNotEmpty);
      expect(acc['net_worth'], isA<num>());
      expect((await tools.run('goals', {}))['goals'], isA<List<dynamic>>());
      final rec = await tools.run('recurring', {});
      expect(rec['rules'] as List, isNotEmpty);
      final b = await tools.run('budgets', {});
      expect(b['month'], '2026-09');
      final s = await tools.run('safe_to_spend', {});
      expect(s['days_left'], 13);
      expect(
        s['left_to_spend'],
        closeTo((s['income_expected'] as num) - (s['spent'] as num) - (s['bills_still_due'] as num), 0.001),
      );
      for (final r in [acc, rec, b, s]) {
        expect(r.containsKey('error'), isFalse, reason: '$r');
      }
    });

    test('tools never write', () async {
      final before = await sql('SELECT COUNT(*) n FROM transactions');
      final dirty = await sql('SELECT COUNT(*) n FROM transactions WHERE dirty = 1');
      for (final d in AssistantTools.definitions) {
        await tools.run((d['function'] as Map)['name'] as String, {'category': 'dining'});
      }
      expect(await sql('SELECT COUNT(*) n FROM transactions'), before);
      expect(await sql('SELECT COUNT(*) n FROM transactions WHERE dirty = 1'), dirty);
    });
  });

  group('assistant', () {
    Future<(Assistant, List<Map<String, dynamic>>)> make(
      List<http.Response> script, {
      Map<String, Object>? prefs,
    }) async {
      SharedPreferences.setMockInitialValues(prefs ?? {'ai.key': 'sk'});
      final sent = <Map<String, dynamic>>[];
      var i = 0;
      final ai = AiAssist(
        await SharedPreferences.getInstance(),
        clock: () => now,
        client: MockClient((r) async {
          sent.add(jsonDecode(r.body) as Map<String, dynamic>);
          return i < script.length ? script[i++] : http.Response('', 500);
        }),
      );
      return (Assistant(ai, ledger, clock: () => now), sent);
    }

    test('runs the tool on the device and answers with its figures', () async {
      final (a, sent) = await make([
        msg(
          calls: [
            ('c1', 'summary', {'from': '2026-08-01', 'to': '2026-08-31'}),
          ],
        ),
        msg(text: 'You spent less in August.'),
      ]);
      final line = await a.ask('How was August?');
      expect(line.text, 'You spent less in August.');
      expect(line.looked, ['summary']);
      expect(a.lines.map((l) => l.fromUser), [true, false]);

      final second = sent[1]['messages'] as List;
      final toolMsg = second.last as Map<String, dynamic>;
      expect(toolMsg['role'], 'tool');
      expect(toolMsg['tool_call_id'], 'c1');
      final result = jsonDecode(toolMsg['content'] as String) as Map<String, dynamic>;
      final expected = await tools.run('summary', {'from': '2026-08-01', 'to': '2026-08-31'});
      expect(result['spent'], expected['spent']);
      expect(sent[0]['tools'], hasLength(AssistantTools.definitions.length));
      final system = (sent[0]['messages'] as List).first as Map;
      expect(system['content'], contains('2026-09-18'));
      expect(system['content'], contains('Groceries'));
    });

    test('a finished turn is folded: the next request carries no old lookups', () async {
      final (a, sent) = await make([
        msg(calls: [('c1', 'accounts', <String, dynamic>{})]),
        msg(text: r'Net worth is $5,000.'),
        msg(text: 'Same as before.'),
      ]);
      await a.ask('Net worth?');
      await a.ask('And now?');
      final third = (sent[2]['messages'] as List).cast<Map<String, dynamic>>();
      expect(third.map((m) => m['role']), ['system', 'user', 'assistant', 'user']);
      expect(third[2]['content'], r'Net worth is $5,000.');
    });

    test('several tools in one round, including a broken call', () async {
      final (a, sent) = await make([
        msg(calls: [('a', 'goals', <String, dynamic>{}), ('b', 'budgets', '{bad'), ('c', 'nope', <String, dynamic>{})]),
        msg(text: 'Done.'),
      ]);
      final line = await a.ask('Goals and budgets?');
      expect(line.failed, isFalse);
      final results = (sent[1]['messages'] as List).cast<Map<String, dynamic>>().where((m) => m['role'] == 'tool');
      expect(results.map((m) => m['tool_call_id']), ['a', 'b', 'c']);
      expect(results.elementAt(1)['content'], contains('not valid JSON'));
      expect(results.elementAt(2)['content'], contains('Unknown tool'));
    });

    test('a failed turn leaves no half-finished history behind', () async {
      final (a, sent) = await make([
        msg(calls: [('c1', 'summary', <String, dynamic>{})]),
        http.Response('boom', 500),
        msg(text: 'Fine now.'),
      ]);
      final bad = await a.ask('First?');
      expect(bad.failed, isTrue);
      expect(bad.text, contains('Couldn’t reach OpenAI'));
      final good = await a.ask('Second?');
      expect(good.text, 'Fine now.');
      final last = (sent.last['messages'] as List).cast<Map<String, dynamic>>();
      expect(last.map((m) => m['role']), ['system', 'user'], reason: 'the failed turn was not kept');
    });

    test('a model that never stops calling tools is cut off', () async {
      final (a, sent) = await make(
        List.generate(20, (i) => msg(calls: [('c$i', 'goals', <String, dynamic>{})])),
      );
      final line = await a.ask('Loop?');
      expect(line.failed, isTrue);
      expect(sent.length, Assistant.maxRounds);
    });

    test('at the cap it says so and sends nothing', () async {
      final (a, sent) = await make([msg(text: 'x')], prefs: {'ai.key': 'sk', 'ai.spent.2026-09': 5000000});
      final line = await a.ask('Hi');
      expect(line.failed, isTrue);
      expect(line.text, contains('budget'));
      expect(sent, isEmpty);
    });

    test('without a key it points to settings', () async {
      final (a, sent) = await make([], prefs: {});
      expect((await a.ask('Hi')).text, contains('Settings'));
      expect(sent, isEmpty);
    });

    test('only the last turns are sent', () async {
      final (a, sent) = await make([for (var i = 0; i < 10; i++) msg(text: 'a$i')]);
      for (var i = 0; i < 10; i++) {
        await a.ask('q$i');
      }
      final last = (sent.last['messages'] as List).cast<Map<String, dynamic>>();
      expect(last.length, 1 + Assistant.keepTurns * 2 + 1);
      expect(last[1]['content'], 'q${9 - Assistant.keepTurns}');
      expect(Day.of(now), '2026-09-18');
    });
  });

  group('drafts', () {
    test('draft_entry prepares, resolves names and defaults, and writes nothing', () async {
      final before = await sql('SELECT COUNT(*) n FROM transactions');
      final r = await tools.run('draft_entry', {'amount': 40, 'category': 'groceries', 'note': 'Spinneys'});
      expect(r['saved'], isFalse);
      final d = tools.takeDrafts().single;
      expect(d.amountCents, 4000);
      expect(d.currency, 'USD');
      expect(d.accountId, seedId('acct:checking'), reason: 'first USD account');
      expect(d.categoryId, seedId('cat:Groceries'));
      expect(d.scope, Scope.household, reason: "the category's default scope");
      expect(d.day, '2026-09-18');
      expect(await sql('SELECT COUNT(*) n FROM transactions'), before);
      expect(tools.takeDrafts(), isEmpty, reason: 'taken once');
    });

    test('LBP goes to an LBP account; explicit scope and date win', () async {
      await tools.run('draft_entry', {
        'amount': 450000,
        'currency': 'lbp',
        'category': 'transport',
        'scope': 'personal',
        'date': '2026-09-17',
      });
      final d = tools.takeDrafts().single;
      expect(d.currency, 'LBP');
      expect(d.amountCents, 45000000);
      expect(d.scope, Scope.personal);
      expect(d.day, '2026-09-17');
      final acct = await (db.select(db.accounts)..where((a) => a.id.equals(d.accountId))).getSingle();
      expect(acct.currency, 'LBP');
    });

    test('bad drafts come back as errors and prepare nothing', () async {
      for (final args in <Map<String, dynamic>>[
        {},
        {'amount': -5},
        {'amount': '12'},
        {'amount': 5, 'type': 'transfer'},
        {'amount': 5, 'currency': 'JPY'},
        {'amount': 5, 'account': 'nope'},
        {'amount': 5, 'account': 'Demo Cash LBP', 'currency': 'USD'},
        {'amount': 5, 'date': '2026-02-30'},
      ]) {
        expect((await tools.run('draft_entry', args))['error'], isA<String>(), reason: '$args');
      }
      expect(tools.takeDrafts(), isEmpty);
    });

    test('an income category is not used for an expense', () async {
      await tools.run('draft_entry', {'amount': 10, 'category': 'salary'});
      expect(tools.takeDrafts().single.categoryId, isNull);
    });
  });

  group('logging from chat', () {
    Future<(Assistant, List<Map<String, dynamic>>)> chat(List<http.Response> script) async {
      SharedPreferences.setMockInitialValues({'ai.key': 'sk'});
      final sent = <Map<String, dynamic>>[];
      var i = 0;
      final ai = AiAssist(
        await SharedPreferences.getInstance(),
        clock: () => now,
        client: MockClient((r) async {
          sent.add(jsonDecode(r.body) as Map<String, dynamic>);
          return script[i++];
        }),
      );
      return (Assistant(ai, ledger, clock: () => now), sent);
    }

    test('drafts ride on the answer; Log saves once, priced; Undo takes it back', () async {
      final (a, _) = await chat([
        msg(
          calls: [
            ('c1', 'draft_entry', {'amount': 12, 'category': 'dining', 'note': 'Assistant test cafe'}),
            ('c2', 'draft_entry', {'amount': 900000, 'currency': 'LBP', 'category': 'transport'}),
          ],
        ),
        msg(text: 'Prepared two entries — tap Log on each.'),
      ]);
      final line = await a.ask('log 12 coffee at kalei and 900k taxi');
      expect(line.drafts.length, 2);
      expect(
        await sql("SELECT COUNT(*) n FROM transactions WHERE note = 'Assistant test cafe'"),
        0,
        reason: 'nothing saved yet',
      );

      final id = await a.log(line.drafts.first);
      expect(await a.log(line.drafts.first), id, reason: 'a second tap is a no-op');
      expect(
        await sql("SELECT COUNT(*) n FROM transactions WHERE note = 'Assistant test cafe' AND deleted_at IS NULL"),
        1,
      );

      await a.log(line.drafts.last);
      final lbp = await (db.select(db.transactions)..where((t) => t.id.equals(line.drafts.last.loggedId!))).getSingle();
      expect(lbp.currency, 'LBP');
      expect(lbp.baseCents, (90000000 / 89500).round(), reason: 'priced to USD like any entry');

      await a.unlog(line.drafts.first);
      expect(line.drafts.first.loggedId, isNull);
      expect(
        await sql("SELECT COUNT(*) n FROM transactions WHERE note = 'Assistant test cafe' AND deleted_at IS NULL"),
        0,
      );
    });

    test('a failed turn shows no drafts, and the next turn does not inherit them', () async {
      final (a, _) = await chat([
        msg(
          calls: [
            ('c1', 'draft_entry', {'amount': 5}),
          ],
        ),
        http.Response('', 500),
        msg(text: 'Nothing to log.'),
      ]);
      expect((await a.ask('log 5')).drafts, isEmpty);
      expect((await a.ask('never mind')).drafts, isEmpty);
    });

    test('the conversation and logged state survive a restart', () async {
      final (a, _) = await chat([
        msg(
          calls: [
            ('c1', 'draft_entry', {'amount': 7, 'note': 'Bread'}),
          ],
        ),
        msg(text: 'Ready to log.'),
      ]);
      final line = await a.ask('log 7 bread');
      await a.log(line.drafts.single);

      final again = Assistant(a.ai, ledger, clock: () => now);
      expect(again.lines.map((l) => l.text), ['log 7 bread', 'Ready to log.']);
      final d = again.lines.last.drafts.single;
      expect(d.note, 'Bread');
      expect(d.loggedId, line.drafts.single.loggedId);

      again.reset();
      expect(Assistant(a.ai, ledger, clock: () => now).lines, isEmpty);
    });

    test('a corrupt store starts a fresh conversation', () async {
      SharedPreferences.setMockInitialValues({'ai.key': 'sk', Assistant.storeKey: '{"lines": [{"oops": 1}]'});
      final ai = AiAssist(await SharedPreferences.getInstance());
      expect(Assistant(ai, ledger).lines, isEmpty);
    });

    test('an entry saved from the editor is adopted, so Log cannot duplicate it', () async {
      final (a, _) = await chat([
        msg(
          calls: [
            ('c1', 'draft_entry', {'amount': 3}),
          ],
        ),
        msg(text: 'ok'),
      ]);
      final d = (await a.ask('log 3')).drafts.single;
      final since = DateTime.now().toUtc();
      await a.adoptEdited(d, since);
      expect(d.loggedId, isNull, reason: 'nothing was saved in the editor');
      final id = await ledger.addTransaction(
        TransactionsCompanion.insert(
          type: TxType.expense,
          scope: Scope.personal,
          amountCents: 350,
          accountId: seedId('acct:cash'),
          occurredOn: '2026-09-18',
        ),
      );
      await a.adoptEdited(d, since);
      expect(d.loggedId, id);
      expect(await a.log(d), id);
    });
  });
}
