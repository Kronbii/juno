import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/sync/sync_engine.dart' show SyncCore;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class BackupFile {
  const BackupFile(this.file, this.at, this.bytes);

  final File file;
  final DateTime at;
  final int bytes;
}

/// Automatic local backups: a consistent SQLite snapshot (`VACUUM INTO`)
/// at most once a day, the newest [keep] kept. Restoring *merges*: rows
/// missing here or newer in the backup come back (and sync); nothing newer
/// on this device is overwritten.
class Backups {
  Backups(this.db, {Directory? dir}) : _dir = dir;

  final AppDatabase db;
  Directory? _dir;
  static const keep = 14;

  Future<Directory> dir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    return _dir = await Directory(p.join(base.path, 'backups')).create(recursive: true);
  }

  Future<List<BackupFile>> list() async {
    final d = await dir();
    final files = d.listSync().whereType<File>().where((f) => f.path.endsWith('.sqlite')).toList();
    final out = [for (final f in files) BackupFile(f, f.lastModifiedSync(), f.lengthSync())]
      ..sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  /// Takes a snapshot now. Returns the file.
  Future<File> snapshot() async {
    final d = await dir();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'juno-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}-${now.millisecond.toString().padLeft(3, '0')}.sqlite';
    final file = File(p.join(d.path, name));
    if (file.existsSync()) file.deleteSync();
    await db.customStatement('VACUUM INTO ?', [file.path]);
    await _prune();
    return file;
  }

  /// Daily backup: only when the newest one is older than [every].
  Future<File?> snapshotIfDue({Duration every = const Duration(hours: 20)}) async {
    final existing = await list();
    if (existing.isNotEmpty && DateTime.now().difference(existing.first.at) < every) return null;
    return snapshot();
  }

  Future<void> _prune() async {
    final all = await list();
    for (final b in all.skip(keep)) {
      b.file.deleteSync();
    }
  }

  /// Merges a backup into the live database. Returns rows restored/updated.
  Future<int> restore(File backup) async {
    // Work on a copy: opening runs migrations, which must not touch the
    // backup itself.
    final tmp = File('${backup.path}.restore-${DateTime.now().microsecondsSinceEpoch}');
    await backup.copy(tmp.path);
    final source = AppDatabase.memory(NativeDatabase(tmp));
    var changed = 0;
    try {
      for (final table in SyncCore.tables) {
        final rows = await source.customSelect('SELECT * FROM $table').get();
        final info = db.allTables.firstWhere((t) => t.actualTableName == table);
        final cols = {for (final c in info.$columns) c.name};
        for (final r in rows) {
          final names = [
            for (final k in r.data.keys)
              if (cols.contains(k) && k != 'dirty') k,
          ];
          await db.customStatement(
            'INSERT INTO $table (${names.join(', ')}, dirty) VALUES (${List.filled(names.length + 1, '?').join(', ')}) '
            'ON CONFLICT(id) DO UPDATE SET ${[for (final k in names)
              if (k != 'id') '$k = excluded.$k', 'dirty = 1'].join(', ')} '
            'WHERE julianday(excluded.updated_at) > julianday($table.updated_at)',
            [for (final k in names) r.data[k], 1],
          );
          final after = await db.customSelect('SELECT changes() AS n').getSingle();
          if (after.read<int>('n') > 0) changed++;
        }
      }
      // Wake every stream so screens show the restored data.
      db.notifyUpdates({for (final t in db.allTables) TableUpdate.onTable(t)});
    } finally {
      await source.close();
      if (tmp.existsSync()) tmp.deleteSync();
    }
    return changed;
  }
}
