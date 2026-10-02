import 'dart:async';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/attachments/attachment_store.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/db/seed.dart';
import 'package:juno/core/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase project, passed at build time:
/// `flutter run --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…`
/// (or `--dart-define-from-file=supabase.json`). Without them Juno runs
/// local-only and the sync UI says so.
const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// Juno's AI relay on the same Supabase project: the `ai` edge function,
/// called with the signed-in session.
class SupabaseAiCloud implements AiCloud {
  const SupabaseAiCloud();

  GoTrueClient get _auth => Supabase.instance.client.auth;

  @override
  bool get available => SyncEngine.configured && _auth.currentUser != null;

  @override
  Future<(Uri, Map<String, String>)?> endpoint() async {
    if (!available) return null;
    var session = _auth.currentSession;
    if (session == null) return null;
    if (session.isExpired) session = (await _auth.refreshSession()).session;
    if (session == null) return null;
    return (
      Uri.parse('$_url/functions/v1/ai'),
      {'Authorization': 'Bearer ${session.accessToken}', 'apikey': _anonKey},
    );
  }
}

enum SyncPhase { disabled, signedOut, idle, syncing, error }

class SyncStatus {
  const SyncStatus(this.phase, {this.lastSynced, this.message, this.email});

  final SyncPhase phase;
  final DateTime? lastSynced;
  final String? message;
  final String? email;

  SyncStatus copyWith({SyncPhase? phase, DateTime? lastSynced, String? message, String? email}) => SyncStatus(
    phase ?? this.phase,
    lastSynced: lastSynced ?? this.lastSynced,
    message: message,
    email: email ?? this.email,
  );
}

/// Abstracts the server so the merge logic can be tested without Supabase.
abstract class SyncRemote {
  String? get userId;

  Future<void> upsert(String table, List<Map<String, dynamic>> rows);

  /// Rows changed on the server after [cursor], ordered by
  /// (server_updated_at, id), at most [limit]. Keyset paging on the pair:
  /// many rows share one server timestamp (Postgres now() is per
  /// transaction), so paging on the timestamp alone skips rows.
  Future<List<Map<String, dynamic>>> changedSince(String table, SyncCursor? cursor, int limit);
}

/// Position in a table's change feed.
class SyncCursor {
  const SyncCursor(this.at, this.id);

  /// Stored as `at|id`. A bare timestamp (older builds) resumes with id ''
  /// — every id sorts after it, so nothing at that timestamp is skipped.
  factory SyncCursor.parse(String s) {
    final i = s.lastIndexOf('|');
    return i < 0 ? SyncCursor(s, '') : SyncCursor(s.substring(0, i), s.substring(i + 1));
  }

  final String at;
  final String id;

  /// Postgres returns `…123456+00:00`; a `+` inside a PostgREST filter is
  /// read as a space, which silently breaks the equality branch of the
  /// keyset query. UTC `…Z` keeps microsecond precision with no `+`.
  static String normalize(String ts) => DateTime.parse(ts).toUtc().toIso8601String();

  @override
  String toString() => '$at|$id';

  /// Whether a row at ([rowAt], [rowId]) comes after this cursor.
  bool before(String rowAt, String rowId) {
    final a = DateTime.parse(rowAt).toUtc();
    final c = DateTime.parse(at).toUtc();
    return a.isAfter(c) || (a.isAtSameMomentAs(c) && rowId.compareTo(id) > 0);
  }
}

class SupabaseRemote implements SyncRemote {
  SupabaseRemote([this._client]);

  final SupabaseClient? _client;
  SupabaseClient get _c => _client ?? Supabase.instance.client;

  @override
  String? get userId => _c.auth.currentUser?.id;

  @override
  Future<void> upsert(String table, List<Map<String, dynamic>> rows) =>
      _c.from(table).upsert(rows, onConflict: 'user_id,id');

  @override
  Future<List<Map<String, dynamic>>> changedSince(String table, SyncCursor? cursor, int limit) async {
    var q = _c.from(table).select();
    if (cursor != null) {
      final at = '"${SyncCursor.normalize(cursor.at)}"';
      q = cursor.id.isEmpty
          ? q.gte('server_updated_at', SyncCursor.normalize(cursor.at))
          : q.or('server_updated_at.gt.$at,and(server_updated_at.eq.$at,id.gt.${cursor.id})');
    }
    // postgrest-dart's order() defaults to DESCENDING; the cursor needs
    // oldest-first, so both keys are explicit.
    final res = await q.order('server_updated_at', ascending: true).order('id', ascending: true).limit(limit);
    return List<Map<String, dynamic>>.from(res);
  }
}

/// Local-first sync: every table is pushed (dirty rows) then pulled
/// (server changes since the last cursor). Conflicts resolve last-write-wins
/// on the row's `updated_at`; deletes are soft so they travel like edits.
/// The device holds another account's data.
class AccountMismatch implements Exception {
  const AccountMismatch();

