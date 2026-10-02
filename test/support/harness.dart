// The full app on an in-memory database, for widget tests: fonts loaded,
// demo data optional, prefs and AI client injectable.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/app/app.dart';
import 'package:juno/app/router.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/demo.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/features/settings/ai_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> loadFonts() async {
  Future<void> family(String name, String match) async {
    final l = FontLoader(name);
    for (final f in Directory('assets/fonts').listSync().whereType<File>().where((f) => f.path.contains(match))) {
      l.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await l.load();
  }

  await family('Manrope', 'Manrope');
  await family('JetBrainsMono', 'JetBrainsMono');
  await family('InstrumentSerif', 'InstrumentSerif');
}

class Harness {
  Harness(this.tester, this.db);

  final WidgetTester tester;
  final AppDatabase db;
  Ledger get ledger => Ledger(db);

  Future<void> settle([int rounds = 5]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> go(String route) async {
    router.go(route);
    await settle();
  }

  BuildContext get ctx => rootNavigatorKey.currentContext!;

  Future<void> dispose() async {
    // Close any sheet or dialog, unmount, let drift's timers fire, close.
    rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  }
}

Future<Harness> boot(
  WidgetTester tester, {
  Size size = const Size(393, 852),
  bool demo = true,
  bool onboarded = true,
  Future<void> Function(AppDatabase db)? setup,
  Map<String, Object> prefs = const {},
  AiAssist Function(SharedPreferences prefs)? ai,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'onboarded': onboarded, ...prefs});
  final sp = await SharedPreferences.getInstance();
  final db = AppDatabase.memory(NativeDatabase.memory());
  await tester.runAsync(() async {
    await db.customSelect('SELECT 1').get();
    if (demo) await seedDemo(db);
    // Setup writes happen before the app watches anything: a write while
    // the app's streams are live would queue behind queries that run in the
    // test's fake clock.
    if (setup != null) await setup(db);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        prefsProvider.overrideWithValue(sp),
        if (ai != null) aiAssistProvider.overrideWithValue(ai(sp)),
      ],
      child: const JunoApp(),
    ),
  );
  final h = Harness(tester, db);
  if (onboarded) await h.go('/home');
  return h;
}

Future<int> count(Harness h, String sql) async {
  final r = await h.tester.runAsync(() => h.db.customSelect(sql).getSingle());
  return r!.read<int>('n');
}
