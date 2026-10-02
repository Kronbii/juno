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

/// Scripted AI: the weekly read, a month-plan answer, and a logging answer
/// with two drafts — chosen from what each request contains.
MockClient _scripted() => MockClient((req) async {
  final body = jsonDecode(req.body) as Map<String, dynamic>;
  final msgs = (body['messages'] as List).cast<Map<String, dynamic>>();
  final last = msgs.last;
  final question = msgs.lastWhere((m) => m['role'] == 'user')['content'] as String;
  final logging = question.startsWith('Log');
  Map<String, dynamic> call(String id, String name, Map<String, Object> args) => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': jsonEncode(args)},
  };
  final Map<String, Object?> message;
  if (body['tools'] == null) {
    message = {
      'role': 'assistant',
      'content':
          r'A steady start: $210 so far, a little under last week, mostly groceries. Dining is the one to '
          'watch — two more evenings out would put you above last week.',
    };
  } else if (last['role'] == 'user') {
    message = {
      'role': 'assistant',
      'content': null,
      'tool_calls': logging
          ? [
              call('c1', 'draft_entry', {'amount': 12, 'category': 'dining', 'note': 'Coffee'}),
              call('c2', 'draft_entry', {'amount': 40, 'category': 'groceries', 'note': 'Spinneys'}),
            ]
          : [call('c1', 'safe_to_spend', {})],
    };
  } else {
    message = {
      'role': 'assistant',
      'content': logging
          ? 'Prepared both — groceries go to the household. Tap Log on each to save them.'
          : r'You have about $1,480 left for the rest of the month — roughly $114 a day, once the $320 of bills '
                r'still due are paid. At your current pace you would finish around $2,900, a little under what '
                'came in.',
    };
  }
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
        await tester.tap(find.byTooltip('New conversation'));
        await settle();
        await tester.tap(find.text('Log 12 coffee and 40 groceries for the house'));
        await settle();
        await settle();
        await expectLater(find.byType(JunoApp), matchesGoldenFile('goldens/${s.key}-${mode.name}-assistant-log.png'));

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
