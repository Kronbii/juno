import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A picked file not yet saved (the entry it belongs to may not exist yet).
class PendingFile {
  const PendingFile({required this.name, required this.mime, required this.bytes});

  final String name;
  final String mime;
  final Uint8List bytes;
}

enum PickSource { camera, library, files }

/// Receipts on disk and in Supabase Storage. Both locations derive from the
/// attachment id, so the synced row carries nothing device-specific:
///   local:  `<app support>/attachments/<id><ext>`
///   remote: `receipts/<user id>/<id><ext>`
class AttachmentStore {
  AttachmentStore(this.ledger);

  final Ledger ledger;
  static const bucket = 'receipts';

  static Directory? _dir;

  /// Points the store at a folder (tests).
  @visibleForTesting
  // ignore: avoid_setters_without_getters, test-only override; read via dir().
  static set directory(Directory d) => _dir = d;

  static Future<Directory> dir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    return _dir = await Directory(p.join(base.path, 'attachments')).create(recursive: true);
  }

  static String _ext(String name) {
    final e = p.extension(name).toLowerCase();
    return e.isEmpty ? '.jpg' : e;
  }

  static Future<File> fileFor(Attachment a) async => File(p.join((await dir()).path, '${a.id}${_ext(a.fileName)}'));

  static bool get canUseCamera => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  /// Shows the platform picker. Null when cancelled.
  static Future<PendingFile?> pick(PickSource source) async {
    if (source == PickSource.files || !canUseCamera) {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Attach a receipt',
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'heic', 'webp'],
      );
      if (files.isEmpty) return null;
      final f = files.first;
      return PendingFile(name: f.name, mime: _mimeOf(f.name), bytes: await f.readAsBytes());
    }
    final x = await ImagePicker().pickImage(
      source: source == PickSource.camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 2000,
      imageQuality: 82,
    );
    if (x == null) return null;
    return PendingFile(name: x.name, mime: _mimeOf(x.name), bytes: await x.readAsBytes());
  }

  static String _mimeOf(String name) => switch (p.extension(name).toLowerCase()) {
    '.png' => 'image/png',
    '.heic' => 'image/heic',
    '.webp' => 'image/webp',
    _ => 'image/jpeg',
  };

  Future<String> save(String transactionId, PendingFile f) async {
    final id = newId();
    final file = File(p.join((await dir()).path, '$id${_ext(f.name)}'));
    await file.writeAsBytes(f.bytes, flush: true);
    return ledger.addAttachment(
      AttachmentsCompanion.insert(
        id: Value(id),
        transactionId: transactionId,
        fileName: f.name,
        mime: f.mime,
        sizeBytes: f.bytes.length,
      ),
    );
  }

  /// Uploads local files the cloud lacks and downloads files other devices
  /// added. Called by the sync engine after rows are in step.
  Future<void> sync(SupabaseClient client) async {
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;
    final storage = client.storage.from(bucket);

    for (final a in await ledger.attachmentsWhere(uploaded: false)) {
      final f = await fileFor(a);
      if (!f.existsSync()) continue;
      await storage.uploadBinary(
        '$uid/${a.id}${_ext(a.fileName)}',
        await f.readAsBytes(),
        fileOptions: FileOptions(contentType: a.mime, upsert: true),
      );
      await ledger.markUploaded(a.id);
    }
    for (final a in await ledger.attachmentsWhere(uploaded: true)) {
      final f = await fileFor(a);
      if (f.existsSync()) continue;
      try {
        await f.writeAsBytes(await storage.download('$uid/${a.id}${_ext(a.fileName)}'), flush: true);
      } on StorageException {
        // Not there yet (the other device may still be uploading); next sync.
      }
    }
  }
}
