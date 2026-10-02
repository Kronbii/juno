import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:intl/intl.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/deeplink/quick_add.dart' show fuzzyMatch;
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';

/// A parsed file: header row (or generated names) and data rows.
class CsvTable {
  const CsvTable(this.headers, this.rows);

  final List<String> headers;
  final List<List<String>> rows;

  static CsvTable parse(String raw) {
    final text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    return fromRows([
      for (final r in Csv().decode(text)) [for (final f in r) f.toString()],
    ]);
  }

  /// Sheet names in an .xlsx workbook, in order.
  static List<String> xlsxSheets(Uint8List bytes) => Excel.decodeBytes(bytes).tables.keys.toList();

  /// Reads one sheet (default: the first with data). Real date cells become
  /// `yyyy-MM-dd`, so the date-format detector sees them unambiguously.
  static CsvTable fromXlsx(Uint8List bytes, {String? sheet}) {
    final book = Excel.decodeBytes(bytes);
    final sheets = book.tables;
    final chosen = sheets[sheet] ?? sheets.values.where((s) => s.maxRows > 1).firstOrNull ?? sheets.values.firstOrNull;
    if (chosen == null) return const CsvTable([], []);
    String cell(Data? d) => switch (d?.value) {
      null => '',
      DateCellValue(:final year, :final month, :final day) => Day.of(DateTime(year, month, day)),
      DateTimeCellValue(:final year, :final month, :final day) => Day.of(DateTime(year, month, day)),
      FormulaCellValue() => '',
      final v => v.toString(),
    };
    return fromRows([
      for (final r in chosen.rows) [for (final d in r) cell(d)],
    ]);
  }

  // ignore: prefer_constructors_over_static_methods, mirrors parse/fromXlsx.
  static CsvTable fromRows(List<List<String>> raw) {
    final all = [
      for (final r in raw) [for (final f in r) f.trim()],
    ].where((r) => r.any((f) => f.isNotEmpty)).toList();
    if (all.isEmpty) return const CsvTable([], []);

    final width = all.fold(0, (m, r) => r.length > m ? r.length : m);
    List<String> pad(List<String> r) => [...r, for (var i = r.length; i < width; i++) ''];

    // A header row is one where no cell parses as an amount or a date.
    final first = all.first;
    final looksLikeHeader = first.every(
      (f) => f.isEmpty || (Money.parse(f) == null && DateFormats.detect([f]) == null),
    );
    if (looksLikeHeader) {
      return CsvTable(pad(first), [for (final r in all.skip(1)) pad(r)]);
    }
    return CsvTable([for (var i = 0; i < width; i++) 'Column ${i + 1}'], [for (final r in all) pad(r)]);
  }
}

/// How amounts are laid out in the file.
enum AmountMode {
  /// One column; negative = money out (most bank exports).
  signedNegativeOut,

  /// One column; positive = money out (most credit-card exports).
  signedPositiveOut,

  /// Separate debit (out) and credit (in) columns.
  debitCredit,
}

class ColumnMapping {
  const ColumnMapping({
    this.date,
    this.description,
    this.amount,
    this.debit,
    this.credit,
    this.category,
    this.mode = AmountMode.signedNegativeOut,
    this.dateFormat,
  });

  /// Guesses columns from header names.
  factory ColumnMapping.guess(CsvTable t) {
    int? find(List<String> keys, {Set<int> not = const {}}) {
      for (final k in keys) {
        for (var i = 0; i < t.headers.length; i++) {
          if (not.contains(i)) continue;
          final h = t.headers[i].toLowerCase();
          if (h == k || h.contains(k)) return i;
        }
      }
      return null;
    }

    final date =
        find(['transaction date', 'posting date', 'posted', 'date']) ??
        _firstColumnWhere(t, (v) => DateFormats.detect([v]) != null);
    final desc = find(['description', 'merchant', 'payee', 'details', 'narrative', 'memo', 'name'], not: {?date});
    final debit = find(['debit', 'withdrawal', 'money out', 'paid out'], not: {?date, ?desc});
    final credit = find(['credit', 'deposit', 'money in', 'paid in'], not: {?date, ?desc, ?debit});
    // A debit/credit pair wins over a guessed numeric column — the debit
    // column is itself numeric and would otherwise be taken as "amount".
    final named = find(['amount', 'value', 'sum'], not: {?date, ?desc, ?debit, ?credit});
    final amount =
        named ??
        (debit != null && credit != null
            ? null
            : _firstColumnWhere(t, (v) => Money.parse(v) != null && DateFormats.detect([v]) == null, not: {?date}));

    final category = find(['category', 'categories', 'tag'], not: {?date, ?desc, ?debit, ?credit, ?amount});
    final useDebitCredit = debit != null && credit != null && amount == null;
    final mapping = ColumnMapping(
      date: date,
      description: desc ?? _firstColumnWhere(t, (v) => Money.parse(v) == null, not: {?date}),
      amount: useDebitCredit ? null : amount,
      debit: useDebitCredit ? debit : null,
      credit: useDebitCredit ? credit : null,
      category: category,
      mode: useDebitCredit ? AmountMode.debitCredit : AmountMode.signedNegativeOut,
    );
    return mapping.copyWith(dateFormat: date == null ? null : DateFormats.detect(t.rows.map((r) => r[date])));
  }

