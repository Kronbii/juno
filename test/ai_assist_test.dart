import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response reply(String content) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': content},
      },
    ],
  }),
  200,
);

void main() {
  test('off without a key: no request is ever made', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final ai = AiAssist(
      await SharedPreferences.getInstance(),
      client: MockClient((_) async {
        calls++;
        return reply('x');
      }),
    );
    expect(ai.enabled, isFalse);
    expect(await ai.summarize(r'Spent $100'), isNull);
    expect(calls, 0);
  });

  test('sends only the given text, parses receipt JSON, counts usage', () async {
    SharedPreferences.setMockInitialValues({AiAssist.keyPref: 'sk-test'});
    late Map<String, dynamic> sent;
    final ai = AiAssist(
      await SharedPreferences.getInstance(),
      client: MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        expect(req.headers['Authorization'], 'Bearer sk-test');
        return reply('Sure: {"total": 21.76, "currency": "USD", "date": "2026-09-28", "merchant": "Spinneys"}');
      }),
    );
    final r = await ai.readReceipt(['SPINNEYS', 'TOTAL 21.76']);
    expect(r!.total, 21.76);
    expect(r.merchant, 'Spinneys');
    expect(sent['max_tokens'], 300);
    expect(sent['model'], AiAssist.defaultModel);
    expect(((sent['messages'] as List).last as Map)['content'], 'SPINNEYS\nTOTAL 21.76');
    expect(ai.usedThisMonth, 1);
  });

  test('the monthly cap stops calls and falls back to null', () async {
    SharedPreferences.setMockInitialValues({AiAssist.keyPref: 'sk-test', AiAssist.capPref: 2});
    var calls = 0;
    final ai = AiAssist(
      await SharedPreferences.getInstance(),
      client: MockClient((_) async {
        calls++;
        return reply('ok');
      }),
    );
    expect(await ai.summarize('a'), 'ok');
    expect(await ai.summarize('b'), 'ok');
    expect(await ai.summarize('c'), isNull);
    expect(calls, 2);
    expect(ai.capped, isTrue);
  });

  test('errors and quota responses never throw', () async {
    SharedPreferences.setMockInitialValues({AiAssist.keyPref: 'sk-test'});
    final ai = AiAssist(
      await SharedPreferences.getInstance(),
      client: MockClient((_) async => http.Response('{"error":{"code":"insufficient_quota"}}', 429)),
    );
    expect(await ai.summarize('x'), isNull);
    expect(await ai.readReceipt(['x']), isNull);
  });
}
