import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/attachments/attachment_store.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase project, passed at build time:
/// `flutter run --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…`
/// (or `--dart-define-from-file=supabase.json`). Without them Juno runs
/// local-only and the sync UI says so.
const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

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

  /// Rows changed on the server after [cursor] (`server_updated_at`),
  /// oldest first, at most [limit].
  Future<List<Map<String, dynamic>>> changedSince(String table, String? cursor, int limit);
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
  Future<List<Map<String, dynamic>>> changedSince(String table, String? cursor, int limit) async {
    var q = _c.from(table).select();
    if (cursor != null) q = q.gt('server_updated_at', cursor);
    final res = await q.order('server_updated_at').limit(limit);
    return List<Map<String, dynamic>>.from(res);
  }
}

/// Local-first sync: every table is pushed (dirty rows) then pulled
/// (server changes since the last cursor). Conflicts resolve last-write-wins
/// on the row's `updated_at`; deletes are soft so they travel like edits.
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

  Future<void> run() async {
    final uid = remote.userId;
    if (uid == null) return;
    for (final t in tables) {
      await push(t, uid);
    }
    for (final t in tables) {
      await pull(t);
    }
  }

  Future<void> push(String name, String uid) async {
    final info = _table(name);
    final cols = {for (final c in info.$columns) c.name: c};
    while (true) {
      final rows = await db.customSelect('SELECT * FROM $name WHERE dirty = 1 LIMIT $_batch').get();
      if (rows.isEmpty) return;
      final payload = [
        for (final r in rows)
          {
            for (final e in r.data.entries)
              if (e.key != 'dirty') e.key: _toRemote(cols[e.key], e.value),
            'user_id': uid,
          },
      ];
      await remote.upsert(name, payload);
      // Clear dirty only if the row wasn't edited again while we pushed.
      await db.transaction(() async {
        for (final r in rows) {
          await db.customStatement(
            'UPDATE $name SET dirty = 0, user_id = ? WHERE id = ? AND updated_at = ?',
            [uid, r.data['id'], r.data['updated_at']],
          );
        }
      });
      if (rows.length < _batch) return;
    }
  }

  Future<void> pull(String name) async {
    final info = _table(name);
    final cols = {for (final c in info.$columns) c.name: c};
    final key = 'cursor:$name';
    var cursor = await db.meta(key);
    while (true) {
      final rows = await remote.changedSince(name, cursor, _batch);
      if (rows.isEmpty) return;
      await db.transaction(() async {
        for (final r in rows) {
          await mergeRow(name, cols, r);
        }
      });
      cursor = rows.last['server_updated_at'] as String?;
      if (cursor != null) await db.setMeta(key, cursor);
      if (rows.length < _batch) return;
    }
  }

  /// Insert, or overwrite only when the incoming row is newer. A local row
  /// with unpushed edits that is newer wins and will be pushed next round.
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
      'WHERE julianday(excluded.updated_at) > julianday($name.updated_at)',
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
    state = state.copyWith(phase: SyncPhase.syncing);
    try {
      do {
        _again = false;
        final db = ref.read(databaseProvider);
        final core = SyncCore(db, SupabaseRemote());
        await core.run();
        // Receipt files follow their rows; marking uploads dirties rows, so
        // push once more to tell other devices the files are there.
        await AttachmentStore(Ledger(db)).sync(Supabase.instance.client);
        await core.run();
      } while (_again);
      state = state.copyWith(phase: SyncPhase.idle, lastSynced: DateTime.now());
    } on Object catch (e) {
      state = state.copyWith(phase: SyncPhase.error, message: e.toString());
    } finally {
      _running = false;
    }
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
