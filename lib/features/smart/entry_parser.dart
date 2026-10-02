import 'package:clock/clock.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/deeplink/quick_add.dart' show fuzzyMatch;
import 'package:juno/core/money.dart';
import 'package:juno/features/import/csv_import.dart' show keywordHints;

/// What a line of free text means as an entry. Every field is optional;
/// the add sheet fills in what was understood and leaves the rest.
class ParsedEntry {
  const ParsedEntry({
    this.amountCents,
    this.currency,
    this.currencyGuessed = false,
    this.type,
    this.categoryId,
    this.scope,
    this.day,
    this.note = '',
  });

  final int? amountCents;

  /// 'USD', 'LBP', … — null when the text didn't say and nothing implied it.
  final String? currency;

  /// True when LBP was inferred from the size of the number ("150000 taxi").
  final bool currencyGuessed;
  final TxType? type;
  final String? categoryId;
  final Scope? scope;
  final String? day;
  final String note;

  @override
  String toString() =>
      'ParsedEntry($amountCents $currency${currencyGuessed ? '?' : ''} $type cat=$categoryId $scope $day "$note")';
}

/// Parses quick-entry text on-device:
///
/// * `12 coffee kalei` → $12.00, Coffee, note "Kalei"
/// * `40k taxi yesterday` → LBP 40,000, Transport, yesterday
/// * `LBP 150000 generator household` → LBP 150,000, household
/// * `$5.50 lunch at tawlet` → $5.50, Dining, "Tawlet"
/// * `salary 5200` → income, Salary
/// * `2 days ago 18 groceries` → $18, Groceries, two days ago
///
/// [memory] maps lowercased merchant/note text to the category last used
/// for it (Ledger.merchantCategoryMemory), so your own habits win over the
/// built-in keyword list.
ParsedEntry parseEntry(
  String input, {
  required List<Category> categories,
  Map<String, String> memory = const {},
  bool hasLbpAccount = true,
  DateTime? now,
}) {
  final today = now ?? clock.now();
  var text = ' ${input.trim()} ';

  // ---- amount (+ currency) ------------------------------------------------
  int? cents;
  String? currency;
  var guessed = false;
  final amountRe = RegExp(
    r'(?<pre>\$|usd|lbp|l\.l\.?|ll|€|eur)?\s*(?<num>\d[\d,.]*)\s*(?<mult>k|m|mil|million|thousand)?\b\s*(?<post>\$|usd|lbp|l\.l\.?|ll|lira|€|eur|dollars?)?',
    caseSensitive: false,
  );
  for (final m in amountRe.allMatches(text)) {
    final numText = m.namedGroup('num')!;
    final parsed = Money.parse(numText);
    if (parsed == null || parsed <= 0) continue;
    // "2 days ago": a number that is part of a date phrase isn't the amount.
    final after = text.substring(m.end).toLowerCase();
    if (m.namedGroup('mult') == null && RegExp(r'^\s*(days?|weeks?)\s+ago').hasMatch(after)) continue;
    var value = parsed;
    final mult = m.namedGroup('mult')?.toLowerCase();
    if (mult != null) value *= mult.startsWith('k') || mult == 'thousand' ? 1000 : 1000000;
    final tag = (m.namedGroup('pre') ?? m.namedGroup('post'))?.toLowerCase();
    currency = switch (tag) {
      null => null,
      r'$' || 'usd' || 'dollar' || 'dollars' => 'USD',
      '€' || 'eur' => 'EUR',
      _ => 'LBP',
    };
    cents = value;
    text = text.replaceRange(m.start, m.end, ' ');
    break;
  }
  // Nobody logs a $40,000 taxi: big round numbers without a currency are
  // pounds when there is an LBP account.
  if (cents != null && currency == null && hasLbpAccount && cents >= 1000000 && cents % 100000 == 0) {
    currency = 'LBP';
    guessed = true;
  }

  // ---- date ----------------------------------------------------------------
  String? day;
  final lower = text.toLowerCase();
  final ago = RegExp(r'\b(\d+)\s+(days?|weeks?)\s+ago\b').firstMatch(lower);
  if (ago != null) {
    final n = int.parse(ago.group(1)!) * (ago.group(2)!.startsWith('week') ? 7 : 1);
    day = Day.of(DateTime(today.year, today.month, today.day - n));
    text = text.replaceRange(ago.start, ago.end, ' ');
  } else if (RegExp(r'\byesterday\b').hasMatch(lower)) {
    day = Day.of(DateTime(today.year, today.month, today.day - 1));
    text = text.replaceAll(RegExp(r'\byesterday\b', caseSensitive: false), ' ');
  } else if (RegExp(r'\btoday\b').hasMatch(lower)) {
    day = Day.of(today);
    text = text.replaceAll(RegExp(r'\btoday\b', caseSensitive: false), ' ');
  } else {
    const names = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
    for (var i = 0; i < names.length; i++) {
      final re = RegExp('\\b(last\\s+|on\\s+)?(${names[i]}|${names[i].substring(0, 3)})\\b', caseSensitive: false);
      final m = re.firstMatch(text);
      if (m == null) continue;
      // Most recent such weekday strictly before today.
      var back = (today.weekday - (i + 1)) % 7;
      if (back == 0) back = 7;
      day = Day.of(DateTime(today.year, today.month, today.day - back));
      text = text.replaceRange(m.start, m.end, ' ');
      break;
    }
  }

  // ---- scope / type words -----------------------------------------------
  Scope? scope;
  TxType? type;
  bool take(RegExp re) {
    if (!re.hasMatch(text)) return false;
    text = text.replaceAll(re, ' ');
    return true;
  }

  if (take(RegExp(r'\b(household|home|family|house)\b', caseSensitive: false))) scope = Scope.household;
  if (take(RegExp(r'\b(personal|me|mine)\b', caseSensitive: false))) scope = Scope.personal;
  if (take(RegExp(r'\b(income|received|got paid|earned)\b', caseSensitive: false))) type = TxType.income;
  text = text.replaceAll(RegExp(r'\b(for|on|at|in|spent|paid|the|a)\b', caseSensitive: false), ' ');

  // ---- category ------------------------------------------------------------
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final lowerWords = [for (final w in words) w.toLowerCase()];
  String? categoryId;
  var used = <int>{};
  final kindFor = type == TxType.income ? CategoryKind.income : null;
  List<Category> pool(CategoryKind? kind) =>
      kind == null ? categories : categories.where((c) => c.kind == kind).toList();

  // 1. Your history: a remembered merchant/note inside the text.
  final phrase = lowerWords.join(' ');
  String? best;
  var bestLen = 0;
  for (final e in memory.entries) {
    if (e.key.length >= 3 && e.key.length > bestLen && phrase.contains(e.key)) {
      best = e.value;
      bestLen = e.key.length;
    }
  }
  if (best != null && categories.any((c) => c.id == best && (kindFor == null || c.kind == kindFor))) {
    categoryId = best;
  }
  // 2. A word that names a category ("coffee", "groceries", "rent").
  if (categoryId == null) {
    for (var i = 0; i < words.length; i++) {
      if (words[i].length < 3) continue;
      final hit = fuzzyMatch(words[i], pool(kindFor), (c) => c.name);
      if (hit != null && _closeEnough(words[i], hit.name)) {
        categoryId = hit.id;
        used = {i};
        break;
      }
    }
  }
  // 3. Built-in hints ("taxi" → Transport, "netflix" → Subscriptions).
  if (categoryId == null) {
    final keys = keywordHints.keys.where((k) => ' $phrase '.contains(' $k ') || phrase.contains(k)).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final k in keys) {
      final name = keywordHints[k]!;
      final cat = pool(kindFor).where((c) => c.name.toLowerCase() == name.toLowerCase()).firstOrNull;
      if (cat != null) {
        categoryId = cat.id;
        break;
      }
    }
  }
  final cat = categories.where((c) => c.id == categoryId).firstOrNull;
  if (type == null && cat?.kind == CategoryKind.income) type = TxType.income;

  final noteWords = [
    for (var i = 0; i < words.length; i++)
      if (!used.contains(i)) words[i],
  ];
  final note = noteWords.isEmpty
      ? ''
      : noteWords.map((w) => w.length > 1 ? '${w[0].toUpperCase()}${w.substring(1)}' : w.toUpperCase()).join(' ');

  return ParsedEntry(
    amountCents: cents,
    currency: currency,
    currencyGuessed: guessed,
    type: type,
    categoryId: categoryId,
    scope: scope,
    day: day,
    note: note,
  );
}

/// fuzzyMatch also accepts containment both ways; for single words in free
/// text that is too loose ("me" in "Home"), so require a real resemblance.
bool _closeEnough(String word, String name) {
  final w = word.toLowerCase();
  final n = name.toLowerCase();
  if (n == w || n.startsWith(w) || w.startsWith(n)) return w.length >= 3;
  final first = n.split(RegExp(r'[\s&]+')).first;
  return first.startsWith(w) || w.startsWith(first) || _edit(w, first) <= 2;
}

int _edit(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}
