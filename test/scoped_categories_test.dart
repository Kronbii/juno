import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/db/category_restructure.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/deeplink/quick_add.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/features/add/entry_sheet.dart';
import 'package:juno/features/import/csv_import.dart';

import 'support/fake_remote.dart';
import 'support/harness.dart';

// Categories each belong to one scope; the scope of every expense is its
// category's. These tests hold the move from the old shape (a category only
// suggested a scope) and every way in that could break the rule again.

/// A real ledger from before scoped categories (ids, kinds, scopes,
/// categories and amounts; no notes): (id, name, kind, scope, archived,
/// deleted, icon, colour, sort).
const _oldCategories = [
  ('8fac907e-6043-5b2c-8bf5-7e4fee55c439', 'Groceries', 'expense', 'household', false, false, 'cart', 0, 0),
  ('e73589db-46af-5539-952d-b76c25ec1280', 'Outings', 'expense', 'personal', false, false, 'beauty', 1, 1),
  ('86e3f117-1ac7-5963-979a-19492a24925e', 'Coffee', 'expense', 'personal', true, true, 'coffee', 4, 2),
  ('72a0e7e1-651d-5957-a539-c8a63f72b35c', 'Motorcycle', 'expense', 'personal', false, false, 'car', 2, 3),
  ('bf4119f6-9f2c-53fc-9b50-4f19d9344e73', 'Transportation', 'expense', 'personal', false, false, 'fuel', 3, 4),
  ('7c2862b3-1d43-5c2f-bfd2-8b6ddaea761a', 'Rent', 'expense', 'household', false, false, 'home', 6, 5),
  ('40fe364e-a208-561e-84bf-c204bb21e1a8', 'Utilities', 'expense', 'household', false, false, 'bolt', 3, 6),
  ('447cc364-1e09-5500-983e-353e509bc733', 'Internet & phone', 'expense', 'household', false, false, 'wifi', 5, 7),
  ('eabe9edd-d553-5dd5-a930-dec09bb3d98a', 'Subscriptions', 'expense', 'personal', false, false, 'repeat', 7, 8),
  ('ad97644b-c223-53f9-9aef-2d69fd198ebc', 'Shopping', 'expense', 'personal', false, false, 'bag', 4, 9),
  ('2a89bb12-3672-5cca-951b-999bea4da06d', 'Health', 'expense', 'personal', true, true, 'health', 2, 10),
  ('ee0905a3-6bd3-5e85-acbf-e1d6678dea3f', 'Fitness', 'expense', 'personal', true, true, 'fitness', 5, 11),
  ('4c2a104d-770b-5571-b9ca-e33a91f04781', 'Gifts', 'expense', 'personal', true, true, 'gift', 4, 12),
  ('8cad9ab6-f1a4-5da0-b587-02a916130405', 'Travel', 'expense', 'personal', true, true, 'plane', 0, 13),
  ('cc95bb4b-80a5-5e6a-8197-40a8b383a7b1', 'Dates', 'expense', 'personal', false, false, 'ticket', 7, 14),
  ('782f8eeb-ec54-5285-85cc-153815485e3b', 'Household supplies', 'expense', 'household', true, true, 'spray', 2, 15),
  ('3d3e99fb-0a81-5578-974c-c4f13bf67a48', 'Education', 'expense', 'personal', true, true, 'book', 6, 16),
  ('b02cc4eb-f605-54b9-9f67-251e7966bfd5', 'Other Personal', 'expense', 'personal', false, false, 'dots', 6, 17),
  ('01a15476-6254-708e-b414-0dd0ee629714', 'Other', 'expense', 'household', false, false, 'dots', 0, 18),
  ('91a43457-6125-5048-a233-1cae4f6631e1', 'Salary', 'income', 'personal', false, false, 'briefcase', 5, 18),
  ('56a6f079-e0ea-502c-ad72-9d53fe288623', 'Freelance', 'income', 'personal', false, false, 'laptop', 2, 19),
  ('7d6c0a4c-56be-5c4c-ae02-8c6bab75a0cd', 'Refunds', 'income', 'personal', true, true, 'undo', 0, 20),
  ('158e32d8-8c41-5e67-b79b-86e0ce124da5', 'Other income', 'income', 'personal', false, false, 'plus', 3, 21),
];

