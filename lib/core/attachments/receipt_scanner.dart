import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:juno/features/smart/receipt_parser.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// On-device receipt reading (iOS): Google ML Kit text recognition, no
/// network. Returns null where it isn't available (desktop) or on failure.
abstract final class ReceiptScanner {
  static bool get supported => !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST') && Platform.isIOS;

  /// The recognised lines from the last [read] (for an optional AI retry).
  static List<String> lastLines = const [];

  static Future<ReceiptRead?> read(Uint8List imageBytes) async {
    if (!supported) return null;
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'juno-receipt-${clock.now().microsecondsSinceEpoch}.jpg'));
    await file.writeAsBytes(imageBytes, flush: true);
    final recognizer = TextRecognizer();
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(file.path));
      final lines = [
        for (final block in result.blocks)
          for (final line in block.lines) line.text,
      ];
      lastLines = lines;
      return parseReceipt(lines);
    } on Object {
      return null;
    } finally {
      await recognizer.close();
      if (file.existsSync()) await file.delete();
    }
  }
}
