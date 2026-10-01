// Renders every main screen at phone and desktop sizes, light and dark, to
// PNGs for visual review:
//
//   flutter test test/screenshots_test.dart --update-goldens --tags shots
//
// Output lands in test/goldens/. Tagged so a normal `flutter test` skips it.
@Tags(['shots'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juno/app/app.dart';
import 'package:juno/app/router.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/demo.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/features/add/entry_sheet.dart';
import 'package:juno/features/settings/ai_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await loader.load();
  }

  final fonts = Directory('assets/fonts').listSync().whereType<File>().map((f) => f.path).toList();
  await family('Manrope', fonts.where((f) => f.contains('Manrope')).toList());
  await family('JetBrainsMono', fonts.where((f) => f.contains('JetBrainsMono')).toList());
  await family('InstrumentSerif', fonts.where((f) => f.contains('InstrumentSerif')).toList());

  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) await family('MaterialIcons', [icons.path]);
}

/// Plays one tool call, then a canned answer.
MockClient _scripted() {
  var n = 0;
  return MockClient((_) async {
    final message = (n++).isEven
        ? {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'c$n',
                'type': 'function',
                'function': {'name': 'safe_to_spend', 'arguments': '{}'},
              },
            ],
          }
        : {
            'role': 'assistant',
            'content':
                r'You have about $1,480 left for the rest of September — roughly $114 a day over 13 days, once '
                r'the $320 of bills still due are paid. At your current pace you would finish the month around '
                r'$2,900, a little under what came in.',
          };
    return http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'choices': [
            {'message': message},
          ],
        }),
      ),
      200,
    );
  });
}

void main() {
  setUpAll(_loadFonts);

  const sizes = {'phone': Size(393, 852), 'desktop': Size(1440, 920)};
  const routes = ['/home', '/activity', '/insights', '/plan', '/settings', '/insights/review', '/settings/backups'];

  for (final s in sizes.entries) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('${s.key} ${mode.name}', (tester) async {
        tester.view.physicalSize = s.value * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);

        SharedPreferences.setMockInitialValues({'themeMode': mode.name, 'onboarded': true, 'ai.key': 'sk-demo'});
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase.memory(NativeDatabase.memory());
        await tester.runAsync(() async {
          await db.customSelect('SELECT 1').get(); // triggers onCreate + seed
          await seedDemo(db);
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              prefsProvider.overrideWithValue(prefs),
              aiAssistProvider.overrideWithValue(AiAssist(prefs, client: _scripted())),
            ],
            child: const JunoApp(),
          ),
        );

        Future<void> settle() async {
          for (var i = 0; i < 6; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
            await tester.pump(const Duration(milliseconds: 400));
          }
        }

        for (final r in routes) {
          router.go(r);
          await settle();
          await expectLater(
            find.byType(JunoApp),
            matchesGoldenFile('goldens/${s.key}-${mode.name}${r.replaceAll('/', '-')}.png'),
          );
        }

        router.go('/assistant');
        await settle();
        await tester.tap(find.text('What can I still spend this month?'));
        await settle();
        await expectLater(find.byType(JunoApp), matchesGoldenFile('goldens/${s.key}-${mode.name}-assistant.png'));

        router.go('/home');
        await settle();
        unawaited(showEntrySheet(rootNavigatorKey.currentContext!));
        await settle();
        await expectLater(find.byType(JunoApp), matchesGoldenFile('goldens/${s.key}-${mode.name}-add.png'));
        rootNavigatorKey.currentState!.pop();
        await settle();

        // Unmount, then let drift's stream-teardown timers fire before close.
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
      });
    }
  }
}