  final int? date;
  final int? description;
  final int? amount;
  final int? debit;
  final int? credit;

  /// A column naming the category (Notion/Excel trackers). Values are
  /// fuzzy-matched to your categories and win over suggestions.
  final int? category;
  final AmountMode mode;
  final String? dateFormat;

  bool get isComplete =>
      date != null &&
      dateFormat != null &&
      (mode == AmountMode.debitCredit ? (debit != null || credit != null) : amount != null);

  ColumnMapping copyWith({
    int? date,
    int? description,
    int? amount,
    int? debit,
    int? credit,
    int? category,
    AmountMode? mode,
    String? dateFormat,
  }) => ColumnMapping(
    date: date ?? this.date,
    description: description ?? this.description,
    amount: amount ?? this.amount,
    debit: debit ?? this.debit,
    credit: credit ?? this.credit,
    category: category ?? this.category,
    mode: mode ?? this.mode,
    dateFormat: dateFormat ?? this.dateFormat,
  );

  /// Sets one column, where null *clears* it ([copyWith] can't express
  /// "unset" — choosing "—" for Debit must actually stop reading Debit).
  ColumnMapping withColumn(String field, int? v) => ColumnMapping(
    date: field == 'date' ? v : date,
    description: field == 'description' ? v : description,
    amount: field == 'amount' ? v : amount,
    debit: field == 'debit' ? v : debit,
    credit: field == 'credit' ? v : credit,
    category: field == 'category' ? v : category,
    mode: mode,
    dateFormat: dateFormat,
  );

  static int? _firstColumnWhere(CsvTable t, bool Function(String) test, {Set<int> not = const {}}) {
    if (t.rows.isEmpty) return null;
    final sample = t.rows.take(10).toList();
    for (var i = 0; i < t.headers.length; i++) {
      if (not.contains(i)) continue;
      final vals = sample.map((r) => r[i]).where((v) => v.isNotEmpty).toList();
      if (vals.isNotEmpty && vals.every(test)) return i;
    }
    return null;
  }
}

/// Date formats seen in bank exports, most specific first.
abstract final class DateFormats {
  static const candidates = [
    'yyyy-MM-dd',
    'yyyy/MM/dd',
    // Day-first before month-first: Lebanese and most non-US banks write
    // dd/MM. Ambiguous files are flagged in the UI (isAmbiguous).
    'dd/MM/yyyy',
    'MM/dd/yyyy',
    'd/M/yyyy',
    'M/d/yyyy',
    'dd.MM.yyyy',
    'dd-MM-yyyy',
    'MM-dd-yyyy',
    'dd/MM/yy',
    'MM/dd/yy',
    'd MMM yyyy',
    'dd MMM yyyy',
    'MMM d, yyyy',
    'MMMM d, yyyy',
    'd MMMM yyyy',
    'MMM d yyyy',
    'yyyyMMdd',
  ];

  static DateTime? tryParse(String value, String format) {
    final v = value.trim();
    // Some exports append a time; the day is all we keep.
    final head = v.split(RegExp(r'[ T](?=\d{1,2}:)')).first;
    try {
      final d = DateFormat(format, 'en_US').parseStrict(head);
      if (d.year < 1970 || d.year > 2100) return null;
      return d;
    } on FormatException {
      return null;
    }
  }

  /// The first format that parses every non-empty sample value. US vs EU
  /// order is settled by the samples themselves: a 13+ in the first field
  /// rules out month-first.
  static String? detect(Iterable<String> values) {
    // Every row, not a sample: one "25/04" late in the file settles the order.
    final sample = values.where((v) => v.trim().isNotEmpty).toList();
    if (sample.isEmpty) return null;
    for (final f in candidates) {
      if (sample.every((v) => tryParse(v, f) != null)) return f;
    }
    return null;
  }

