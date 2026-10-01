import 'dart:math' as math;

import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';

/// A `juno://add?...` request, as sent by the iOS Back Tap Shortcut.
///
/// ```text
/// juno://add?amount=12.50&category=Groceries&scope=household
///           &note=Spinneys&account=Cash&type=expense&date=2026-10-01
/// ```
/// Every parameter is optional. With an amount the entry is saved straight
/// away; without one (or with `confirm=1`) the add sheet opens prefilled.
class QuickAdd {
  const QuickAdd({
    this.amountCents,
    this.category,
    this.account,
    this.currency,
    this.tags = const [],
    this.scope,
    this.type,
    this.note,
    this.day,
    this.confirm = false,
    this.text,
  });

  final int? amountCents;
  final String? category;
  final String? account;

  /// Picks the first account in this currency when no account is named.
  final String? currency;
  final List<String> tags;
  final Scope? scope;
  final TxType? type;
  final String? note;
  final String? day;
  final bool confirm;

  /// Free text ("12 coffee kalei") from a dictation Shortcut; parsed with
  /// the same on-device parser as the add sheet's quick line.
  final String? text;

  bool get saveDirectly => !confirm && (amountCents ?? 0) > 0;

  /// Null when [uri] is not a quick-add link.
  static QuickAdd? parse(Uri uri) {
    final isAdd =
        (uri.scheme == 'juno' && (uri.host == 'add' || uri.path == '/add' || uri.path == 'add')) || uri.path == '/add';
    if (!isAdd) return null;
    final q = {for (final e in uri.queryParameters.entries) e.key.toLowerCase(): e.value.trim()};
    String? s(String k) => (q[k]?.isEmpty ?? true) ? null : q[k];

    final rawAmount = s('amount') ?? s('a');
    final cents = rawAmount == null ? null : Money.parse(rawAmount);

    final scopeRaw = (s('scope') ?? s('for'))?.toLowerCase();
    final scope = switch (scopeRaw) {
      null => null,
      final v when v.startsWith('h') || v == 'home' || v == 'family' || v == 'shared' => Scope.household,
      final v when v.startsWith('p') || v == 'me' || v == 'mine' => Scope.personal,
      _ => null,
    };

    final typeRaw = s('type')?.toLowerCase();
    var type = switch (typeRaw) {
      'income' || 'in' || 'received' => TxType.income,
      'expense' || 'out' || 'spent' => TxType.expense,
      _ => null,
    };
    // A negative amount from a Shortcut means money out; positive is the
    // default meaning (an expense) unless type says otherwise.
    if (cents != null && cents < 0) type ??= TxType.expense;

    final dateRaw = s('date');
    String? day;
    if (dateRaw != null) {
      final d = DateTime.tryParse(dateRaw);
      // A Shortcut may send an ISO timestamp in UTC; the entry's day is the
      // local calendar day.
      if (d != null) day = Day.of(d.isUtc ? d.toLocal() : d);
      if (dateRaw.toLowerCase() == 'yesterday') {
        day = Day.of(DateTime.now().subtract(const Duration(days: 1)));
      }
    }

    return QuickAdd(
      amountCents: cents?.abs(),
      category: s('category') ?? s('cat') ?? s('c'),
      account: s('account'),
      currency: s('currency')?.toUpperCase(),
      tags: EntryTags.fromInput(s('tags') ?? s('tag') ?? ''),
      scope: scope,
      type: type,
      note: s('note') ?? s('n'),
      day: day,
      confirm: s('confirm') == '1' || s('confirm') == 'true',
      text: s('text') ?? s('q'),
    );
  }
}

/// Best match for a typed name: exact, prefix, contains, then edit distance
/// ≤ 2 (so "grocery" and "Groceris" find Groceries). Case-insensitive.
T? fuzzyMatch<T>(String? query, Iterable<T> items, String Function(T) name) {
  if (query == null || query.trim().isEmpty) return null;
  final q = _norm(query);
  if (q.isEmpty) return null;
  // Names that normalise to nothing (emoji only) would prefix-match anything.
  final list = items.where((i) => _norm(name(i)).isNotEmpty).toList();
  for (final pass in [
    (String n) => n == q,
    (String n) => n.startsWith(q) || q.startsWith(n),
    (String n) => n.contains(q) || q.contains(n),
  ]) {
    final hit = list.where((i) => pass(_norm(name(i))));
    if (hit.isNotEmpty) return hit.first;
  }
  T? best;
  var bestD = 3;
  for (final i in list) {
    final d = _levenshtein(q, _norm(name(i)));
    if (d < bestD) {
      best = i;
      bestD = d;
    }
  }
  return best;
}

/// Lowercase, alphanumerics only, naive singular ("groceries" → "grocery",
/// "subscriptions" → "subscription") so plurals match what people type.
String _norm(String s) {
  final w = s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  if (w.length > 4 && w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
  if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) return w.substring(0, w.length - 1);
  return w;
}

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    prev = cur;
  }
  return prev[b.length];
}