  @override
  String toString() =>
      'This device holds another account’s data. Sign in with that account, or reset local data to switch.';
}

class SyncCore {
  SyncCore(this.db, this.remote);

  final AppDatabase db;
  final SyncRemote remote;

  static const tables = [
    'accounts',
    'categories',
    'transactions',
    'budgets',
    'goals',
    'goal_contributions',
    'recurring_rules',
    'import_batches',
    'currency_rates',
    'attachments',
  ];

  static const _batch = 500;

  TableInfo<Table, dynamic> _table(String name) => db.allTables.firstWhere((t) => t.actualTableName == name);

  /// Rows (or whole tables) that failed this run. They stay dirty or keep
  /// their cursor, so the next run retries them; everything else proceeds.
  int failures = 0;

  /// How far each pull re-reads behind its cursor. server_updated_at is the
  /// *start* of the writing transaction, so a long push can commit rows
  /// stamped earlier than ones another device already pulled. Re-reading a
  /// short window catches them; merging is idempotent.
  static const overlap = Duration(minutes: 2);

  static const ownerKey = 'owner_uid';

  Future<void> run() async {
    final uid = remote.userId;
    if (uid == null) return;
    // A device's rows belong to one account. Syncing them into another
    // would leak them there and leave the other account's data unpulled.
    final owner = await db.meta(ownerKey);
    if (owner != null && owner != uid) throw const AccountMismatch();
    if (owner == null) await db.setMeta(ownerKey, uid);

    for (final t in tables) {
      try {
        await push(t, uid);
      } on Object {
        failures++;
      }
    }
    for (final t in tables) {
      try {
        await pull(t);
      } on Object {
        failures++;
      }
    }
  }

  Future<void> push(String name, String uid) async {
    final info = _table(name);
    final cols = {for (final c in info.$columns) c.name: c};
    final failed = <String>{};
    while (true) {
      final skip = failed.isEmpty ? '' : 'AND id NOT IN (${List.filled(failed.length, '?').join(',')})';
      final rows = await db
          .customSelect(
            'SELECT * FROM $name WHERE dirty = 1 $skip LIMIT $_batch',
            variables: [for (final id in failed) Variable.withString(id)],
          )
          .get();
      if (rows.isEmpty) return;
      Map<String, dynamic> toRemote(QueryRow r) => {
        for (final e in r.data.entries)
          if (e.key != 'dirty') e.key: _toRemote(cols[e.key], e.value),
        'user_id': uid,
      };

      var sent = rows;
      try {
        await remote.upsert(name, [for (final r in rows) toRemote(r)]);
      } on Object {
        // Find the bad row(s): retry one by one, keep going with the rest.
        sent = [];
        for (final r in rows) {
          try {
            await remote.upsert(name, [toRemote(r)]);
            sent.add(r);
          } on Object {
            failed.add(r.data['id'] as String);
            failures++;
          }
        }
      }
      // Clear dirty only if the row wasn't edited again while we pushed.
      await db.transaction(() async {
        for (final r in sent) {
          await db.customStatement(
            'UPDATE $name SET dirty = 0, user_id = ? WHERE id = ? AND updated_at = ?',
            [uid, r.data['id'], r.data['updated_at']],
          );
        }
      });
      if (rows.length < _batch && failed.isEmpty) return;
      if (sent.isEmpty && rows.length < _batch) return;
    }
  }

  Future<void> pull(String name) async {
    final info = _table(name);
    final cols = {for (final c in info.$columns) c.name: c};
    final key = 'cursor:$name';
    final stored = await db.meta(key);
    var cursor = stored == null ? null : SyncCursor.parse(stored);
    if (cursor != null) {
      final back = DateTime.parse(cursor.at).toUtc().subtract(overlap);
      cursor = SyncCursor(back.toIso8601String(), '');
    }
    while (true) {
      final rows = await remote.changedSince(name, cursor, _batch);
      if (rows.isEmpty) return;
      await db.transaction(() async {
        for (final r in rows) {
          try {
            await mergeRow(name, cols, r);
          } on Object {
            failures++;
          }
        }
      });
      final last = rows.last;
      cursor = SyncCursor(SyncCursor.normalize(last['server_updated_at'] as String), last['id'] as String);
      await db.setMeta(key, cursor.toString());
      if (rows.length < _batch) return;
    }
  }

  /// Insert, or overwrite when the incoming row is at least as new — the
  /// same rule as the server trigger, so ties resolve the same everywhere.
  /// A local row with a newer unpushed edit wins and is pushed next round.
  Future<void> mergeRow(String name, Map<String, GeneratedColumn> cols, Map<String, dynamic> remoteRow) async {
    final names = [
      for (final k in remoteRow.keys)
        if (cols.containsKey(k) && k != 'dirty') k,
    ];
    final values = [for (final k in names) _toLocal(cols[k]!, remoteRow[k])];
    final placeholders = List.filled(names.length + 1, '?').join(', ');
    final updates = [
      for (final k in names)
        if (k != 'id') '$k = excluded.$k',
      'dirty = 0',
    ].join(', ');
    await db.customStatement(
      'INSERT INTO $name (${names.join(', ')}, dirty) VALUES ($placeholders) '
      'ON CONFLICT(id) DO UPDATE SET $updates '
      'WHERE julianday(excluded.updated_at) >= julianday($name.updated_at)',
      [...values, 0],
    );
  }