  static const _swaps = {
    'dd/MM/yyyy': 'MM/dd/yyyy',
    'MM/dd/yyyy': 'dd/MM/yyyy',
    'd/M/yyyy': 'M/d/yyyy',
    'M/d/yyyy': 'd/M/yyyy',
    'dd-MM-yyyy': 'MM-dd-yyyy',
    'MM-dd-yyyy': 'dd-MM-yyyy',
    'dd/MM/yy': 'MM/dd/yy',
    'MM/dd/yy': 'dd/MM/yy',
  };

  /// True when [values] read just as well with day and month swapped — the
  /// UI then asks the user to confirm the order.
  static bool isAmbiguous(Iterable<String> values, String format) {
    final swap = _swaps[format];
    if (swap == null) return false;
    final v = values.where((x) => x.trim().isNotEmpty).toList();
    return v.isNotEmpty && v.every((x) => tryParse(x, swap) != null);
  }
}

/// A row ready for review.
class ImportRow {
  ImportRow({
    required this.index,
    required this.day,
    required this.description,
    required this.cents,
    required this.hash,
    this.categoryId,
    this.duplicate = false,
    this.error,
  });

  final int index;
  final String? day;
  final String description;

  /// Signed: negative = money out.
  final int? cents;
  final String hash;
  String? categoryId;
  bool duplicate;

  /// The category came from the AI and hasn't been confirmed by a person.
  bool aiSuggested = false;

  /// Whether the row will be imported. Duplicates and errors start off.
  late bool include = error == null && !duplicate;
  final String? error;

  TxType get type => (cents ?? 0) < 0 ? TxType.expense : TxType.income;
}

/// Stable fingerprint for a bank row. The occurrence count makes two genuine
/// identical rows on one day (two $4.50 coffees) distinct, while re-importing
/// the same file reproduces the same hashes.
String dedupeHash(String day, int cents, String description, int occurrence, {String account = ''}) {
  final norm = description.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  return sha1.convert(utf8.encode('$account|$day|$cents|$norm|$occurrence')).toString().substring(0, 20);
}

/// Built-in keyword → category-name hints for first-time imports, before
/// Juno has learned anything from your own history.
const keywordHints = <String, String>{
  'uber eats': 'Dining',
  'deliveroo': 'Dining',
  'doordash': 'Dining',
  'talabat': 'Dining',
  'toters': 'Dining',
  'restaurant': 'Dining',
  'pizza': 'Dining',
  'burger': 'Dining',
  'mcdonald': 'Dining',
  'kfc': 'Dining',
  'starbucks': 'Coffee',
  'coffee': 'Coffee',
  'cafe': 'Coffee',
  'uber': 'Transport',
  'lyft': 'Transport',
  'bolt': 'Transport',
  'taxi': 'Transport',
  'parking': 'Transport',
  'shell': 'Fuel',
  'total': 'Fuel',
  'fuel': 'Fuel',
  'gas station': 'Fuel',
  'netflix': 'Subscriptions',
  'spotify': 'Subscriptions',
  'apple.com': 'Subscriptions',
  'icloud': 'Subscriptions',
  'youtube': 'Subscriptions',
  'disney': 'Subscriptions',
  'openai': 'Subscriptions',
  'anthropic': 'Subscriptions',
  'github': 'Subscriptions',
  'amazon': 'Shopping',
  'aliexpress': 'Shopping',
  'shein': 'Shopping',
  'ikea': 'Household supplies',
  'pharmacy': 'Health',
  'clinic': 'Health',
  'hospital': 'Health',
  'gym': 'Fitness',
  'supermarket': 'Groceries',
  'grocery': 'Groceries',
  'market': 'Groceries',
  'carrefour': 'Groceries',
  'spinneys': 'Groceries',
  'walmart': 'Groceries',
  'costco': 'Groceries',
  'electric': 'Utilities',
  'water': 'Utilities',
  'internet': 'Internet & phone',
  'mobile': 'Internet & phone',
  'airline': 'Travel',
  'airbnb': 'Travel',
  'booking.com': 'Travel',
  'hotel': 'Travel',
  'rent': 'Rent',
  'salary': 'Salary',
  'payroll': 'Salary',
  'refund': 'Refunds',
};

