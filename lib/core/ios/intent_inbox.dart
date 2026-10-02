import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:home_widget/home_widget.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/deeplink/quick_add.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/smart/entry_parser.dart';

/// Entries logged on iOS without opening Juno — by the "Log expense" App
/// Intent from Siri, Shortcuts, Back Tap, the Action Button or a widget
/// button. The intent appends to a JSON inbox in the shared App Group; Juno
/// imports it on the next launch/resume. Contract (ios/Runner/JunoIntents.swift):
///
/// ```json
/// [{"id": "UUID", "amount": 12.5, "currency": "LBP", "category": "Groceries",
///   "scope": "household", "type": "expense", "note": "Spinneys",
///   "text": "12 coffee kalei", "at": "2026-10-01T09:30:00"}]
/// ```
class InboxItem {
  const InboxItem({
    required this.id,
    this.amount,
    this.currency,
    this.category,
    this.scope,
    this.type,
    this.note,
    this.text,
    this.at,
  });

  factory InboxItem.fromJson(Map<String, dynamic> j) => InboxItem(
    id: j['id'] as String,
    amount: (j['amount'] as num?)?.toDouble(),
    currency: (j['currency'] as String?)?.toUpperCase(),
    category: j['category'] as String?,
    scope: j['scope'] as String?,
    type: j['type'] as String?,
    note: j['note'] as String?,
    text: j['text'] as String?,
    at: j['at'] == null ? null : DateTime.tryParse(j['at'] as String),
  );

  final String id;
  final double? amount;
  final String? currency;
  final String? category;
  final String? scope;
  final String? type;
  final String? note;
  final String? text;
  final DateTime? at;
}

List<InboxItem> parseInbox(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final list = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in list)
        if (e is Map<String, dynamic> && e['id'] is String) InboxItem.fromJson(e),
    ];
  } on FormatException {
    return const [];
  }
}

/// Turns an inbox item into a row, or null when it can't be one (no amount).
/// Same matching as `juno://add` links. When the currency asked for has no
/// account, the amount is converted into the chosen account's currency at
/// today's rate rather than misread as that currency.
Future<TransactionsCompanion?> inboxToEntry(
  InboxItem item, {
  required List<Category> categories,
  required List<Account> accounts,
  required Map<String, double> rates,
  Map<String, String> memory = const {},
}) async {
  var q = QuickAdd(
    amountCents: item.amount == null ? null : (item.amount! * 100).round().abs(),
    currency: item.currency,
    category: item.category,
    scope: switch (item.scope?.toLowerCase()) {
      'household' => Scope.household,
      'personal' => Scope.personal,
      _ => null,
    },
    type: switch (item.type?.toLowerCase()) {
      'income' => TxType.income,
      'expense' => TxType.expense,
      _ => null,
    },
    note: item.note,
    day: item.at == null ? null : Day.of(item.at!.isUtc ? item.at!.toLocal() : item.at!),
  );
  if (item.text != null && item.text!.trim().isNotEmpty) {
    final e = parseEntry(
      item.text!,
      categories: categories,
      memory: memory,
      hasLbpAccount: accounts.any((a) => a.currency == 'LBP'),
      // "yesterday" means the day before it was said, not before Juno opened.
      now: item.at == null ? null : (item.at!.isUtc ? item.at!.toLocal() : item.at!),
    );
    q = QuickAdd(
      amountCents: q.amountCents ?? e.amountCents,
      currency: q.currency ?? e.currency,
      category: q.category ?? categories.where((c) => c.id == e.categoryId).firstOrNull?.name,
      scope: q.scope ?? e.scope,
      type: q.type ?? e.type,
      note: q.note ?? (e.note.isEmpty ? null : e.note),
      day: e.day ?? q.day,
    );
  }
  final cents = q.amountCents;
  if (cents == null || cents <= 0) return null;
  final r = resolveQuickAdd(q, categories, accounts);
  final account = r.account;
  if (account == null) return null;

  var amount = cents;
  var note = q.note ?? '';
  if (r.currencyMismatch) {
    final converted = Fx.tryToUsd(cents, q.currency!, rates) == null
        ? null
        : Fx.convert(cents, q.currency!, account.currency, rates);
    if (converted == null) return null;
    amount = converted;
    final original = Fx.format(cents, q.currency!);
    note = note.isEmpty ? original : '$note ($original)';
  }
  return TransactionsCompanion.insert(
    // The intent's id: importing the same inbox twice is a no-op.
    id: Value(item.id.toLowerCase()),
    type: r.type,
    scope: r.scope,
    amountCents: amount,
    accountId: account.id,
    categoryId: Value(r.category?.id),
    occurredOn: q.day ?? Day.today(),
    note: Value(note),
    tags: Value(EntryTags.store(['quick'])),
  );
}

