import 'package:juno/core/sync/sync_engine.dart';

/// In-memory stand-in for the Supabase tables, with the same semantics as
/// the server trigger (supabase/migrations/*_lww.sql): an incoming row older
/// than the stored one is ignored, and every write stamps a monotonically
/// increasing server_updated_at (the pull cursor).
class FakeRemote implements SyncRemote {
  final Map<String, Map<String, Map<String, dynamic>>> tables = {};
  var _clock = 0;
  bool down = false;

  /// Signed-in user; tests switch it to simulate another account.
  String? user = 'user-1';

  /// Rows the server refuses (e.g. a constraint violation), by note.
  final Set<String> rejectNotes = {};

  @override
  String? get userId => user;

  /// A row whose transaction committed late: stamped with a server time
  /// earlier than rows other devices have already pulled.
  void insertLate(String table, Map<String, dynamic> row, {int microsBeforeNewest = 5}) {
    tables.putIfAbsent(table, () => {})[row['id'] as String] = {
      ...row,
      'server_updated_at': DateTime.utc(
        2030,
      ).add(Duration(microseconds: _clock - microsBeforeNewest)).toIso8601String(),
    };
  }

  static DateTime _at(Object? v) => DateTime.parse(v! as String).toUtc();

  @override
  Future<void> upsert(String table, List<Map<String, dynamic>> rows, {bool keepExisting = false}) async {
    if (down) throw Exception('network down');
    final t = tables.putIfAbsent(table, () => {});
    // Postgres now() is the transaction start: a whole batch shares one
    // stamp. The cursor must cope with that.
    _clock++;
    for (final r in rows) {
      if (rejectNotes.contains(r['note'])) throw Exception('row rejected by server');
    }
    for (final r in rows) {
      final id = r['id'] as String;
      final old = t[id];
      // Insert-only (ON CONFLICT DO NOTHING): an existing row is untouched.
      if (keepExisting && old != null) continue;
      final keepOld = old != null && _at(r['updated_at']).isBefore(_at(old['updated_at']));
      t[id] = {
        ...(keepOld ? old : r),
        'server_updated_at': DateTime.utc(2030).add(Duration(microseconds: _clock)).toIso8601String(),
      };
    }
  }

  @override
  Future<List<Map<String, dynamic>>> changedSince(String table, SyncCursor? cursor, int limit) async {
    if (down) throw Exception('network down');
    final rows =
        (tables[table]?.values ?? const <Map<String, dynamic>>[])
            .where((r) => cursor == null || cursor.before(r['server_updated_at'] as String, r['id'] as String))
            .toList()
          ..sort((a, b) {
            final c = (a['server_updated_at'] as String).compareTo(b['server_updated_at'] as String);
            return c != 0 ? c : (a['id'] as String).compareTo(b['id'] as String);
          });
    return rows.take(limit).toList();
  }
}