/// Builds review rows from a table and a mapping.
List<ImportRow> buildRows({
  required CsvTable table,
  required ColumnMapping mapping,
  required Set<String> existingHashes,
  required Map<String, String> memory,
  required List<Category> categories,
  String accountId = '',
}) {
  final byName = {for (final k in categories) k.name.toLowerCase(): k};
  final seen = <String, int>{};
  final out = <ImportRow>[];

  for (var i = 0; i < table.rows.length; i++) {
    final r = table.rows[i];
    final desc = mapping.description == null ? '' : r[mapping.description!];
    final date = mapping.date == null || mapping.dateFormat == null
        ? null
        : DateFormats.tryParse(r[mapping.date!], mapping.dateFormat!);

    int? cents;
    switch (mapping.mode) {
      case AmountMode.signedNegativeOut:
        cents = mapping.amount == null ? null : Money.parse(r[mapping.amount!]);
      case AmountMode.signedPositiveOut:
        final v = mapping.amount == null ? null : Money.parse(r[mapping.amount!]);
        cents = v == null ? null : -v;
      case AmountMode.debitCredit:
        final d = mapping.debit == null ? null : Money.parse(r[mapping.debit!]);
        final c = mapping.credit == null ? null : Money.parse(r[mapping.credit!]);
        if ((d ?? 0) != 0) {
          cents = -d!.abs();
        } else if ((c ?? 0) != 0) {
          cents = c!.abs();
        }
    }

    String? error;
    if (date == null) {
      error = 'Unreadable date';
    } else if (cents == null || cents == 0) {
      error = 'No amount';
    }

    final day = date == null ? null : Day.of(date);
    final baseKey = '$day|$cents|${desc.toLowerCase().trim()}';
    final occurrence = seen[baseKey] = (seen[baseKey] ?? 0) + 1;
    final hash = dedupeHash(day ?? '', cents ?? 0, desc, occurrence, account: accountId);

    final row = ImportRow(
      index: i,
      day: day,
      description: desc,
      cents: cents,
      hash: hash,
      duplicate: existingHashes.contains(hash),
      error: error,
    );
    final named = mapping.category == null ? null : r[mapping.category!];
    final kind = row.type == TxType.income ? CategoryKind.income : CategoryKind.expense;
    row.categoryId =
        (named == null || named.isEmpty
            ? null
            : fuzzyMatch(named, categories.where((c) => c.kind == kind), (c) => c.name)?.id) ??
        suggestCategory(desc, row.type, memory, byName);
    out.add(row);
  }
  return out;
}

/// Learned history first (exact, then contained), then keyword hints.
String? suggestCategory(
  String description,
  TxType type,
  Map<String, String> memory,
  Map<String, Category> byName,
) {
  final d = description.toLowerCase().trim();
  if (d.isEmpty) return null;
  final wantKind = type == TxType.income ? CategoryKind.income : CategoryKind.expense;
  bool ok(String? id) => id != null && byName.values.any((k) => k.id == id && k.kind == wantKind);

  final exact = memory[d];
  if (ok(exact)) return exact;
  String? best;
  var bestLen = 0;
  for (final e in memory.entries) {
    if (e.key.length >= 4 && e.key.length > bestLen && d.contains(e.key) && ok(e.value)) {
      best = e.value;
      bestLen = e.key.length;
    }
  }
  if (best != null) return best;

  // Longest keyword wins so "uber eats" beats "uber".
  final keys = keywordHints.keys.where(d.contains).toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final k in keys) {
    final cat = byName[keywordHints[k]!.toLowerCase()];
    if (cat != null && cat.kind == wantKind) return cat.id;
  }
  return null;
}

/// Serialises transactions for export.
String exportCsv(
  List<Transaction> txs,
  Map<String, Category> cats,
  Map<String, Account> accounts,
) {
  final rows = <List<Object?>>[
    [
      'date',
      'type',
      'amount',
      'currency',
      'amount_usd',
      'scope',
      'category',
      'account',
      'to_account',
      'note',
      'merchant',
      'tags',
    ],
    for (final t in txs)
      [
        t.occurredOn,
        t.type.name,
        (t.type == TxType.expense ? -t.amountCents : t.amountCents) / 100,
        t.currency,
        (t.type == TxType.expense ? -t.usd : t.usd) / 100,
        t.scope.name,
        cats[t.categoryId]?.name ?? '',
        accounts[t.accountId]?.name ?? '',
        accounts[t.toAccountId]?.name ?? '',
        t.note,
        t.merchant,
        EntryTags.parse(t.tags).join(' '),
      ],
  ];
  return Csv(lineDelimiter: '\n').encode(rows);
}

/// Applies AI suggestions (description → category name) to rows that have
/// no category yet, matching the category's kind to money in or out. Rows a
/// person already categorised are left alone. Returns how many were placed.
int applyCategorySuggestions(List<ImportRow> rows, Map<String, String> names, List<Category> categories) {
  var placed = 0;
  for (final r in rows) {
    if (r.categoryId != null) continue;
    final name = names[r.description.trim()];
    if (name == null) continue;
    final kind = r.type == TxType.income ? CategoryKind.income : CategoryKind.expense;
    final k = categories.where((k) => k.name == name && k.kind == kind && !k.archived).firstOrNull;
    if (k == null) continue;
    r
      ..categoryId = k.id
      ..aiSuggested = true;
    placed++;
  }
  return placed;
}
