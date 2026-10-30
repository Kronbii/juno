import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/deeplink/quick_add.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/ios/intent_inbox.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/smart/categorizer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

/// An OpenAI-style reply whose content is [content].
http.Response answer(Object content) => http.Response.bytes(
  utf8.encode(
    jsonEncode({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': content is String ? content : jsonEncode(content)},
        },
      ],
      'usage': {'prompt_tokens': 600, 'completion_tokens': 12},
    }),
  ),
  200,
);

Map<String, dynamic> _map(Object? o) => o! as Map<String, dynamic>;

/// The system (first) or user (last) message of a sent request.
String message(Map<String, dynamic> body, {bool system = false}) {
  final m = (body['messages'] as List).cast<Map<String, dynamic>>();
  return (system ? m.first : m.last)['content'] as String;
}

List<String> allowedCategories(Map<String, dynamic> body) {
  final schema = _map(_map(_map(body['response_format'])['json_schema'])['schema']);
  return (_map(_map(schema['properties'])['category'])['enum'] as List).cast<String>();
}

void main() {
  late List<Map<String, dynamic>> sent;
  late http.Response Function(Map<String, dynamic> body) respond;

  Future<AiAssist> ai() async {
    SharedPreferences.setMockInitialValues({'ai.key': 'sk-test'});
    final sp = await SharedPreferences.getInstance();
    return AiAssist(
      sp,
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        sent.add(body);
        return respond(body);
      }),
    );
  }

  setUp(() {
    sent = [];
    respond = (_) => answer({'category': 'Dining', 'sure': true});
  });

  Future<AppDatabase> fresh() async {
    final db = AppDatabase.memory(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    return db;
  }

  Future<List<Category>> cats(AppDatabase db) => db.select(db.categories).get();

  TransactionsCompanion entry(String note, String category) => TransactionsCompanion.insert(
    type: TxType.expense,
    scope: Scope.personal,
    amountCents: 500,
    accountId: seedId('acct:cash'),
    categoryId: Value(seedId('cat:$category')),
    occurredOn: Day.today(),
    note: Value(note),
  );

  Future<CategoryGuess?> guess(AppDatabase db, String note, {AiAssist? with_, Scope scope = Scope.personal}) async =>
      guessCategory(
        db,
        note: note,
        scope: scope,
        type: TxType.expense,
        amountCents: 1250,
        currency: 'USD',
        categories: await cats(db),
        ai: with_,
      );

  group('filing a note', () {
    test('a note filed before goes where it went last time, without the AI', () async {
      final db = await fresh();
      addTearDown(db.close);
      final l = Ledger(db);
      await l.addTransaction(entry('Abu Elie', 'Groceries'));
      // A later correction wins.
      await l.addTransaction(entry('abu elie', 'Shopping'));
      final g = await guess(db, 'Abu Elie ', with_: await ai());
      expect(g!.category.name, 'Shopping');
      expect(g.source, GuessSource.history);
      expect(sent, isEmpty);
    });

    test('with the AI off, a plain keyword is matched on the device', () async {
      final db = await fresh();
      addTearDown(db.close);
      final g = await guess(db, 'coffee');
      expect(g!.category.name, 'Coffee');
      expect(g.source, GuessSource.keywords);
      expect(g.provisional, isTrue, reason: 'for the AI to check once it can');
    });

    test('a keyword match still asks the AI, and its pick wins', () async {
      final db = await fresh();
      addTearDown(db.close);
      final local = await guessOnDevice(
        db,
        note: 'coffee with rania',
        scope: Scope.personal,
        type: TxType.expense,
        categories: await cats(db),
      );
      expect(local!.category.name, 'Coffee', reason: 'what keywords alone would say');
      respond = (_) => answer({'category': 'Dining', 'sure': true});
      final g = await guess(db, 'coffee with rania', with_: await ai());
      expect(g!.category.name, 'Dining');
      expect(g.source, GuessSource.ai);
      expect(g.provisional, isFalse);
      expect(sent, hasLength(1));
    });

    test('an unreachable AI leaves the keyword guess, marked for a second look', () async {
      final db = await fresh();
      addTearDown(db.close);
      respond = (_) => throw http.ClientException('offline');
      final g = await guess(db, 'coffee', with_: await ai());
      expect(g!.category.name, 'Coffee');
      expect(g.source, GuessSource.keywords);
      expect(g.provisional, isTrue);
      expect(sent, hasLength(1));
    });

    test('guesses awaiting a second look teach nothing until confirmed', () async {
      final db = await fresh();
      addTearDown(db.close);
      final l = Ledger(db);
      final id = await l.addTransaction(entry('abu elie', 'Coffee'));
      await l.markFiling(id, byAi: false);
      expect(await l.merchantCategoryMemory(), isNot(contains('abu elie')));
      final byId = {for (final c in await cats(db)) c.id: c};
      expect(await pastExamples(db, 'abu elie', byId: byId), isEmpty, reason: 'nor shown to the AI as yours');
      expect((await guess(db, 'abu elie'))?.source, isNot(GuessSource.history));
      await l.updateTransaction(id, const TransactionsCompanion(note: Value('abu elie')));
      expect((await l.merchantCategoryMemory())['abu elie'], seedId('cat:Coffee'), reason: 'edited: yours');
      expect(await pastExamples(db, 'abu elie', byId: byId), [('abu elie', 'Coffee')]);
    });

    test('a new note asks the AI once, with structured output, your categories and related past entries', () async {
      final db = await fresh();
      addTearDown(db.close);
      final l = Ledger(db);
      await l.addTransaction(entry('tawlet lunch', 'Dining'));
      await l.addTransaction(entry('generator bill', 'Utilities'));
      final g = await guess(db, 'tawlet with friends', with_: await ai(), scope: Scope.household);
      expect(g!.category.name, 'Dining');
      expect(g.source, GuessSource.ai);
      expect(sent, hasLength(1));
      final body = sent.single;
      final format = body['response_format'] as Map<String, dynamic>;
      expect(format['type'], 'json_schema');
      final allowed = allowedCategories(body);
      expect(allowed, contains('Dining'));
      expect(allowed, isNot(contains('Salary')), reason: 'expense categories only');
      final user = message(body);
      expect(user, contains('"tawlet with friends"'));
      expect(user, contains('for Household'));
      expect(user, contains('Usual for Household: Groceries'));
      expect(
        user.indexOf('"tawlet lunch" → Dining'),
        lessThan(user.indexOf('"generator bill" → Utilities')),
        reason: 'past entries sharing a word come first',
      );
      expect(message(body, system: true), contains('Arabizi'));
    });

    test('an off-list or broken answer files nothing; an unsure one says so', () async {
      final db = await fresh();
      addTearDown(db.close);
      final assist = await ai();
      respond = (_) => answer({'category': 'Lottery', 'sure': true});
      expect(await guess(db, 'mystery thing', with_: assist), isNull);
      respond = (_) => answer('no idea');
      expect(await guess(db, 'mystery thing', with_: assist), isNull);
      respond = (_) => answer({'category': 'dining ', 'sure': false});
      final g = await guess(db, 'mystery thing', with_: assist);
      expect(g!.category.name, 'Dining', reason: 'case and spaces forgiven, names kept exact');
      expect(g.sure, isFalse);
    });

    test('no AI, nothing to match: null, never a wrong category', () async {
      final db = await fresh();
      addTearDown(db.close);
      expect(await guess(db, 'zxq'), isNull);
    });
  });

  group('filing quick entries', () {
    late AppDatabase db;
    late Ledger l;

    setUp(() async {
      db = await fresh();
      l = Ledger(db);
    });
    tearDown(() => db.close());

    Future<String> quick(String note, {Scope scope = Scope.personal, int daysAgo = 0}) => l.addTransaction(
      TransactionsCompanion.insert(
        type: TxType.expense,
        scope: scope,
        amountCents: 900,
        accountId: seedId('acct:cash'),
        occurredOn: Day.of(DateTime.now().subtract(Duration(days: daysAgo))),
        note: Value(note),
        tags: const Value(',quick,'),
      ),
    );
    Future<String?> categoryOf(String id) async =>
        (await (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle()).categoryId;
    void offline() => respond = (_) => throw http.ClientException('offline');
    // The AI's answer for each note; anything else gets an unusable reply.
    void picks(Map<String, Object> byNote) => respond = (body) {
      for (final MapEntry(key: note, value: pick) in byNote.entries) {
        if (message(body).toLowerCase().contains('note: "${note.toLowerCase()}"')) return answer(pick);
      }
      return answer('nothing');
    };

    test('offline: filed by keywords at once, checked by the AI once it answers; offline runs cost no tries', () async {
      final coffee = await quick('coffee kalei');
      final taxi = await quick('taxi hamra');
      final assist = await ai();
      offline();
      for (var run = 0; run < 3; run++) {
        expect(await fileQuickEntries(db, ledger: l, ai: assist), run == 0 ? 2 : 0);
      }
      expect(await categoryOf(coffee), seedId('cat:Coffee'), reason: 'filed on the device, no waiting');
      expect(await categoryOf(taxi), seedId('cat:Transport'));
      expect(sent, hasLength(3), reason: 'one attempt a run: no answer ends it');
      expect((await l.filings()).keys, unorderedEquals([coffee, taxi]));
      expect(await db.meta('quick.filing.tries.$coffee'), isNull);
      expect(await db.meta('quick.filing.tries.$taxi'), isNull);

      sent.clear();
      picks({
        'coffee kalei': {'category': 'Dining', 'sure': true},
        'taxi hamra': {'category': 'Transport', 'sure': true},
      });
      expect(await fileQuickEntries(db, ledger: l, ai: assist), 1);
      expect(await categoryOf(coffee), seedId('cat:Dining'), reason: 'the AI’s pick replaces the keyword’s');
      expect(await categoryOf(taxi), seedId('cat:Transport'));
      expect(sent, hasLength(2));
      expect(await l.filings(), isEmpty);

      // Checked, so now it's your history: the same note again needs no AI.
      sent.clear();
      final again = await quick('coffee kalei');
      await fileQuickEntries(db, ledger: l, ai: assist);
      expect(await categoryOf(again), seedId('cat:Dining'));
      expect(sent, isEmpty);
      expect(await l.filings(), isEmpty);
    });

    test('an entry changed since it was filed is never re-filed, here or from another device', () async {
      final mine = await quick('coffee');
      final resaved = await quick('coffee beans');
      final moved = await quick('coffee cups');
      final assist = await ai();
      offline();
      await fileQuickEntries(db, ledger: l, ai: assist);
      expect((await l.filings()).keys, unorderedEquals([mine, resaved, moved]));

      await l.updateTransaction(mine, TransactionsCompanion(categoryId: Value(seedId('cat:Dining'))));
      expect((await l.filings()).keys, isNot(contains(mine)), reason: 'an edit makes it yours');
      // By sync from another device: saved again as it was, or recategorised.
      final t = await (db.select(db.transactions)..where((t) => t.id.equals(resaved))).getSingle();
      await (db.update(db.transactions)..where((x) => x.id.equals(resaved))).write(
        TransactionsCompanion(updatedAt: Value(t.updatedAt.add(const Duration(seconds: 5)))),
      );
      await (db.update(
        db.transactions,
      )..where((x) => x.id.equals(moved))).write(TransactionsCompanion(categoryId: Value(seedId('cat:Health'))));

      sent.clear();
      respond = (_) => answer({'category': 'Education', 'sure': true});
      expect(await fileQuickEntries(db, ledger: l, ai: assist), 0);
      expect(sent, isEmpty);
      expect(await categoryOf(mine), seedId('cat:Dining'));
      expect(await categoryOf(resaved), seedId('cat:Coffee'));
      expect(await categoryOf(moved), seedId('cat:Health'));
      expect(await l.filings(), isEmpty);
    });

    test('an unsure pick shows as such until you edit it, is not asked again and teaches nothing', () async {
      final id = await quick('tawlet');
      final assist = await ai();
      respond = (_) => answer({'category': 'Coffee', 'sure': false});
      expect(await fileQuickEntries(db, ledger: l, ai: assist), 1);
      expect(await categoryOf(id), seedId('cat:Coffee'));
      expect(await l.watchUnsureFilings().first, {id: seedId('cat:Coffee')});
      expect(await l.merchantCategoryMemory(), isNot(contains('tawlet')), reason: 'a guess isn’t your habit yet');
      await fileQuickEntries(db, ledger: l, ai: assist);
      expect(sent, hasLength(1), reason: 'asked once');
      await l.updateTransaction(id, const TransactionsCompanion(note: Value('tawlet')));
      expect(await l.watchUnsureFilings().first, isEmpty, reason: 'opened and saved: confirmed');
      expect((await l.merchantCategoryMemory())['tawlet'], seedId('cat:Coffee'));
    });

    test('an answer that places nothing costs a try; two tries each at most', () async {
      final a = await quick('tawlet', scope: Scope.other);
      final b = await quick('zzz', scope: Scope.other);
      final assist = await ai();
      picks({
        'tawlet': {'category': 'Other', 'sure': true},
      });
      expect(await fileQuickEntries(db, ledger: l, ai: assist), 1);
      expect(await categoryOf(a), seedId('cat:Other'));
      final filed = await (db.select(db.transactions)..where((t) => t.id.equals(a))).getSingle();
      expect(filed.scope, Scope.other, reason: 'filing never changes who it was for');
      await fileQuickEntries(db, ledger: l, ai: assist);
      final calls = sent.length;
      await fileQuickEntries(db, ledger: l, ai: assist);
      expect(sent.length, calls, reason: '"zzz" had its two tries');
      expect(await categoryOf(b), isNull);
    });

    test('at most [max] AI calls a run; the rest wait for the next', () async {
      for (var i = 0; i < 5; i++) {
        await quick('mystery $i');
      }
      final assist = await ai();
      respond = (_) => answer({'category': 'Dining', 'sure': true});
      expect(await fileQuickEntries(db, ledger: l, ai: assist, max: 2), 2);
      expect(sent, hasLength(2));
      expect(await fileQuickEntries(db, ledger: l, ai: assist, max: 2), 2);
      expect(await fileQuickEntries(db, ledger: l, ai: assist, max: 2), 1);
      expect(sent, hasLength(5));
    });

    test('keyword guesses older than two weeks stand; marks of deleted entries go', () async {
      final old = await quick('coffee', daysAgo: 20);
      final gone = await quick('coffee shop');
      for (final id in [old, gone]) {
        await l.updateTransaction(id, TransactionsCompanion(categoryId: Value(seedId('cat:Coffee'))));
        await l.markFiling(id, byAi: false);
      }
      // Deleted on another device, arriving by sync.
      await (db.update(
        db.transactions,
      )..where((t) => t.id.equals(gone))).write(TransactionsCompanion(deletedAt: Value(DateTime.now().toUtc())));
      final assist = await ai();
      await fileQuickEntries(db, ledger: l, ai: assist);
      expect(sent, isEmpty);
      expect(await l.filings(), isEmpty);
      expect(await categoryOf(old), seedId('cat:Coffee'));
    });

    test('from the iOS inbox: a sentence’s category gets the AI’s second look; one you picked is final', () async {
      final added = await IntentInbox.importItems(db, const [
        InboxItem(id: 'A1', text: '12 coffee kalei'),
        InboxItem(id: 'B2', amount: 5, category: 'Coffee', scope: 'personal', note: 'beans'),
        InboxItem(id: 'C3', amount: 7, scope: 'personal', note: 'taxi hamra'),
      ]);
      expect(added, 3);
      expect(await categoryOf('a1'), seedId('cat:Coffee'), reason: 'read from the sentence at once');
      expect((await l.filings()).keys, ['a1']);
      expect(await categoryOf('c3'), isNull, reason: 'Log purchase: filed by Juno after import');

      final assist = await ai();
      // The sentence's note is what's left of it: "Kalei".
      picks({
        'kalei': {'category': 'Dining', 'sure': true},
        'taxi hamra': {'category': 'Transport', 'sure': true},
      });
      await fileQuickEntries(db, ledger: l, ai: assist);
      expect(await categoryOf('a1'), seedId('cat:Dining'));
      expect(await categoryOf('b2'), seedId('cat:Coffee'), reason: 'chosen in Siri or a widget');
      expect(await categoryOf('c3'), seedId('cat:Transport'));
      expect(sent, hasLength(2));
      expect(await l.filings(), isEmpty);
    });

    test('a capped budget, a server error or a slow AI ends the run and costs no tries', () async {
      final id = await quick('mystery');
      Future<void> run(AiAssist a, {Duration timeout = const Duration(seconds: 8)}) async {
        expect(await fileQuickEntries(db, ledger: l, ai: a, timeout: timeout), 0);
        expect(await db.meta('quick.filing.tries.$id'), isNull);
        expect(await categoryOf(id), isNull);
      }

      // At the monthly cap nothing is even sent.
      final now = DateTime.now();
      final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      SharedPreferences.setMockInitialValues({'ai.key': 'sk-test', 'ai.spent.$month': 5000000});
      var capped = 0;
      await run(
        AiAssist(
          await SharedPreferences.getInstance(),
          client: MockClient((req) async {
            capped++;
            return answer({'category': 'Dining', 'sure': true});
          }),
        ),
      );
      expect(capped, 0);

      final assist = await ai();
      respond = (_) => http.Response('{"error":{"code":"invalid_api_key"}}', 401);
      await run(assist);
      respond = (_) => http.Response('upstream down', 500);
      await run(assist);
      expect(sent, hasLength(2), reason: 'one attempt a run');

      final slow = AiAssist(
        await SharedPreferences.getInstance(),
        client: MockClient((req) async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return answer({'category': 'Dining', 'sure': true});
        }),
      );
      await run(slow, timeout: const Duration(milliseconds: 50));

      // Back to normal: still has both of its tries.
      respond = (_) => answer({'category': 'Dining', 'sure': true});
      expect(await fileQuickEntries(db, ledger: l, ai: assist), 1);
      expect(await categoryOf(id), seedId('cat:Dining'));
    });

    test('a keyword guess you since filed the same way by hand is settled from history, without the AI', () async {
      final id = await quick('coffee kalei');
      final assist = await ai();
      offline();
      await fileQuickEntries(db, ledger: l, ai: assist);
      expect((await l.filings()).keys, [id]);
      // Logged again in the app and filed by hand.
      await l.addTransaction(entry('coffee kalei', 'Dining'));
      sent.clear();
      respond = (_) => answer({'category': 'Education', 'sure': true});
      expect(await fileQuickEntries(db, ledger: l, ai: assist), 1);
      expect(await categoryOf(id), seedId('cat:Dining'));
      expect(sent, isEmpty);
      expect(await l.filings(), isEmpty);
    });

    test('when the AI agrees with the keywords the entry is not rewritten, and becomes history', () async {
      final id = await quick('coffee');
      final assist = await ai();
      offline();
      await fileQuickEntries(db, ledger: l, ai: assist);
      Future<Transaction> row() => (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();
      final before = await row();
      respond = (_) => answer({'category': 'Coffee', 'sure': true});
      expect(await fileQuickEntries(db, ledger: l, ai: assist), 0);
      expect((await row()).updatedAt, before.updatedAt, reason: 'nothing new to sync');
      expect(await l.filings(), isEmpty);
      expect((await l.merchantCategoryMemory())['coffee'], seedId('cat:Coffee'));
    });

    test('with no AI set up, keyword guesses are final and teach your history', () async {
      final id = await quick('coffee kalei');
      expect(await fileQuickEntries(db, ledger: l), 1);
      expect(await categoryOf(id), seedId('cat:Coffee'));
      expect(await l.filings(), isEmpty);
      expect((await l.merchantCategoryMemory())['coffee kalei'], seedId('cat:Coffee'));
      // Marked by a Back Tap link while the AI was off: cleared on the next run.
      final linked = await quick('coffee beans');
      await l.updateTransaction(linked, TransactionsCompanion(categoryId: Value(seedId('cat:Coffee'))));
      await l.markFiling(linked, byAi: false);
      await fileQuickEntries(db, ledger: l);
      expect(await l.filings(), isEmpty);
    });

    test('a corrupt mark is dropped rather than hiding the entry from your history forever', () async {
      final id = await l.addTransaction(entry('abu elie', 'Coffee'));
      await db.setMeta(Ledger.filingKey(id), '{not json');
      expect(await l.merchantCategoryMemory(), isNot(contains('abu elie')));
      expect(await l.watchUnsureFilings().first, isEmpty);
      await fileQuickEntries(db, ledger: l);
      expect(await db.meta(Ledger.filingKey(id)), isNull);
      expect((await l.merchantCategoryMemory())['abu elie'], seedId('cat:Coffee'));
    });

    test('years of unsure marks never opened: the run stays quick and correct', () async {
      await db.transaction(() async {
        for (var i = 0; i < 1500; i++) {
          final id = await l.addTransaction(entry('thing $i', 'Coffee'));
          await l.markFiling(id, byAi: true);
        }
      });
      final fresh = await quick('tawlet');
      final assist = await ai();
      respond = (_) => answer({'category': 'Dining', 'sure': true});
      final sw = Stopwatch()..start();
      expect(await fileQuickEntries(db, ledger: l, ai: assist), 1);
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      expect(sent, hasLength(1), reason: 'unsure picks are never asked again');
      expect(await l.filings(), hasLength(1500));
      expect(await categoryOf(fresh), seedId('cat:Dining'));
    });
  });

  test('links: scope=other is understood', () {
    expect(QuickAdd.parse(Uri.parse('juno://add?amount=3&note=x&scope=Other'))!.scope, Scope.other);
    expect(QuickAdd.parse(Uri.parse('juno://add?amount=3&scope=household'))!.scope, Scope.household);
  });

  testWidgets('Back Tap link: amount, note and Other → filed by the AI, saved for Other, toast says where', (
    tester,
  ) async {
    final h = await boot(
      tester,
      demo: false,
      prefs: {'ai.key': 'sk-test'},
      ai: (sp) => AiAssist(sp, client: MockClient((req) async => answer({'category': 'Gifts', 'sure': true}))),
    );
    await h.go('/settings/back-tap');
    final field = find.byType(TextField).last;
    await tester.ensureVisible(field);
    await tester.enterText(field, 'juno://add?amount=25&note=flowers%20for%20rania&scope=other');
    await tester.tap(find.text('Run link'));
    await h.settle(8);
    final t = (await tester.runAsync(() => h.db.select(h.db.transactions).get()))!.single;
    expect(t.categoryId, seedId('cat:Gifts'));
    expect(t.scope, Scope.other);
    expect(t.note, 'flowers for rania');
    expect(t.tagList, contains('quick'));
    expect(find.textContaining('Gifts · Other'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await h.dispose();
  });

  testWidgets('Back Tap sentence link: "25 flowers for rania" + Other → amount and note read, filed, saved', (
    tester,
  ) async {
    final h = await boot(
      tester,
      demo: false,
      prefs: {'ai.key': 'sk-test'},
      ai: (sp) => AiAssist(sp, client: MockClient((req) async => answer({'category': 'Gifts', 'sure': true}))),
    );
    await h.go('/settings/back-tap');
    final field = find.byType(TextField).last;
    await tester.ensureVisible(field);
    await tester.enterText(field, 'juno://add?scope=other&text=25%20flowers%20for%20rania');
    await tester.tap(find.text('Run link'));
    await h.settle(8);
    final t = (await tester.runAsync(() => h.db.select(h.db.transactions).get()))!.single;
    expect(t.amountCents, 2500);
    expect(t.categoryId, seedId('cat:Gifts'));
    expect(t.scope, Scope.other);
    expect(t.note.toLowerCase(), contains('flowers'));
    expect(tester.takeException(), isNull);
    await h.dispose();
  });

  testWidgets('Back Tap link with the AI unreachable: filed by keywords at once, left for the AI to check', (
    tester,
  ) async {
    final h = await boot(
      tester,
      demo: false,
      prefs: {'ai.key': 'sk-test'},
      ai: (sp) => AiAssist(sp, client: MockClient((req) async => throw http.ClientException('offline'))),
    );
    await h.go('/settings/back-tap');
    final field = find.byType(TextField).last;
    await tester.ensureVisible(field);
    await tester.enterText(field, 'juno://add?amount=4&note=coffee&scope=personal');
    await tester.tap(find.text('Run link'));
    await h.settle(8);
    final t = (await tester.runAsync(() => h.db.select(h.db.transactions).get()))!.single;
    expect(t.categoryId, seedId('cat:Coffee'));
    final marks = (await tester.runAsync(() => h.ledger.filings()))!;
    expect(marks[t.id]?.byAi, isFalse);
    expect(find.textContaining('Coffee · Personal'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await h.dispose();
  });

  testWidgets('Activity: an unsure AI filing shows a "?" until you open the entry and save it', (tester) async {
    final h = await boot(
      tester,
      demo: false,
      setup: (db) async {
        final l = Ledger(db);
        final id = await l.addTransaction(
          TransactionsCompanion.insert(
            type: TxType.expense,
            scope: Scope.personal,
            amountCents: 900,
            accountId: seedId('acct:cash'),
            categoryId: Value(seedId('cat:Coffee')),
            occurredOn: Day.today(),
            note: const Value('tawlet'),
            tags: const Value(',quick,'),
          ),
        );
        await l.markFiling(id, byAi: true);
      },
    );
    await h.go('/activity');
    expect(find.textContaining('Coffee?'), findsOneWidget);
    await tester.tap(find.text('tawlet'));
    await h.settle();
    await tester.tap(find.textContaining(r'Save $9.00').first);
    await h.settle();
    expect(find.textContaining('Coffee?'), findsNothing, reason: 'saved as it was: confirmed');
    expect(find.textContaining('Coffee'), findsWidgets);
    expect(await tester.runAsync(() => h.ledger.filings()), isEmpty);
    expect(tester.takeException(), isNull);
    await h.dispose();
  });
}
