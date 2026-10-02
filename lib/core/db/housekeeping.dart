import 'package:clock/clock.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/money.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps local-only state from growing for as long as the app is used:
/// edit history older than a year (and beyond [keepVersions] per entry),
/// and per-day / per-month flags whose day or month is long past. Runs at
/// most once a day. Nothing here is synced or shown as data.
abstract final class Housekeeping {
  static const lastKey = 'tidy.last';
  static const keepVersions = 20;

  static Future<void> runIfDue(AppDatabase db, SharedPreferences prefs, {DateTime? now}) async {
    final today = Day.of(now ?? clock.now());
    if (prefs.getString(lastKey) == today) return;
    await run(db, prefs, now: now);
    await prefs.setString(lastKey, today);
  }

  static Future<void> run(AppDatabase db, SharedPreferences prefs, {DateTime? now}) async {
    final n = now ?? clock.now();
    // Edit history: a year back, and the newest versions of each entry.
    await db.customStatement('DELETE FROM entry_history WHERE julianday(at) < julianday(?)', [
      n.toUtc().subtract(const Duration(days: 365)).toIso8601String(),
    ]);
    await db.customStatement(
      'DELETE FROM entry_history WHERE id IN ('
      '  SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY transaction_id ORDER BY at DESC, id DESC) AS r '
      '  FROM entry_history) WHERE r > ?)',
      [keepVersions],
    );

    // Flags keyed by a day or a month that's gone by.
    final dayCutoff = Day.of(Day.shift(n, -60));
    final monthCutoff = Day.firstOfMonth(DateTime(n.year, n.month - 1)).substring(0, 7);
    final yearCutoff = Day.firstOfMonth(DateTime(n.year - 1, n.month)).substring(0, 7);
    final day = RegExp(r'\d{4}-\d{2}-\d{2}');
    final month = RegExp(r'\d{4}-\d{2}(?!-)');
    for (final k in prefs.getKeys().toList()) {
      String? stale;
      if (k.startsWith('notified.bill.')) {
        final d = day.allMatches(k).lastOrNull?.group(0);
        if (d != null && d.compareTo(dayCutoff) < 0) stale = k;
      } else if (k.startsWith('notified.budget.')) {
        final m = month.allMatches(k).lastOrNull?.group(0);
        if (m != null && m.compareTo(monthCutoff) < 0) stale = k;
      } else if (k.startsWith('ai.spent.') || k.startsWith('ai.used.') || k.startsWith('ai.cloud.spent.')) {
        final m = month.allMatches(k).lastOrNull?.group(0);
        if (m != null && m.compareTo(yearCutoff) < 0) stale = k;
      }
      if (stale != null) await prefs.remove(stale);
    }
  }
}

extension on Iterable<RegExpMatch> {
  RegExpMatch? get lastOrNull => isEmpty ? null : last;
}
