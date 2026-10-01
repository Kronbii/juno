// The real provider, end to end: receipt reading, a monthly read, and an
// assistant question answered through the on-device tools.
//   JUNO_AI_KEY=… [JUNO_AI_PROVIDER=openai] flutter test test/ai_live_test.dart --run-skipped
// Costs a fraction of a cent. Tagged so normal runs skip it.
@Tags(['ai-live'])
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/demo.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/features/assistant/assistant.dart';
import 'package:juno/features/assistant/assistant_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final key = Platform.environment['JUNO_AI_KEY'] ?? '';
  final provider = AiProvider.values.firstWhere(
    (p) => p.name == (Platform.environment['JUNO_AI_PROVIDER'] ?? 'openai'),
  );
  final now = DateTime(2026, 9, 18, 14);
  late AiAssist ai;

  setUp(() async {
    SharedPreferences.setMockInitialValues({AiAssist.providerPref: provider.name, AiAssist.keyPrefFor(provider): key});
    ai = AiAssist(await SharedPreferences.getInstance(), clock: () => now);
  });

  test('reads a messy receipt', () async {
    final r = await ai.readReceipt([
      'SPINNEYS ACHRAFIEH',
      'TVA 11%',
      'SUBTOTAL 19.60',
      'TOTAL USD 21.76',
      'CASH 30.00',
      'CHANGE 8.24',
      '28/09/2026 18:42',
    ]);
    expect(r, isNotNull, reason: 'request failed — check the key and model');
    expect(r!.total, 21.76);
    expect(r.date, '2026-09-28');
    // ignore: avoid_print, the output is the point of a live run
    print('receipt: $r · spent so far \$${(ai.spentMicros / 1e6).toStringAsFixed(5)}');
  });

  test('the assistant answers from the tools, with the right figure', () async {
    final db = AppDatabase.memory(NativeDatabase.memory());
    addTearDown(db.close);
    await seedDemo(db, now: now);
    final ledger = Ledger(db);
    final truth = await AssistantTools(ledger, clock: () => now).run('category_spending', {
      'category': 'groceries',
      'from': '2026-08-01',
      'to': '2026-08-31',
    });
    final a = Assistant(ai, ledger, clock: () => now);
    final line = await a.ask('How much did I spend on groceries in August?');
    // ignore: avoid_print, the output is the point of a live run
    print(
      'answer: ${line.text}\nlooked: ${line.looked}\ntruth: ${truth['spent']}\n'
      'cost: \$${(ai.spentMicros / 1e6).toStringAsFixed(5)} over ${ai.callsThisMonth} requests',
    );
    expect(line.failed, isFalse, reason: line.text);
    expect(line.looked, isNotEmpty, reason: 'it must look the figure up, not guess');
    final whole = (truth['spent'] as num).round().toString();
    final digits = line.text.replaceAll(',', '');
    expect(digits.contains(whole) || digits.contains((truth['spent'] as num).toStringAsFixed(2)), isTrue);
  });
}