/// (id, type, scope, category, cents) and where each one belongs after:
/// (starter key, scope).
const _oldEntries = [
  ('01a1540c-02e6-75fa-82c9-1392b5dd0b0e', 'expense', 'household', '7c2862b3-1d43-5c2f-bfd2-8b6ddaea761a', 60000),
  ('01a1540d-0dcf-74b4-9298-7089c627718a', 'expense', 'household', '447cc364-1e09-5500-983e-353e509bc733', 5000),
  ('01a1540d-7471-712f-9cfd-ecb34802d92b', 'expense', 'household', '40fe364e-a208-561e-84bf-c204bb21e1a8', 20000),
  ('01a1540d-bc40-7c7f-b150-34acc3d60e69', 'expense', 'household', 'b02cc4eb-f605-54b9-9f67-251e7966bfd5', 10000),
  ('01a15410-2888-7b27-acbb-49ffa1492b4e', 'expense', 'household', '8fac907e-6043-5b2c-8bf5-7e4fee55c439', 1200),
  ('01a15410-dfe6-7309-ab88-c3f82583811e', 'expense', 'household', '8fac907e-6043-5b2c-8bf5-7e4fee55c439', 4100),
  ('01a15411-4ce2-7d5e-ad8e-aa6f38adf327', 'expense', 'personal', 'e73589db-46af-5539-952d-b76c25ec1280', 1000),
  ('01a15411-9c30-71ea-b304-bd78b6b43ff3', 'expense', 'personal', 'b02cc4eb-f605-54b9-9f67-251e7966bfd5', 2500),
  ('01a15411-eae4-7547-90af-3a5db9bdf9d9', 'expense', 'personal', 'b02cc4eb-f605-54b9-9f67-251e7966bfd5', 2000),
  ('01a15412-5b32-7021-9048-d795b2fe552e', 'expense', 'personal', 'cc95bb4b-80a5-5e6a-8197-40a8b383a7b1', 2000),
  ('01a15412-76dd-763e-adb0-29997570895f', 'expense', 'personal', 'e73589db-46af-5539-952d-b76c25ec1280', 1200),
  ('01a15413-06d1-75fb-8c96-ece56f4a71b1', 'expense', 'personal', 'e73589db-46af-5539-952d-b76c25ec1280', 700),
  ('01a15413-4722-7502-b23a-bb9e10b7f76a', 'expense', 'personal', 'e73589db-46af-5539-952d-b76c25ec1280', 1500),
  ('01a15413-6a5f-7377-a598-7d4e9b8f75e3', 'expense', 'personal', 'e73589db-46af-5539-952d-b76c25ec1280', 1000),
  ('01a15413-a27a-79fe-8b52-fe05a0c0fc55', 'expense', 'personal', 'bf4119f6-9f2c-53fc-9b50-4f19d9344e73', 1700),
  ('01a15413-dbc7-7164-93d2-bfdb3a889906', 'income', 'personal', '91a43457-6125-5048-a233-1cae4f6631e1', 220000),
  ('01a15414-b6a7-7074-917f-ac5d3db17f70', 'expense', 'personal', 'b02cc4eb-f605-54b9-9f67-251e7966bfd5', 2500),
  ('01a15414-f2f9-7ef3-811b-98e350739179', 'expense', 'personal', 'b02cc4eb-f605-54b9-9f67-251e7966bfd5', 1200),
  ('01a15417-20e1-7084-8fbe-510531f9ee6b', 'expense', 'personal', 'eabe9edd-d553-5dd5-a930-dec09bb3d98a', 2000),
  ('01a159bd-7e7e-72ff-b031-526905bc4120', 'expense', 'personal', '8fac907e-6043-5b2c-8bf5-7e4fee55c439', 1000),
  ('01a159d6-fd53-73b9-a427-717febfc7c73', 'expense', 'personal', 'b02cc4eb-f605-54b9-9f67-251e7966bfd5', 5000),
  ('3173cb51-b6f7-4a40-8c48-9ff4425bb6d3', 'expense', 'personal', 'e73589db-46af-5539-952d-b76c25ec1280', 700),
  ('47242e1d-6032-43a4-8ac8-5afe4b5a4d44', 'expense', 'household', 'ad97644b-c223-53f9-9aef-2d69fd198ebc', 6000),
];

