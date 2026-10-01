import 'package:juno/core/money.dart';

/// What a receipt says, read from its recognised text lines.
class ReceiptRead {
  const ReceiptRead({this.totalCents, this.currency, this.day, this.merchant, this.confident = false});

  final int? totalCents;
  final String? currency;
  final String? day;
  final String? merchant;

  /// True when the total came from a labelled line ("TOTAL 23.40") rather
  /// than the largest-number fallback.
  final bool confident;
}

final _amount = RegExp(r'(?<![\d.,])(\d{1,3}(?:[ ,.]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?![\d])');
final _totalLabel = RegExp(
  r'\b(grand\s*total|total\s*(?:due|ttc|amount|to\s*pay)?|amount\s*due|net\s*amount|to\s*pay|balance\s*due|net\s*total)\b|المجموع|الإجمالي',
  caseSensitive: false,
);
final _notTotal = RegExp(
  r'\b(sub\s*-?\s*total|tax|vat|tva|tip|change|cash|tendered|paid|discount|saving|points|qty|items?)\b',
  caseSensitive: false,
);

/// Reads a receipt's total, currency, date and merchant from OCR lines
/// (top to bottom). Conservative: a labelled TOTAL line wins; otherwise the
/// largest amount in the lower half, marked not confident so the UI says so.
ReceiptRead parseReceipt(List<String> lines) {
  final clean = [for (final l in lines) l.trim()].where((l) => l.isNotEmpty).toList();
  if (clean.isEmpty) return const ReceiptRead();
  final all = clean.join('\n');

  // Currency.
  String? currency;
  if (RegExp(r'\bLBP\b|L\.L\.?|ل\.ل|\bLL\b', caseSensitive: false).hasMatch(all)) currency = 'LBP';
  if (RegExp(r'\$|\bUSD\b', caseSensitive: false).hasMatch(all)) currency ??= 'USD';

  int? amountIn(String line) {
    final matches = _amount.allMatches(line).toList();
    if (matches.isEmpty) return null;
    // The amount on a total line is its last number ("TOTAL 2 items 23.40").
    return Money.parse(matches.last.group(1)!);
  }

  // 1. A labelled total, last one wins (receipts print subtotal, then total).
  int? total;
  var confident = false;
  for (var i = 0; i < clean.length; i++) {
    final l = clean[i];
    if (!_totalLabel.hasMatch(l) || _notTotal.hasMatch(l.replaceAll(_totalLabel, ''))) continue;
    if (RegExp(r'sub\s*-?\s*total', caseSensitive: false).hasMatch(l)) continue;
    final v = amountIn(l) ?? (i + 1 < clean.length ? amountIn(clean[i + 1]) : null);
    if (v != null && v > 0) {
      total = v;
      confident = true;
    }
  }
  // 2. Fallback: the largest amount in the lower half, skipping cash/change.
  if (total == null) {
    var best = 0;
    for (final l in clean.skip(clean.length ~/ 2)) {
      if (_notTotal.hasMatch(l) || _looksLikeDate(l)) continue;
      final v = amountIn(l);
      if (v != null && v > best) best = v;
    }
    if (best > 0) total = best;
  }
  // LBP totals are large and whole; a "$" never appears on them.
  if (currency == null && total != null && total >= 1000000 && total % 100 == 0) currency = 'LBP';

  // Date: first date-looking token, day-first unless impossible.
  String? day;
  final dm = RegExp(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b|\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})\b').firstMatch(all);
  if (dm != null) {
    int y;
    int m;
    int d;
    if (dm.group(1) != null) {
      y = int.parse(dm.group(1)!);
      m = int.parse(dm.group(2)!);
      d = int.parse(dm.group(3)!);
    } else {
      final a = int.parse(dm.group(4)!);
      final b = int.parse(dm.group(5)!);
      y = int.parse(dm.group(6)!);
      if (y < 100) y += 2000;
      // Day-first (Lebanon, most of the world) unless the first can't be a day… or the second can't be a month.
      if (b > 12 && a <= 12) {
        m = a;
        d = b;
      } else {
        d = a;
        m = b;
      }
    }
    if (m >= 1 && m <= 12 && d >= 1 && d <= 31 && y >= 2000 && y <= 2100) {
      day = Day.of(DateTime(y, m, d));
    }
  }

  // Merchant: the first line that reads like a name.
  String? merchant;
  for (final l in clean.take(5)) {
    final letters = l.replaceAll(RegExp(r'[^\p{L}]', unicode: true), '');
    if (letters.length < 3) continue;
    if (RegExp(
      r'receipt|invoice|tax|vat|tel|phone|www\.|http|welcome|date|time|cashier',
      caseSensitive: false,
    ).hasMatch(l)) {
      continue;
    }
    merchant = _title(l);
    break;
  }

  return ReceiptRead(totalCents: total, currency: currency, day: day, merchant: merchant, confident: confident);
}

bool _looksLikeDate(String l) =>
    RegExp(r'\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}|\d{4}-\d{2}-\d{2}|\d{1,2}:\d{2}').hasMatch(l);

String _title(String s) {
  final words = s.split(RegExp(r'\s+'));
  return words
      .map((w) => w.length <= 1 ? w : (w == w.toUpperCase() ? '${w[0]}${w.substring(1).toLowerCase()}' : w))
      .join(' ');
}
