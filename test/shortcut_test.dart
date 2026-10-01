import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/app/app.dart';
import 'package:juno/app/router.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/features/add/entry_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('N opens a new entry, but not while typing in a field', (tester) async {
    tester.view.physicalSize = const Size(1440, 920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.memory(NativeDatabase.memory());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db), prefsProvider.overrideWithValue(prefs)],
        child: const JunoApp(),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    router.go('/activity');
    await settle();

    // Typing "n" into the search field types an n.
    await tester.tap(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, 'n');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await settle();
    expect(find.byType(EntrySheet), findsNothing);

    // With nothing focused, N opens the sheet.
    FocusManager.instance.primaryFocus?.unfocus();
    await settle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await settle();
    expect(find.byType(EntrySheet), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  });
}