const _filed = <String, (String, Scope)>{
  '01a1540c-02e6-75fa-82c9-1392b5dd0b0e': ('Rent', Scope.household),
  '01a1540d-0dcf-74b4-9298-7089c627718a': ('Internet', Scope.household),
  '01a1540d-7471-712f-9cfd-ecb34802d92b': ('Electricity', Scope.household),
  '01a1540d-bc40-7c7f-b150-34acc3d60e69': ('Groceries', Scope.household),
  '01a15410-2888-7b27-acbb-49ffa1492b4e': ('Groceries', Scope.household),
  '01a15410-dfe6-7309-ab88-c3f82583811e': ('Groceries', Scope.household),
  '01a15411-4ce2-7d5e-ad8e-aa6f38adf327': ('Food & Outings', Scope.personal),
  '01a15411-9c30-71ea-b304-bd78b6b43ff3': ('Food & Outings', Scope.personal),
  '01a15411-eae4-7547-90af-3a5db9bdf9d9': ('Personal Care', Scope.personal),
  '01a15412-5b32-7021-9048-d795b2fe552e': ('Dates', Scope.personal),
  '01a15412-76dd-763e-adb0-29997570895f': ('Food & Outings', Scope.personal),
  '01a15413-06d1-75fb-8c96-ece56f4a71b1': ('Food & Outings', Scope.personal),
  '01a15413-4722-7502-b23a-bb9e10b7f76a': ('Food & Outings', Scope.personal),
  '01a15413-6a5f-7377-a598-7d4e9b8f75e3': ('Food & Outings', Scope.personal),
  '01a15413-a27a-79fe-8b52-fe05a0c0fc55': ('Transportation', Scope.personal),
  '01a15413-dbc7-7164-93d2-bfdb3a889906': ('Salary', Scope.personal),
  '01a15414-b6a7-7074-917f-ac5d3db17f70': ('Transportation', Scope.personal),
  '01a15414-f2f9-7ef3-811b-98e350739179': ('Learning & Tech', Scope.personal),
  '01a15417-20e1-7084-8fbe-510531f9ee6b': ('Subscriptions', Scope.personal),
  '01a159bd-7e7e-72ff-b031-526905bc4120': ('Food & Outings', Scope.personal),
  '01a159d6-fd53-73b9-a427-717febfc7c73': ('Other', Scope.other),
  '3173cb51-b6f7-4a40-8c48-9ff4425bb6d3': ('Food & Outings', Scope.personal),
  '47242e1d-6032-43a4-8ac8-5afe4b5a4d44': ('Other', Scope.other),
};

const _ruleId = '01a15560-8a6b-7538-8467-46fd729ae2fb';
final _t0 = DateTime.utc(2026, 10, 19, 12);

String key(String k) => seedId('cat:$k');

/// Writes the old ledger into [db] as an older app version left it.
Future<void> _writeOld(AppDatabase db, {bool dirty = false}) async {
  await db.delete(db.categories).go();
  await (db.delete(db.localMeta)..where((m) => m.key.equals(restructuredKey))).go();
  for (final (id, name, kind, scope, archived, deleted, icon, color, sort) in _oldCategories) {
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: Value(id),
            createdAt: Value(_t0),
            updatedAt: Value(_t0),
            deletedAt: Value(deleted ? _t0 : null),
            dirty: Value(dirty),
            name: name,
            icon: icon,
            colorIndex: color,
            kind: CategoryKind.values.byName(kind),
            scope: Value(Scope.values.byName(scope)),
            sort: Value(sort),
            archived: Value(archived),
          ),
        );
  }
  for (final (id, type, scope, category, cents) in _oldEntries) {
    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            id: Value(id),
            createdAt: Value(_t0),
            updatedAt: Value(_t0),
            dirty: Value(dirty),
            type: TxType.values.byName(type),
            scope: Scope.values.byName(scope),
            amountCents: cents,
            accountId: seedId('acct:cash'),
            categoryId: Value(category),
            occurredOn: '2026-10-19',
          ),
        );
  }
  await db
      .into(db.recurringRules)
      .insert(
        RecurringRulesCompanion.insert(
          id: const Value(_ruleId),
          createdAt: Value(_t0),
          updatedAt: Value(_t0),
          dirty: Value(dirty),
          type: TxType.expense,
          scope: Scope.personal,
          amountCents: 2000,
          accountId: seedId('acct:cash'),
          categoryId: const Value('eabe9edd-d553-5dd5-a930-dec09bb3d98a'),
          frequency: Frequency.monthly,
          anchorDate: '2026-10-19',
          nextDue: '2026-11-19',
        ),
      );
}

