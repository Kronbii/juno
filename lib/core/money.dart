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

  /// Parses user or CSV input to cents, with integer arithmetic only.
  ///
  /// Accepts `$1,204.5`, `(12.00)`, `-12`, `12-`, `12 DR`/`12 CR`,
  /// `1.204,50` and `150.000` (dot thousands, as LBP is often written),
  /// `1 234,56`, `1'234.56`, `USD 12`. A lone separator followed by exactly
  /// three digits is a thousands separator (`1.005` = 1,005), unless the
  /// whole part is 0 (`0.285`). Returns null when it isn't a number — text
  /// such as `Address Line 1` included.
  static int? parse(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    var negative = false;
    if (s.startsWith('(') && s.endsWith(')')) {
      negative = true;
      s = s.substring(1, s.length - 1).trim();
    }
    // Currency codes/symbols and debit/credit markers around the number.
    final marker = RegExp(r'^(?:[A-Za-z]{2,3}|[$€£₺¥])\s*|\s*(?:[A-Za-z]{2,3}|[$€£₺¥])$');
    for (var i = 0; i < 2; i++) {
      final m = marker.firstMatch(s);
      if (m == null) break;
      final token = m.group(0)!.trim().toUpperCase();
      if (token == 'DR') negative = true;
      s = s.replaceRange(m.start, m.end, '').trim();
    }
    if (s.startsWith('-') || s.startsWith('−')) {
      negative = !negative;
      s = s.substring(1).trim();
    } else if (s.endsWith('-') || s.endsWith('−')) {
      negative = !negative;
      s = s.substring(0, s.length - 1).trim();
    } else if (s.startsWith('+')) {
      s = s.substring(1).trim();
    }
    if (s.startsWith(r'$') || s.startsWith('€') || s.startsWith('£')) s = s.substring(1).trim();
    if (!RegExp(r"^\d[\d.,'  ]*$|^[.,]\d+$").hasMatch(s)) return null;
    s = s.replaceAll(RegExp("['  ]"), '');

    final lastDot = s.lastIndexOf('.');
    final lastComma = s.lastIndexOf(',');
    var whole = s;
    var frac = '';
    final sepAt = lastDot > lastComma ? lastDot : lastComma;
    if (sepAt >= 0) {
      final sep = s[sepAt];
      final other = sep == '.' ? ',' : '.';
      final tail = s.substring(sepAt + 1);
      final head = s.substring(0, sepAt);
      final sepCount = sep.allMatches(s).length;
      final bothKinds = s.contains(other);
      final isDecimal =
          bothKinds ||
          (sepCount == 1 && (tail.length != 3 || head.replaceAll(RegExp('[.,]'), '').replaceAll('0', '').isEmpty));
      if (isDecimal) {
        whole = head.replaceAll(RegExp('[.,]'), '');
        frac = tail;
      } else {
        whole = s.replaceAll(RegExp('[.,]'), '');
      }
    }
    if (whole.isEmpty) whole = '0';
    if (!RegExp(r'^\d+$').hasMatch(whole) || (frac.isNotEmpty && !RegExp(r'^\d+$').hasMatch(frac))) return null;
    final padded = frac.padRight(3, '0');
    var cents = int.parse(whole) * 100 + int.parse(padded.substring(0, 2));
    if (padded.codeUnitAt(2) - 48 >= 5) cents += 1; // half-up on the 3rd digit
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

  /// Whole calendar days from [a] to [b] (negative if [b] is earlier).
  /// Counted on the dates, not the clock: `b.difference(a).inDays` loses a
  /// day across a spring DST change (Lebanon moves its clocks at midnight,
  /// so "yesterday" is only 23 hours ago and would read as today).
  static int between(DateTime a, DateTime b) =>
      DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  /// The date [days] after [d] (before, if negative), on the calendar.
  /// `d.add(Duration(days: n))` adds 24-hour blocks, which lands on the
  /// wrong date across a DST change when [d] is near midnight.
  static DateTime shift(DateTime d, int days) => DateTime(d.year, d.month, d.day + days);

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
  static String relative(String day, {DateTime? now}) {
    final d = parse(day);
    now ??= DateTime.now();
    final diff = between(d, now);
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
