import 'package:intl/intl.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/money.dart';

/// Base currency. Totals, budgets, goals and insights are all in USD; other
/// currencies live on accounts and convert at entry time.
const baseCurrency = 'USD';

class CurrencyInfo {
  const CurrencyInfo(this.code, this.name, {this.symbol, this.decimals = 2});

  final String code;
  final String name;

  /// Prefix symbol; null prints the code (`LBP 150,000`).
  final String? symbol;

  /// Digits shown. LBP shows none — nobody counts piastres.
  final int decimals;
}

const currencies = <String, CurrencyInfo>{
  'USD': CurrencyInfo('USD', 'US dollar', symbol: r'$'),
  'LBP': CurrencyInfo('LBP', 'Lebanese pound', decimals: 0),
  'EUR': CurrencyInfo('EUR', 'Euro', symbol: '€'),
  'GBP': CurrencyInfo('GBP', 'British pound', symbol: '£'),
  'AED': CurrencyInfo('AED', 'UAE dirham'),
  'SAR': CurrencyInfo('SAR', 'Saudi riyal'),
  'TRY': CurrencyInfo('TRY', 'Turkish lira', symbol: '₺'),
};

CurrencyInfo currencyInfo(String code) => currencies[code] ?? CurrencyInfo(code, code);

abstract final class Fx {
  /// Formats [cents] (hundredths of a unit) in [code].
  static String format(int cents, String code) {
    if (code == baseCurrency) return Money.format(cents);
    final info = currencyInfo(code);
    final f = NumberFormat.currency(
      locale: 'en_US',
      symbol: info.symbol ?? '${info.code} ',
      decimalDigits: info.decimals,
    );
    return f.format(cents / 100);
  }

  /// Converts [cents] of [code] to USD cents with [perUsd] (units per USD).
  static int toUsd(int cents, String code, Map<String, double> perUsd) {
    if (code == baseCurrency) return cents;
    final rate = perUsd[code];
    // Never fall back to "treat it as dollars": LBP 1,500,000 would become
    // $1.5M. A missing rate is a bug to surface, not a number to show.
    if (rate == null || rate <= 0) throw StateError('No exchange rate for $code');
    return (cents / rate).round();
  }

  /// Converts between two non-base currencies through USD.
  static int convert(int cents, String from, String to, Map<String, double> perUsd) {
    if (from == to) return cents;
    final usd = toUsd(cents, from, perUsd);
    if (to == baseCurrency) return usd;
    final rate = perUsd[to];
    if (rate == null || rate <= 0) throw StateError('No exchange rate for $to');
    return (usd * rate).round();
  }

  /// Values for the transaction columns a new entry in [currency] needs.
  static int? baseFor(int cents, String currency, Map<String, double> perUsd) =>
      currency == baseCurrency ? null : toUsd(cents, currency, perUsd);
}

extension TransactionUsd on Transaction {
  /// The amount in USD — what every total and chart adds up.
  int get usd => baseCents ?? amountCents;

  List<String> get tagList => EntryTags.parse(tags);
}

abstract final class EntryTags {
  /// `,trip,gift,` → `[trip, gift]`.
  static List<String> parse(String stored) =>
      stored.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

  /// Normalises user input (`#Trip Istanbul, gift`) to the stored form
  /// (`,trip-istanbul,gift,`). Empty input stores as ''.
  static String store(Iterable<String> tags) {
    final clean = <String>{
      for (final t in tags)
        if (normalize(t).isNotEmpty) normalize(t),
    };
    return clean.isEmpty ? '' : ',${clean.join(',')},';
  }

  static String normalize(String t) =>
      t.trim().toLowerCase().replaceAll('#', '').replaceAll(RegExp(r'\s+'), '-').replaceAll(',', '');

  /// Splits free text typed into a tag field.
  static List<String> fromInput(String input) => input.split(',').map(normalize).where((t) => t.isNotEmpty).toList();
}
