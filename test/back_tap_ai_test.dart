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

    test('a plain keyword is matched on the device, without the AI', () async {
      final db = await fresh();
      addTearDown(db.close);
      final g = await guess(db, 'coffee', with_: await ai());
      expect(g!.category.name, 'Coffee');
      expect(g.source, GuessSource.keywords);
      expect(sent, isEmpty);
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

  group('filing later', () {
    test('quick entries saved uncategorised are filed when the AI is back; two tries each at most', () async {
      final db = await fresh();
      addTearDown(db.close);
      final l = Ledger(db);
      Future<String> quick(String note) => l.addTransaction(
        TransactionsCompanion.insert(
          type: TxType.expense,
          scope: Scope.other,
          amountCents: 900,
          accountId: seedId('acct:cash'),
          occurredOn: Day.today(),
          note: Value(note),
          tags: const Value(',quick,'),
        ),
      );
      final a = await quick('tawlet');
      final b = await quick('zzz');
      final assist = await ai();
      respond = (body) {
        final user = message(body);
        return user.contains('note: "tawlet"') ? answer({'category': 'Dining', 'sure': true}) : answer('nothing');
      };
      expect(await fileUncategorisedQuickEntries(db, ledger: l, ai: assist), 1);
      final filed = await (db.select(db.transactions)..where((t) => t.id.equals(a))).getSingle();
      expect(filed.categoryId, seedId('cat:Dining'));
      expect(filed.scope, Scope.other, reason: 'filing never changes who it was for');
      await fileUncategorisedQuickEntries(db, ledger: l, ai: assist);
      final calls = sent.length;
      await fileUncategorisedQuickEntries(db, ledger: l, ai: assist);
      expect(sent.length, calls, reason: '"zzz" had its two tries');
      expect((await (db.select(db.transactions)..where((t) => t.id.equals(b))).getSingle()).categoryId, isNull);
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
}
