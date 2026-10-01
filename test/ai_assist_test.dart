import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response reply(String? content, {int input = 1000, int output = 100, List<Object>? toolCalls}) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'role': 'assistant', 'content': content, 'tool_calls': ?toolCalls},
      },
    ],
    'usage': {'prompt_tokens': input, 'completion_tokens': output},
  }),
  200,
);

class FakeCloud implements AiCloud {
  FakeCloud({this.available = true, this.reachable = true});

  @override
  bool available;
  bool reachable;

  static final url = Uri.parse('https://proj.supabase.co/functions/v1/ai');

  @override
  Future<(Uri, Map<String, String>)?> endpoint() async =>
      reachable ? (url, {'Authorization': 'Bearer user-jwt', 'apikey': 'pub'}) : null;
}

http.Response relay(String content, {int spent = 1234, int cap = 2000000, int status = 200}) => http.Response.bytes(
  utf8.encode(
    jsonEncode(
      status == 200
          ? {
              'model': 'gpt-5-mini-2025-08-07',
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': content},
                },
              ],
            }
          : {
              'error': {'code': 'cap'},
            },
    ),
  ),
  status,
  headers: {'x-juno-spent-micros': '$spent', 'x-juno-cap-micros': '$cap'},
);

Future<AiAssist> make(Map<String, Object> prefs, Future<http.Response> Function(http.Request) handler) async {
  SharedPreferences.setMockInitialValues(prefs);
  return AiAssist(await SharedPreferences.getInstance(), client: MockClient(handler));
}