  static Object? _toRemote(GeneratedColumn<Object>? col, Object? v) {
    if (v == null || col == null) return v;
    if (col.type == DriftSqlType.bool) return v == 1 || v == true;
    return v;
  }

  static Object? _toLocal(GeneratedColumn<Object> col, Object? v) {
    if (v == null) return null;
    switch (col.type) {
      case DriftSqlType.bool:
        return v == true || v == 1 ? 1 : 0;
      case DriftSqlType.dateTime:
        // Store as drift does (UTC ISO-8601) so lexical and julianday
        // comparisons agree with locally written rows.
        return DateTime.parse(v.toString()).toUtc().toIso8601String();
      default:
        return v;
    }
  }
}

class SyncEngine extends Notifier<SyncStatus> {
  static bool get configured => _url.isNotEmpty && _anonKey.isNotEmpty;

  static Future<void> initialize() async {
    if (!configured) return;
    await Supabase.initialize(url: _url, publishableKey: _anonKey);
  }

  Timer? _debounce;
  bool _running = false;
  bool _again = false;
  StreamSubscription<AuthState>? _authSub;

  GoTrueClient get _auth => Supabase.instance.client.auth;

  @override
  SyncStatus build() {
    ref.onDispose(() {
      _debounce?.cancel();
      _authSub?.cancel();
    });
    if (!configured) return const SyncStatus(SyncPhase.disabled);
    _authSub = _auth.onAuthStateChange.listen((s) {
      final user = s.session?.user;
      if (user == null) {
        state = const SyncStatus(SyncPhase.signedOut);
      } else {
        state = state.copyWith(phase: SyncPhase.idle, email: user.email);
        if (s.event == AuthChangeEvent.signedIn) unawaited(syncNow());
      }
    });
    final user = _auth.currentUser;
    return user == null ? const SyncStatus(SyncPhase.signedOut) : SyncStatus(SyncPhase.idle, email: user.email);
  }

  /// Called after local writes; batches bursts into one push.
  void schedule() {
    if (state.phase == SyncPhase.disabled || state.phase == SyncPhase.signedOut) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), syncNow);
  }

  Future<void> syncNow() async {
    if (!configured || _auth.currentUser == null) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    var failures = 0;
    state = state.copyWith(phase: SyncPhase.syncing);
    try {
      do {
        _again = false;
        final db = ref.read(databaseProvider);
        final core = SyncCore(db, SupabaseRemote());
        await core.run();
        await AttachmentStore(Ledger(db)).sync(Supabase.instance.client);
        failures = core.failures;
      } while (_again);
      state = failures == 0
          ? state.copyWith(phase: SyncPhase.idle, lastSynced: clock.now())
          : state.copyWith(
              phase: SyncPhase.error,
              lastSynced: clock.now(),
              message: '$failures item${failures == 1 ? '' : 's'} couldn’t sync; retrying next time.',
            );
    } on AccountMismatch catch (e) {
      state = state.copyWith(phase: SyncPhase.error, message: e.toString());
    } on Object catch (e) {
      state = state.copyWith(phase: SyncPhase.error, message: e.toString());
    } finally {
      _running = false;
    }
  }

  /// Wipes this device and restores it: defaults re-seeded, then (when
  /// signed in) everything pulled back from the cloud. Waits for any sync in
  /// flight so a pull can't write a cursor after the wipe.
  Future<void> resetLocal() async {
    while (_running) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _running = true;
    try {
      final db = ref.read(databaseProvider);
      await Ledger(db).wipe();
      await seedDefaults(db);
    } finally {
      _running = false;
    }
    await syncNow();
  }

  Future<String?> signIn(String email, String password) async {
    try {
      await _auth.signInWithPassword(email: email, password: password);
      return null;
    } on AuthException catch (e) {
      return e.message;
    } on Object catch (e) {
      // Network or platform failures must reach the screen too, not leave
      // the button spinning.
      return 'Couldn’t reach the sync server: $e';
    }
  }

  Future<String?> signUp(String email, String password) async {
    try {
      final r = await _auth.signUp(email: email, password: password);
      return r.session == null ? 'Check your inbox to confirm, then sign in.' : null;
    } on AuthException catch (e) {
      return e.message;
    } on Object catch (e) {
      // Network or platform failures must reach the screen too, not leave
      // the button spinning.
      return 'Couldn’t reach the sync server: $e';
    }
  }

  Future<void> signOut() => _auth.signOut();
}

final syncEngineProvider = NotifierProvider<SyncEngine, SyncStatus>(SyncEngine.new);
