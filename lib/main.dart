import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/app/app.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final db = AppDatabase();
  await SyncEngine.initialize();

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        prefsProvider.overrideWithValue(prefs),
      ],
      child: const JunoApp(),
    ),
  );
}