void main() {
  test('off without a key: no request is ever made', () async {
    var calls = 0;
    final ai = await make({}, (_) async {
      calls++;
      return reply('x');
    });
    expect(ai.enabled, isFalse);
    expect(await ai.summarize(r'Spent $100'), isNull);
    expect(calls, 0);
  });

  test('OpenAI: gpt-5-mini by default with reasoning parameters; parses receipt JSON', () async {
    late http.Request req;
    final ai = await make({'ai.key': 'sk-test'}, (r) async {
      req = r;
      return reply('Sure: {"total": 21.76, "currency": "USD", "date": "2026-09-28", "merchant": "Spinneys"}');
    });
    final r = await ai.readReceipt(['SPINNEYS', 'TOTAL 21.76']);
    expect(r!.total, 21.76);
    expect(r.merchant, 'Spinneys');
    final sent = jsonDecode(req.body) as Map<String, dynamic>;
    expect(req.url.toString(), 'https://api.openai.com/v1/chat/completions');
    expect(req.headers['Authorization'], 'Bearer sk-test');
    expect(sent['model'], 'gpt-5-mini');
    expect(sent['reasoning_effort'], 'minimal');
    expect(sent.containsKey('max_tokens'), isFalse, reason: 'reasoning models reject max_tokens');
    expect(sent.containsKey('temperature'), isFalse, reason: 'reasoning models reject temperature');
    expect(((sent['messages'] as List).last as Map)['content'], 'SPINNEYS\nTOTAL 21.76');
    expect(ai.callsThisMonth, 1);
  });

  test('other providers: their own URL, key and model, classic parameters', () async {
    final seen = <String, Map<String, dynamic>>{};
    for (final p in AiProvider.values.where((p) => p != AiProvider.openai)) {
      late http.Request req;
      final ai = await make({'ai.provider': p.name, AiAssist.keyPrefFor(p): 'k-${p.name}'}, (r) async {
        req = r;
        return reply('ok');
      });
      expect(await ai.summarize('x'), 'ok');
      expect(req.url.toString(), p.url);
      expect(req.headers['Authorization'], 'Bearer k-${p.name}');
      seen[p.name] = jsonDecode(req.body) as Map<String, dynamic>;
      expect(seen[p.name]!['model'], p.defaultModel);
      expect(seen[p.name]!['max_tokens'], 300);
      expect(seen[p.name]!.containsKey('reasoning_effort'), isFalse);
    }
    expect(seen.length, 5);
  });

  test('a custom model is used, and an OpenAI key does not leak to another provider', () async {
    final ai = await make({
      'ai.key': 'sk-openai',
      'ai.provider': 'deepseek',
      'ai.model.deepseek': 'deepseek-v4-pro',
    }, (_) async => reply('ok'));
    expect(ai.enabled, isFalse, reason: 'DeepSeek has no key of its own');
    expect(ai.model, 'deepseek-v4-pro');
  });

  test('spend is measured from reported tokens, and the dollar cap stops calls', () async {
    var calls = 0;
    // $0.01 budget. Each reply: 10k in × $0.25/M + 2k out × $2/M = $0.0065.
    final ai = await make({'ai.key': 'sk', AiAssist.budgetPref: 1}, (_) async {
      calls++;
      return reply('ok', input: 10000, output: 2000);
    });
    expect(await ai.summarize('a'), 'ok');
    expect(ai.spentMicros, 6500);
    expect(ai.capped, isFalse);
    expect(await ai.summarize('b'), 'ok');
    expect(ai.capped, isTrue);
    expect(await ai.summarize('c'), isNull);
    expect(calls, 2);
  });

  test('cached input is billed at a tenth on OpenAI', () async {
    final ai = await make({'ai.key': 'sk'}, (_) async => reply('ok'));
    expect(ai.costMicros(10000, 0), 2500);
    expect(ai.costMicros(10000, 0, cached: 8000), 500 + 200);
    expect(ai.costMicros(10000, 0, cached: 50000), 250, reason: 'cached never exceeds input');
  });

  test('a model that rejects reasoning_effort is retried once without it', () async {
    final bodies = <Map<String, dynamic>>[];
    final ai = await make({'ai.key': 'sk', 'ai.model.openai': 'gpt-5.6-mini'}, (r) async {
      bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
      if (bodies.length == 1) return http.Response('{"error":{"param":"reasoning_effort"}}', 400);
      return reply('ok');
    });
    expect(await ai.summarize('x'), 'ok');
    expect(bodies.length, 2);
    expect(bodies.first['reasoning_effort'], 'low');
    expect(bodies.last.containsKey('reasoning_effort'), isFalse);
  });

  test('tool calls are parsed; bad JSON arguments become null, not a crash', () async {
    final ai = await make(
      {'ai.key': 'sk'},
      (_) async => reply(
        null,
        toolCalls: [
          {
            'id': 'c1',
            'type': 'function',
            'function': {'name': 'summary', 'arguments': '{"from":"2026-09-01"}'},
          },
          {
            'id': 'c2',
            'type': 'function',
            'function': {'name': 'goals', 'arguments': '{oops'},
          },
        ],
      ),
    );
    final r = await ai.chat([
      {'role': 'user', 'content': 'hi'},
    ], tools: const []);
    expect(r!.toolCalls.map((c) => c.name), ['summary', 'goals']);
    expect(r.toolCalls.first.args, {'from': '2026-09-01'});
    expect(r.toolCalls.last.args, isNull);
    expect(r.message['tool_calls'], isNotNull, reason: 'kept for the history');
  });

  test('errors and quota responses never throw; a timeout still counts toward the cap', () async {
    final ai = await make({'ai.key': 'sk'}, (_) async => http.Response('{"error":{"code":"insufficient_quota"}}', 429));
    expect(await ai.summarize('x'), isNull);
    expect(await ai.readReceipt(['x']), isNull);
    expect(ai.spentMicros, 0, reason: 'a rejected request is not billed');

    final slow = await make({'ai.key': 'sk'}, (_) async => throw http.ClientException('offline'));
    expect(await slow.summarize('x'), isNull);
    expect(slow.spentMicros, greaterThan(0));
  });

  test('replies are read as UTF-8 even without a charset (Arabic, dashes)', () async {
    const text = r'صرفت ٤٠$ على المطاعم — أقل من الشهر الماضي';
    final ai = await make(
      {'ai.key': 'sk'},
      (_) async => http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': text},
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    expect(await ai.summarize('x'), text);
  });

  test('the month rolls over', () async {
    SharedPreferences.setMockInitialValues({'ai.key': 'sk'});
    final prefs = await SharedPreferences.getInstance();
    var now = DateTime(2026, 9, 30);
    final ai = AiAssist(prefs, client: MockClient((_) async => reply('ok')), clock: () => now);
    await ai.summarize('x');
    expect(ai.spentMicros, greaterThan(0));
    now = DateTime(2026, 10, 2);
    expect(ai.spentMicros, 0);
    expect(ai.callsThisMonth, 0);
  });

  group('Juno cloud', () {
    Future<AiAssist> cloudAi(
      Map<String, Object> prefs,
      Future<http.Response> Function(http.Request) handler, {
      FakeCloud? cloud,
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      return AiAssist(await SharedPreferences.getInstance(), client: MockClient(handler), cloud: cloud ?? FakeCloud());
    }

    test('signed in with no key of your own: works through the relay, never sends a key', () async {
      late http.Request req;
      final ai = await cloudAi({}, (r) async {
        req = r;
        return relay('ok');
      });
      expect(ai.enabled, isTrue);
      expect(ai.usingCloud, isTrue);
      expect(ai.sourceLabel, 'Juno cloud');
      expect(await ai.summarize('facts'), 'ok');
      expect(req.url, FakeCloud.url);
      expect(req.headers['Authorization'], 'Bearer user-jwt');
      final sent = jsonDecode(req.body) as Map<String, dynamic>;
      expect(sent.keys.toSet(), {'messages', 'max_output'}, reason: 'the relay picks the model and holds the key');
      expect(sent['max_output'], 300);
    });

    test("the relay's spend and cap are mirrored for display, and its cap stops calls", () async {
      var calls = 0;
      final ai = await cloudAi({}, (_) async {
        calls++;
        return calls == 1 ? relay('ok', spent: 1500000) : relay('', spent: 2000000, status: 429);
      });
      expect(await ai.summarize('a'), 'ok');
      expect(ai.spentMicros, 1500000);
      expect(ai.budgetCents, 200);
      expect(ai.model, 'gpt-5-mini-2025-08-07');
      expect(ai.capped, isFalse);
      expect(await ai.summarize('b'), isNull);
      expect(ai.capped, isTrue);
      expect(await ai.summarize('c'), isNull);
      expect(calls, 2, reason: 'nothing more is sent once the relay says the cap is reached');
    });

    test('your own key takes precedence over the relay', () async {
      late http.Request req;
      final ai = await cloudAi({'ai.key': 'sk-own'}, (r) async {
        req = r;
        return reply('mine');
      });
      expect(ai.usingCloud, isFalse);
      expect(await ai.summarize('x'), 'mine');
      expect(req.url.host, 'api.openai.com');
    });

    test('signed out, or session unavailable: off and silent', () async {
      var calls = 0;
      Future<http.Response> h(http.Request _) async {
        calls++;
        return relay('x');
      }

      final out = await cloudAi({}, h, cloud: FakeCloud(available: false));
      expect(out.enabled, isFalse);
      expect(await out.summarize('x'), isNull);
      final stale = await cloudAi({}, h, cloud: FakeCloud(reachable: false));
      expect(await stale.summarize('x'), isNull);
      expect(calls, 0);
    });

    test('relay errors never throw', () async {
      final ai = await cloudAi({}, (_) async => http.Response('<html>bad gateway</html>', 502));
      expect(await ai.summarize('x'), isNull);
      final down = await cloudAi({}, (_) async => throw http.ClientException('offline'));
      expect(await down.summarize('x'), isNull);
    });
  });
}