abstract final class IntentInbox {
  static const appGroup = 'group.com.kronbii.juno';
  static const inboxKey = 'juno.inbox';
  static const catalogKey = 'juno.catalog';

  static bool get supported => !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST') && Platform.isIOS;

  /// Imports pending entries. Returns how many were added.
  static Future<int> drain(AppDatabase db) async {
    if (!supported) return 0;
    await HomeWidget.setAppGroupId(appGroup);
    final items = parseInbox(await HomeWidget.getWidgetData<String>(inboxKey));
    if (items.isEmpty) return 0;
    final ledger = Ledger(db);
    final categories = await (db.select(db.categories)..where((c) => c.deletedAt.isNull())).get();
    final accounts = await (db.select(
      db.accounts,
    )..where((a) => a.deletedAt.isNull() & a.archived.equals(false))).get();
    final rates = {'USD': 1.0, ...await ledger.rates()};
    final memory = await ledger.merchantCategoryMemory();
    var added = 0;
    final handled = <String>{};
    for (final item in items) {
      final exists = await (db.select(
        db.transactions,
      )..where((t) => t.id.equals(item.id.toLowerCase()))).getSingleOrNull();
      if (exists == null) {
        final row = await inboxToEntry(item, categories: categories, accounts: accounts, rates: rates, memory: memory);
        if (row != null) {
          await ledger.addTransaction(row);
          added++;
        }
      }
      handled.add(item.id);
    }
    // Re-read before writing back: the intent may have appended meanwhile.
    final now = parseInbox(await HomeWidget.getWidgetData<String>(inboxKey));
    final remaining = [
      for (final i in now)
        if (!handled.contains(i.id)) i,
    ];
    await HomeWidget.saveWidgetData<String>(
      inboxKey,
      remaining.isEmpty ? null : jsonEncode([for (final i in remaining) _toJson(i)]),
    );
    return added;
  }

  /// Publishes names the App Intent can offer (Siri's category picker).
  static Future<void> publishCatalog(AppDatabase db) async {
    if (!supported) return;
    final categories =
        await (db.select(db.categories)
              ..where((c) => c.deletedAt.isNull() & c.archived.equals(false))
              ..orderBy([(c) => OrderingTerm(expression: c.sort)]))
            .get();
    final accounts = await (db.select(
      db.accounts,
    )..where((a) => a.deletedAt.isNull() & a.archived.equals(false))).get();
    await HomeWidget.setAppGroupId(appGroup);
    await HomeWidget.saveWidgetData<String>(
      catalogKey,
      jsonEncode({
        'categories': [
          for (final c in categories) {'name': c.name, 'kind': c.kind.name, 'scope': c.defaultScope.name},
        ],
        'currencies': {for (final a in accounts) a.currency}.toList(),
      }),
    );
  }

  static Map<String, dynamic> _toJson(InboxItem i) => {
    'id': i.id,
    'amount': ?i.amount,
    'currency': ?i.currency,
    'category': ?i.category,
    'scope': ?i.scope,
    'type': ?i.type,
    'note': ?i.note,
    'text': ?i.text,
    if (i.at != null) 'at': i.at!.toIso8601String(),
  };
}
