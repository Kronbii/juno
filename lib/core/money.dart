import 'package:intl/intl.dart';

/// Money is integer cents everywhere. Floats never touch a balance.
abstract final class Money {
  static final _full = NumberFormat.currency(locale: 'en_US', symbol: r'$');
  static final _whole = NumberFormat.currency(locale: 'en_US', symbol: r'$', decimalDigits: 0);
  static final _compact = NumberFormat.compactCurrency(locale: 'en_US', symbol: r'$');
  static final _plain = NumberFormat('#,##0.00', 'en_US');

  /// `$1,204.50`
  static String format(int cents) => _full.format(cents / 100);

  /// `$1,205` — for headline figures where cents are noise.
  static String whole(int cents) => _whole.format(cents / 100);

  /// `$12.4K` — chart axes.
  static String compact(int cents) => cents == 0 ? r'$0' : _compact.format(cents / 100);

  /// `1,204.50` without the symbol, for figures that set the `$` separately.
  static String plain(int cents) => _plain.format(cents / 100);

  /// `+$40.00` / `−$12.50` with a true minus sign.
  static String signed(int cents) =>
      // U+2060 keeps the sign glued to the figure when text wraps.
      cents < 0 ? '\u2212\u2060${format(-cents)}' : '+\u2060${format(cents)}';

  /// Parses user or CSV input to cents. Accepts `$1,204.5`, `(12.00)`,
  /// `-12`, `12-`, `1.204,50` (EU) and `USD 12`. Returns null when there is
  /// no number in it.
  static int? parse(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    var negative = false;
    if (s.startsWith('(') && s.endsWith(')')) {
      negative = true;
      s = s.substring(1, s.length - 1);
    }
    s = s.replaceAll(RegExp(r'[^\d,.\-−]'), '');
    if (s.contains('-') || s.contains('−')) {
      negative = true;
      s = s.replaceAll(RegExp('[-−]'), '');
    }
    if (s.isEmpty) return null;

    final lastComma = s.lastIndexOf(',');
    final lastDot = s.lastIndexOf('.');
    if (lastComma > lastDot) {
      // Comma is the decimal separator only when it has 1–2 digits after it.
      final tail = s.length - lastComma - 1;
      s = tail <= 2 ? s.replaceAll('.', '').replaceAll(',', '.') : s.replaceAll(',', '');
    } else {
      s = s.replaceAll(',', '');
    }
    final value = double.tryParse(s);
    if (value == null) return null;
    final cents = (value * 100).round();
    return negative ? -cents : cents;
  }
}

/// Calendar days as `YYYY-MM-DD` strings — the storage form for "when".
abstract final class Day {
  static String of(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String today() => of(DateTime.now());

  static DateTime parse(String day) {
    final p = day.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  static String firstOfMonth(DateTime m) => of(DateTime(m.year, m.month));

  static String lastOfMonth(DateTime m) => of(DateTime(m.year, m.month + 1, 0));

  static int daysInMonth(DateTime m) => DateTime(m.year, m.month + 1, 0).day;

  static final _label = DateFormat('EEE d MMM');
  static final _labelYear = DateFormat('EEE d MMM yyyy');
  static final _short = DateFormat('d MMM');
  static final _month = DateFormat('MMMM');
  static final _monthYear = DateFormat('MMMM yyyy');
  static final _monthShort = DateFormat('MMM');

  /// `Today`, `Yesterday`, `Tue 30 Sep`.
  static String relative(String day) {
    final d = parse(day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(d).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff == -1) return 'Tomorrow';
    return d.year == now.year ? _label.format(d) : _labelYear.format(d);
  }

  static String short(String day) => _short.format(parse(day));
  static String month(DateTime m) => _month.format(m);
  static String monthYear(DateTime m) => _monthYear.format(m);
  static String monthShort(DateTime m) => _monthShort.format(m);
}