Future<AppDatabase> _oldLedger({bool dirty = false}) async {
  final db = AppDatabase.memory(NativeDatabase.memory());
  await db.customSelect('SELECT 1').get();
  await _writeOld(db, dirty: dirty);
  return db;
}

Future<Map<Scope, int>> _spentByScope(AppDatabase db) async {
  final out = {for (final s in Scope.values) s: 0};
  for (final t in await (db.select(
    db.transactions,
  )..where((t) => t.deletedAt.isNull() & t.type.equalsValue(TxType.expense))).get()) {
    out[t.scope] = out[t.scope]! + t.amountCents;
  }
  return out;
}

/// Live expenses whose category belongs to another scope.
Future<List<String>> _crossed(AppDatabase db) async => [
  for (final r in await db.customSelect('''
    SELECT t.id FROM transactions t JOIN categories c ON c.id = t.category_id
    WHERE t.deleted_at IS NULL AND t.type = 'expense' AND c.kind = 'expense' AND c.default_scope <> t.scope
    UNION ALL
    SELECT r.id FROM recurring_rules r JOIN categories c ON c.id = r.category_id
    WHERE r.deleted_at IS NULL AND r.type = 'expense' AND c.kind = 'expense' AND c.default_scope <> r.scope
  ''').get())
    r.read<String>('id'),
];

Future<List<Map<String, Object?>>> _dump(AppDatabase db, String table) async => [
  for (final r in await db.customSelect('SELECT * FROM $table ORDER BY id').get())
    {
      for (final e in r.data.entries)
        if (!{'dirty', 'user_id'}.contains(e.key)) e.key: e.value,
    },
];

TransactionsCompanion _spend(String category, Scope scope, {int cents = 1000}) => TransactionsCompanion.insert(
  type: TxType.expense,
  scope: scope,
  amountCents: cents,
  accountId: seedId('acct:cash'),
  categoryId: Value(category),
  occurredOn: Day.today(),
);

