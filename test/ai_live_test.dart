// The real provider, end to end: receipt reading, a monthly read, and an
// assistant question answered through the on-device tools.
//   JUNO_AI_KEY=… [JUNO_AI_PROVIDER=openai] flutter test test/ai_live_test.dart --run-skipped
// And Juno's cloud relay (the deployed `ai` edge function), signed in:
//   SUPABASE_URL=… SUPABASE_ANON_KEY=… JUNO_LIVE_EMAIL=… JUNO_LIVE_PASSWORD=… \
//     flutter test test/ai_live_test.dart --run-skipped --plain-name relay
// Costs a fraction of a cent. Tagged so normal runs skip it.
@Tags(['ai-live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/demo.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/features/assistant/assistant.dart';
import 'package:juno/features/assistant/assistant_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The relay with a session from a password sign-in.
class _EnvCloud implements AiCloud {
  _EnvCloud(this.url, this.anon, this.token);

  final String url;
  final String anon;
  final String token;

  @override
  bool get available => true;

  @override
  Future<(Uri, Map<String, String>)?> endpoint() async =>
      (Uri.parse('$url/functions/v1/ai'), {'Authorization': 'Bearer $token', 'apikey': anon});
}

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

  test('the assistant drafts entries from plain words (LBP, household, yesterday) without saving', () async {
    final db = AppDatabase.memory(NativeDatabase.memory());
    addTearDown(db.close);
    await seedDemo(db, now: now);
    final ledger = Ledger(db);
    final before = (await db.customSelect('SELECT COUNT(*) AS n FROM transactions').getSingle()).read<int>('n');
    final a = Assistant(ai, ledger, clock: () => now);
    final line = await a.ask('log 12 dollars coffee, and 450k taxi yesterday, and 40 groceries for the house');
    // ignore: avoid_print, the output is the point of a live run
    print(
      'drafts: ${line.text}\n${[for (final d in line.drafts) '${d.type.name} ${d.amountCents} ${d.currency} ${d.scope.name} ${d.day} ${d.note}'].join('\n')}',
    );
    expect(line.failed, isFalse, reason: line.text);
    expect(line.drafts.length, 3);
    final lbp = line.drafts.where((d) => d.currency == 'LBP').single;
    expect(lbp.amountCents, 45000000);
    expect(lbp.day, '2026-09-17');
    // "…and 40 groceries for the house" is its own item: today. (The coffee
    // before "taxi yesterday" is ambiguous; the card shows its date.)
    expect(line.drafts.firstWhere((d) => d.amountCents == 4000).day, '2026-09-18', reason: '"yesterday" was the taxi');
    expect(line.drafts.where((d) => d.currency == 'USD').map((d) => d.amountCents).toSet(), {1200, 4000});
    expect(line.drafts.firstWhere((d) => d.amountCents == 4000).scope, Scope.household);
    final after = (await db.customSelect('SELECT COUNT(*) AS n FROM transactions').getSingle()).read<int>('n');
    expect(after, before, reason: 'nothing is saved until Log');
  });

  test('import categories from descriptions alone', () async {
    final out = await ai.categorize(
      [
        ('SPINNEYS ACHRAFIEH', false),
        ('TOTAL LIBAN STATION', false),
        ('NETFLIX.COM', false),
        ('PAYROLL ACME SAL', true),
        ('PHARMACIE MAZLOUM', false),
        ('XQZ 7781', false),
      ],
      expenseCategories: const ['Groceries', 'Fuel', 'Subscriptions', 'Health', 'Dining', 'Transport', 'Other'],
      incomeCategories: const ['Salary', 'Freelance', 'Other income'],
    );
    // ignore: avoid_print, the output is the point of a live run
    print('categorize: $out · spent \$${(ai.spentMicros / 1e6).toStringAsFixed(5)}');
    expect(out['SPINNEYS ACHRAFIEH'], 'Groceries');
    expect(out['TOTAL LIBAN STATION'], 'Fuel');
    expect(out['NETFLIX.COM'], 'Subscriptions');
    expect(out['PAYROLL ACME SAL'], 'Salary');
    expect(out['PHARMACIE MAZLOUM'], 'Health');
  });

  test('relay: signed in, no key on the device, answers and reports spend', () async {
    final env = Platform.environment;
    final url = env['SUPABASE_URL'] ?? '';
    final anon = env['SUPABASE_ANON_KEY'] ?? '';
    final signIn = await http.post(
      Uri.parse('$url/auth/v1/token?grant_type=password'),
      headers: {'apikey': anon, 'Content-Type': 'application/json'},
      body: jsonEncode({'email': env['JUNO_LIVE_EMAIL'], 'password': env['JUNO_LIVE_PASSWORD']}),
    );
    expect(signIn.statusCode, 200, reason: 'sign-in failed');
    final token = (jsonDecode(signIn.body) as Map<String, dynamic>)['access_token'] as String;

    SharedPreferences.setMockInitialValues({});
    final cloud = AiAssist(await SharedPreferences.getInstance(), cloud: _EnvCloud(url, anon, token));
    expect(cloud.usingCloud, isTrue);
    final text = await cloud.summarize(r'Spent $1,850 (+$200 vs August). Income $3,000. Dining $420 (+$150).');
    // ignore: avoid_print, the output is the point of a live run
    print(
      'relay: $text\nspent this month: \$${(cloud.spentMicros / 1e6).toStringAsFixed(5)} '
      'of \$${cloud.budgetCents / 100} · model ${cloud.model}',
    );
    expect(text, isNotNull, reason: 'relay failed — deployed? OPENAI_API_KEY secret set?');
    expect(cloud.spentMicros, greaterThan(0));

    final anonymous = await http.post(Uri.parse('$url/functions/v1/ai'), headers: {'apikey': anon}, body: '{}');
    expect(anonymous.statusCode, 401, reason: 'the relay must refuse callers who are not signed in');
  });

  group('relay, deeper', () {
    final env = Platform.environment;
    final url = env['SUPABASE_URL'] ?? '';
    final anon = env['SUPABASE_ANON_KEY'] ?? '';
    late String token;
    late String userId;

    setUpAll(() async {
      final r = await http.post(
        Uri.parse('$url/auth/v1/token?grant_type=password'),
        headers: {'apikey': anon, 'Content-Type': 'application/json'},
        body: jsonEncode({'email': env['JUNO_LIVE_EMAIL'], 'password': env['JUNO_LIVE_PASSWORD']}),
      );
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      token = j['access_token'] as String;
      userId = (j['user'] as Map<String, dynamic>)['id'] as String;
    });

    Future<AiAssist> cloudAi() async {
      SharedPreferences.setMockInitialValues({});
      return AiAssist(await SharedPreferences.getInstance(), cloud: _EnvCloud(url, anon, token), clock: () => now);
    }

    test('relay: the assistant answers through the tools, to the cent', () async {
      final db = AppDatabase.memory(NativeDatabase.memory());
      addTearDown(db.close);
      await seedDemo(db, now: now);
      final ledger = Ledger(db);
      final truth = await AssistantTools(ledger, clock: () => now).run('category_spending', {
        'category': 'groceries',
        'from': '2026-08-01',
        'to': '2026-08-31',
      });
      final ai = await cloudAi();
      final line = await Assistant(ai, ledger, clock: () => now).ask('How much did I spend on groceries in August?');
      // ignore: avoid_print, the output is the point of a live run
      print(
        'relay assistant: ${line.text} · looked ${line.looked} · truth ${truth['spent']} · '
        '\$${(ai.spentMicros / 1e6).toStringAsFixed(5)} this month on the server',
      );
      expect(line.failed, isFalse, reason: line.text);
      expect(line.looked, isNotEmpty);
      expect(line.text.replaceAll(',', ''), contains((truth['spent'] as num).toStringAsFixed(2)));
    });

    test('relay: malformed and oversized requests are refused', () async {
      Future<int> post(String body) async => (await http.post(
        Uri.parse('$url/functions/v1/ai'),
        headers: {'Authorization': 'Bearer $token', 'apikey': anon, 'Content-Type': 'application/json'},
        body: body,
      )).statusCode;
      expect(await post('{not json'), 400);
      expect(await post(jsonEncode({'messages': <Object>[]})), 400);
      expect(
        await post(
          jsonEncode({
            'messages': [
              {'role': 'hacker', 'content': 'x'},
            ],
          }),
        ),
        400,
      );
      expect(
        await post(
          jsonEncode({
            'messages': [
              {'role': 'user', 'content': 'x' * 250000},
            ],
          }),
        ),
        413,
      );
      final forged = await http.post(
        Uri.parse('$url/functions/v1/ai'),
        headers: {'Authorization': 'Bearer not-a-real-token', 'apikey': anon},
        body: jsonEncode({
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
        }),
      );
      expect(forged.statusCode, 401);
    });

    test('relay: at the monthly cap the server says no and the app falls back', () async {
      final service = env['JUNO_SERVICE_KEY'] ?? '';
      final month = DateTime.now().toUtc().toIso8601String().substring(0, 7);
      // Put this test user at the cap, as the server would after a heavy month.
      final up = await http.post(
        Uri.parse('$url/rest/v1/ai_usage'),
        headers: {
          'apikey': service,
          'Authorization': 'Bearer $service',
          'Content-Type': 'application/json',
          'Prefer': 'resolution=merge-duplicates',
        },
        body: jsonEncode({'user_id': userId, 'month': month, 'spent_micros': 2000000, 'calls': 999}),
      );
      expect(up.statusCode, anyOf(200, 201, 204), reason: up.body);
      final ai = await cloudAi();
      expect(await ai.summarize(r'Spent $10.'), isNull);
      expect(ai.capped, isTrue, reason: 'the cap the server reported is mirrored');
      expect(ai.spentMicros, 2000000);
      // A user can read their own usage, never write it.
      final self = await http.post(
        Uri.parse('$url/rest/v1/ai_usage'),
        headers: {'apikey': anon, 'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': userId, 'month': month, 'spent_micros': 0}),
      );
      expect(self.statusCode, anyOf(401, 403), reason: 'users must not reset their own spend');
    });
  });
}