void main() {
  group('restructuring an old ledger', () {
    test('every entry lands where it was decided; no scope total moves but the two sent to Other', () async {
      final db = await _oldLedger();
      addTearDown(db.close);
      final before = await _spentByScope(db);
      final allBefore = (await db.select(db.transactions).get()).fold(0, (a, t) => a + t.amountCents);

      await restructureCategories(db);

      final after = await _spentByScope(db);
      // A wedding gift ($50, personal) and sunglasses for a sister ($60,
      // household) were moved to Other by hand; nothing else changes scope.
      expect(after[Scope.personal], before[Scope.personal]! - 5000);
      expect(after[Scope.household], before[Scope.household]! - 6000);
      expect(after[Scope.other], before[Scope.other]! + 11000);
      expect((await db.select(db.transactions).get()).fold(0, (a, t) => a + t.amountCents), allBefore);

      final rows = {for (final t in await db.select(db.transactions).get()) t.id: t};
      for (final MapEntry(key: id, value: (k, scope)) in _filed.entries) {
        expect(rows[id]!.categoryId, key(k), reason: '$id → $k');
        expect(rows[id]!.scope, scope, reason: '$id → $scope');
      }
      final rule = await (db.select(db.recurringRules)..where((r) => r.id.equals(_ruleId))).getSingle();
      expect(rule.categoryId, key('Subscriptions'));
      expect(await _crossed(db), isEmpty);
    });

    test('the categories are exactly the chosen ones, each in its scope; income untouched', () async {
      final db = await _oldLedger();
      addTearDown(db.close);
      await restructureCategories(db);
      final live = await (db.select(db.categories)..where((c) => c.deletedAt.isNull())).get();
      Set<String> names(Scope s) => {
        for (final c in live)
          if (c.kind == CategoryKind.expense && c.scope == s) c.name,
      };
      expect(names(Scope.personal), {
        'Transportation',
        'Dates',
        'Food & Outings',
        'Subscriptions',
        'Clothes & Accessories',
        'Learning & Tech',
        'Personal Care',
      });
      expect(names(Scope.household), {'Rent', 'Electricity', 'Utilities', 'Groceries', 'Subscriptions', 'Internet'});
      expect(names(Scope.other), {'Other'});
      expect(
        {for (final c in live.where((c) => c.kind == CategoryKind.income)) c.name},
        {
          'Salary',
          'Freelance',
          'Other income',
        },
      );
      // Every old category folded away is remembered, so entries an older
      // app version logs there later follow on after sync.
      for (final id in [
        'e73589db-46af-5539-952d-b76c25ec1280', // Outings
        '72a0e7e1-651d-5957-a539-c8a63f72b35c', // Motorcycle
        'bf4119f6-9f2c-53fc-9b50-4f19d9344e73', // the old Transportation
        '447cc364-1e09-5500-983e-353e509bc733', // Internet & phone
        'ad97644b-c223-53f9-9aef-2d69fd198ebc', // Shopping
        'cc95bb4b-80a5-5e6a-8197-40a8b383a7b1', // the old Dates
        '01a15476-6254-708e-b414-0dd0ee629714', // a household "Other"
      ]) {
        expect(await db.meta('category.merged.$id'), isNotNull, reason: id);
        expect((await (db.select(db.categories)..where((c) => c.id.equals(id))).getSingle()).deletedAt, isNotNull);
      }
    });

    test('writes are stamped just after what they replace and go out on the next sync', () async {
      final db = await _oldLedger();
      addTearDown(db.close);
      await restructureCategories(db);
      final t = await (db.select(
        db.transactions,
      )..where((t) => t.id.equals('01a15411-4ce2-7d5e-ad8e-aa6f38adf327'))).getSingle();
      expect(t.updatedAt, _t0.add(const Duration(milliseconds: 1)));
      expect(t.dirty, isTrue);
      final untouched = await (db.select(
        db.transactions,
      )..where((t) => t.id.equals('01a15413-dbc7-7164-93d2-bfdb3a889906'))).getSingle();
      expect(untouched.dirty, isFalse, reason: 'income is left alone');
    });

    test('runs once: a second run changes nothing', () async {
      final db = await _oldLedger();
      addTearDown(db.close);
      await restructureCategories(db);
      final tx = await _dump(db, 'transactions');
      final cats = await _dump(db, 'categories');
      await restructureCategories(db);
      expect(await _dump(db, 'transactions'), tx);
      expect(await _dump(db, 'categories'), cats);
    });

    test('two devices restructuring the same ledger write identical rows', () async {
      final a = await _oldLedger();
      final b = await _oldLedger();
      addTearDown(a.close);
      addTearDown(b.close);
      await restructureCategories(a);
      await restructureCategories(b);
      for (final table in ['categories', 'transactions', 'recurring_rules', 'budgets']) {
        expect(await _dump(a, table), await _dump(b, table), reason: table);
      }
    });

    test('a device that restructures late never undoes what you changed since', () async {
      final remote = FakeRemote();
      final a = await _oldLedger(dirty: true);
      final b = await _oldLedger();
      addTearDown(a.close);
      addTearDown(b.close);
      await SyncCore(a, remote).run();
      // b is in step with a, then goes quiet.
      for (final t in SyncCore.tables) {
        await b.setMeta('cursor:$t', DateTime.utc(2031).toIso8601String());
      }

      await restructureCategories(a);
      await SyncCore(a, remote).run();
      // You re-file the haircut, and rename a category, on a.
      const haircut = '01a15411-eae4-7547-90af-3a5db9bdf9d9';
      await Ledger(
        a,
      ).updateTransaction(haircut, TransactionsCompanion(categoryId: Value(key('Clothes & Accessories'))));
      final lt = await (a.select(a.categories)..where((c) => c.id.equals(key('Learning & Tech')))).getSingle();
      await Ledger(a).upsertCategory(lt.toCompanion(true).copyWith(name: const Value('Learning & Gadgets')));
      await SyncCore(a, remote).run();

      // b updates later, restructuring its stale copy, then syncs.
      await restructureCategories(b);
      for (final t in SyncCore.tables) {
        await (b.delete(b.localMeta)..where((m) => m.key.equals('cursor:$t'))).go();
      }
      await SyncCore(b, remote).run();
      await SyncCore(a, remote).run();

      for (final db in [a, b]) {
        final t = await (db.select(db.transactions)..where((t) => t.id.equals(haircut))).getSingle();
        expect(t.categoryId, key('Clothes & Accessories'));
        final c = await (db.select(db.categories)..where((c) => c.id.equals(key('Learning & Tech')))).getSingle();
        expect(c.name, 'Learning & Gadgets');
        expect(await _crossed(db), isEmpty);
      }
      for (final table in ['categories', 'transactions', 'recurring_rules']) {
        expect(await _dump(a, table), await _dump(b, table), reason: table);
      }
    });

    test('the upgrade itself restructures, and a ledger it cannot read still opens', () async {
      final dir = await Directory.systemTemp.createTemp('juno_v7');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/juno.sqlite');
      final v6 = AppDatabase.memory(NativeDatabase(file));
      await v6.customSelect('SELECT 1').get();
      await _writeOld(v6);
      await v6.customStatement('PRAGMA user_version = 6');
      await v6.close();

      final db = AppDatabase.memory(NativeDatabase(file));
      addTearDown(db.close);
      final t = await (db.select(
        db.transactions,
      )..where((t) => t.id.equals('01a1540d-7471-712f-9cfd-ecb34802d92b'))).getSingle();
      expect(t.categoryId, key('Electricity'));
      expect(await db.meta(restructuredKey), '1');
      expect(await _crossed(db), isEmpty);
    });

    test('a new install is born scoped: nothing to restructure', () async {
      final db = AppDatabase.memory(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();
      expect(await db.meta(restructuredKey), '1');
      final cats = await db.select(db.categories).get();
      expect(cats.map((c) => c.id).toSet(), {for (final s in starterCategories) s.id});
    });
  });

  group('older app versions after the move', () {
    test('an entry filed across scopes keeps its scope and moves category on sync', () async {
      final remote = FakeRemote();
      final db = AppDatabase.memory(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();
      // As an old phone would push them: the category only a hint.
      Future<String> old(String category, Scope scope) async {
        final id = newId();
        await db.into(db.transactions).insert(_spend(category, scope).copyWith(id: Value(id)));
        return id;
      }

      final rent = await old(key('Rent'), Scope.personal);
      final subs = await old(key('Subscriptions'), Scope.household);
      final food = await old(key('Food & Outings'), Scope.other);
      final ok = await old(key('Dates'), Scope.personal);
      final before = await _spentByScope(db);
      await SyncCore(db, remote).run();

      Future<Transaction> row(String id) => (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();
      expect((await row(rent)).categoryId, isNull, reason: 'no personal Rent: uncategorised, still personal');
      expect((await row(subs)).categoryId, key('household:Subscriptions'), reason: 'same name in its scope');
      expect((await row(food)).categoryId, key('Other'), reason: 'the scope’s catch-all');
      expect((await row(ok)).categoryId, key('Dates'));
      expect(await _spentByScope(db), before);
      expect(await _crossed(db), isEmpty);
      // And the fix went up with the same sync.
      expect(remote.tables['transactions']![subs]!['category_id'], key('household:Subscriptions'));
    });
  });

  group('every write keeps spending in its category’s scope', () {
    late AppDatabase db;
    late Ledger l;
    setUp(() async {
      db = AppDatabase.memory(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
      l = Ledger(db);
    });
    tearDown(() => db.close());

    Future<Transaction> row(String id) => (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();

    test('adding: the category decides the scope', () async {
      expect((await row(await l.addTransaction(_spend(key('Rent'), Scope.personal)))).scope, Scope.household);
      expect((await row(await l.addTransaction(_spend(key('Dates'), Scope.household)))).scope, Scope.personal);
      // Income keeps the scope it is given.
      final salary = await l.addTransaction(
        _spend(key('Salary'), Scope.household).copyWith(type: const Value(TxType.income)),
      );
      expect((await row(salary)).scope, Scope.household);
    });

    test('editing: a new category brings its scope; a new scope alone leaves the category behind', () async {
      final id = await l.addTransaction(_spend(key('Dates'), Scope.personal));
      await l.updateTransaction(id, TransactionsCompanion(categoryId: Value(key('Groceries'))));
      expect((await row(id)).scope, Scope.household);
      await l.updateTransaction(id, const TransactionsCompanion(scope: Value(Scope.personal)));
      final t = await row(id);
      expect(t.scope, Scope.personal);
      expect(t.categoryId, isNull);
      // The entry sheet sends every field back: an unchanged category with
      // a changed scope is a scope change.
      await l.updateTransaction(id, TransactionsCompanion(categoryId: Value(key('Dates'))));
      await l.updateTransaction(
        id,
        TransactionsCompanion(categoryId: Value(key('Dates')), scope: const Value(Scope.household)),
      );
      expect((await row(id)).categoryId, isNull);
      expect(await _crossed(db), isEmpty);
    });

    test('splitting: each part takes its category’s scope; amounts still add up', () async {
      final id = await l.addTransaction(_spend(key('Groceries'), Scope.household, cents: 10000));
      final parts = await l.splitTransaction(id, [
        (key('Groceries'), Scope.household, 6000),
        (key('Food & Outings'), Scope.household, 4000),
      ]);
      expect((await row(parts.last)).scope, Scope.personal);
      expect((await db.select(db.transactions).get()).fold(0, (a, t) => a + t.amountCents), 10000);
    });

    test('importing, recurring bills and budgets follow too', () async {
      await l.commitImport('x.csv', [_spend(key('Rent'), Scope.personal)]);
      expect((await db.select(db.transactions).get()).single.scope, Scope.household);
      final rule = await l.upsertRecurring(
        RecurringRulesCompanion.insert(
          type: TxType.expense,
          scope: Scope.personal,
          amountCents: 999,
          accountId: seedId('acct:cash'),
          categoryId: Value(key('household:Subscriptions')),
          frequency: Frequency.monthly,
          anchorDate: Day.today(),
          nextDue: Day.today(),
        ),
      );
      expect(
        (await (db.select(db.recurringRules)..where((r) => r.id.equals(rule))).getSingle()).scope,
        Scope.household,
      );
      final budget = await l.upsertBudget(
        BudgetsCompanion.insert(categoryId: Value(key('Dates')), scope: const Value(Scope.household), limitCents: 1),
      );
      expect((await (db.select(db.budgets)..where((b) => b.id.equals(budget))).getSingle()).scope, Scope.personal);
      expect(await _crossed(db), isEmpty);
    });

    test('moving a category to another scope moves everything filed in it', () async {
      final id = await l.addTransaction(_spend(key('Learning & Tech'), Scope.personal));
      await l.upsertRecurring(
        RecurringRulesCompanion.insert(
          type: TxType.expense,
          scope: Scope.personal,
          amountCents: 999,
          accountId: seedId('acct:cash'),
          categoryId: Value(key('Learning & Tech')),
          frequency: Frequency.monthly,
          anchorDate: Day.today(),
          nextDue: Day.today(),
        ),
      );
      final lt = await (db.select(db.categories)..where((c) => c.id.equals(key('Learning & Tech')))).getSingle();
      await l.upsertCategory(lt.toCompanion(true).copyWith(scope: const Value(Scope.household)));
      expect((await row(id)).scope, Scope.household);
      expect((await row(id)).dirty, isTrue);
      expect(await _crossed(db), isEmpty);
      expect(await l.watchHistory(id).first, isNotEmpty, reason: 'the move can be seen and rolled back');
    });
  });

  group('two scopes, one name', () {
    late List<Category> cats;
    setUp(() async {
      final db = AppDatabase.memory(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
      cats = await db.select(db.categories).get();
      await db.close();
    });

    test('quick add: the scope asked for, else the one on screen, picks', () {
      final accounts = <Account>[];
      ResolvedEntry r(String q) => resolveQuickAdd(QuickAdd.parse(Uri.parse('juno://add?$q'))!, cats, accounts);
      expect(r('amount=10&category=subscriptions&scope=household').category!.id, key('household:Subscriptions'));
      expect(r('amount=10&category=subscriptions&scope=personal').category!.id, key('Subscriptions'));
      expect(
        resolveQuickAdd(
          QuickAdd.parse(Uri.parse('juno://add?amount=10&category=subscriptions'))!,
          cats,
          accounts,
          prefer: Scope.household,
        ).scope,
        Scope.household,
      );
      // A category with one home decides the scope, whatever was asked.
      final rent = r('amount=600&category=rent&scope=personal');
      expect(rent.category!.id, key('Rent'));
      expect(rent.scope, Scope.household);
      expect(r('amount=5&note=x&scope=other').scope, Scope.other);
    });

    test('CSV import matches names in the scope being imported into', () {
      final t = CsvTable.parse('Date,Description,Amount,Category\n2026-10-01,Shahid,-9.99,Subscriptions\n');
      final m = ColumnMapping.guess(t);
      List<ImportRow> rows(Scope s) =>
          buildRows(table: t, mapping: m, existingHashes: {}, memory: {}, categories: cats, scope: s);
      expect(rows(Scope.household).single.categoryId, key('household:Subscriptions'));
      expect(rows(Scope.personal).single.categoryId, key('Subscriptions'));
    });

    test('labels say the scope only where the name is shared', () {
      final labels = categoryLabels(cats);
      expect(labels[key('Subscriptions')], 'Subscriptions · Personal');
      expect(labels[key('household:Subscriptions')], 'Subscriptions · Household');
      expect(labels[key('Rent')], 'Rent');
      expect(labels[key('Salary')], 'Salary');
    });
  });

  testWidgets('settings: categories sit under their scope, Other on its own', (tester) async {
    // Tall enough to lay out every section at once.
    final h = await boot(tester, demo: false, size: const Size(393, 2200));
    await h.go('/settings/categories');
    double y(String text) => tester.getTopLeft(find.text(text).first).dy;
    expect(y('PERSONAL'), lessThan(y('Dates')));
    expect(y('Dates'), lessThan(y('HOUSEHOLD')));
    expect(y('HOUSEHOLD'), lessThan(y('Rent')));
    expect(y('Rent'), lessThan(y('OTHER')));
    expect(y('OTHER'), lessThan(tester.getTopLeft(find.text('Other').last).dy));
    expect(find.text('Subscriptions'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await h.dispose();
  });

  testWidgets('entry sheet: the grid is the scope’s; switching scope drops a category from another', (tester) async {
    final h = await boot(tester, demo: false);
    unawaited(showEntrySheet(h.ctx));
    await h.settle();
    expect(find.text('Dates'), findsOneWidget);
    expect(find.text('Rent'), findsNothing);
    await tester.tap(find.text('Dates'));
    await h.settle(1);
    await tester.tap(find.descendant(of: find.byType(ScopeToggle), matching: find.text('Household')));
    await h.settle(1);
    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('Dates'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '25');
    await h.settle(1);
    await tester.tap(find.textContaining(r'Log $25.00').first);
    await h.settle();
    final t = (await tester.runAsync(() => h.ledger.transactions(const TxQuery())))!.single;
    expect(t.scope, Scope.household);
    expect(t.categoryId, isNull, reason: 'Dates was personal; it did not come along');
    expect(tester.takeException(), isNull);
    await h.dispose();
  });
}
