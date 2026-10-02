import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// The model services Juno can talk to. All of them accept the same
/// OpenAI-style `chat/completions` request, so one client covers every one.
enum AiProvider {
  openai(
    label: 'OpenAI',
    url: 'https://api.openai.com/v1/chat/completions',
    defaultModel: 'gpt-5-mini',
    keyHint: 'sk-…',
    keysAt: 'platform.openai.com',
    inPerM: 0.25,
    outPerM: 2,
  ),
  gemini(
    label: 'Gemini',
    url: 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
    defaultModel: 'gemini-3.7-flash',
    keyHint: 'AIza…',
    keysAt: 'aistudio.google.com',
    inPerM: 1.5,
    outPerM: 7.5,
  ),
  anthropic(
    label: 'Anthropic',
    url: 'https://api.anthropic.com/v1/chat/completions',
    defaultModel: 'claude-haiku-4-5',
    keyHint: 'sk-ant-…',
    keysAt: 'console.anthropic.com',
    inPerM: 1,
    outPerM: 5,
  ),
  deepseek(
    label: 'DeepSeek',
    url: 'https://api.deepseek.com/chat/completions',
    defaultModel: 'deepseek-flash',
    keyHint: 'sk-…',
    keysAt: 'platform.deepseek.com',
    inPerM: 0.3,
    outPerM: 1.2,
    chinaBased: true,
  ),
  qwen(
    label: 'Qwen',
    url: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions',
    defaultModel: 'qwen-plus',
    keyHint: 'sk-…',
    keysAt: 'Alibaba Cloud Model Studio',
    inPerM: 0.4,
    outPerM: 1.6,
    chinaBased: true,
  ),
  kimi(
    label: 'Kimi',
    url: 'https://api.moonshot.ai/v1/chat/completions',
    defaultModel: 'kimi-k2.6',
    keyHint: 'sk-…',
    keysAt: 'platform.moonshot.ai',
    inPerM: 0.95,
    outPerM: 4,
    chinaBased: true,
  )
  ;

  const AiProvider({
    required this.label,
    required this.url,
    required this.defaultModel,
    required this.keyHint,
    required this.keysAt,
    required this.inPerM,
    required this.outPerM,
    this.chinaBased = false,
  });

  final String label;
  final String url;
  final String defaultModel;
  final String keyHint;
  final String keysAt;

  /// USD per million tokens for [defaultModel] — the higher (peak or
  /// post-promotion) rate where there are two, so the spending cap errs safe.
  final double inPerM;
  final double outPerM;
  final bool chinaBased;
}

/// A tool the model asked to run. [args] is null when it sent invalid JSON.
class AiToolCall {
  const AiToolCall(this.id, this.name, this.args);

  final String id;
  final String name;
  final Map<String, dynamic>? args;
}

/// Juno's own AI relay (a Supabase edge function holding the OpenAI key).
/// Used when you're signed in and haven't set a key of your own.
abstract class AiCloud {
  /// Signed in, so the relay will accept requests.
  bool get available;

  /// The relay's URL and auth headers, refreshing the session if needed.
  /// Null when it can't be reached right now.
  Future<(Uri, Map<String, String>)?> endpoint();
}

class AiReply {
  const AiReply(this.message, this.text, this.toolCalls);

  /// The assistant message exactly as returned, for the conversation history.
  final Map<String, dynamic> message;
  final String? text;
  final List<AiToolCall> toolCalls;
}

/// AI help, through Juno's cloud relay when you're signed in, or through a
/// key of your own set on this device (which then takes precedence).
///
/// Guard rails:
/// * a monthly spending cap in dollars (default $2), measured from the token
///   counts each reply reports — enforced by the relay for cloud requests and
///   here for your own key; at the cap every call returns null and the
///   on-device result is used;
/// * short prompts, capped output, a small model by default;
/// * callers send only what's needed (see each feature);
/// * every failure (offline, bad key, quota) returns null — the app never
///   depends on it.
///
/// Note: ChatGPT Plus does not include API access; the key needs API billing.
class AiAssist {
  AiAssist(this.prefs, {http.Client? client, DateTime Function()? clock, this.cloud})
    : _client = client ?? http.Client(),
      _clock = clock ?? DateTime.now;

  final SharedPreferences prefs;
  final AiCloud? cloud;
  final http.Client _client;
  final DateTime Function() _clock;

  static const providerPref = 'ai.provider';
  static const budgetPref = 'ai.budget.cents';
  static const defaultBudgetCents = 200;

  /// The OpenAI key keeps its original name so existing setups carry over.
  static String keyPrefFor(AiProvider p) => p == AiProvider.openai ? 'ai.key' : 'ai.key.${p.name}';
  static String modelPrefFor(AiProvider p) => 'ai.model.${p.name}';

  /// The provider chosen for your own key.
  AiProvider get chosenProvider =>
      AiProvider.values.where((p) => p.name == prefs.getString(providerPref)).firstOrNull ?? AiProvider.openai;

  /// Your own key for [chosenProvider], if set.
  String? get apiKey {
    final k = prefs.getString(keyPrefFor(chosenProvider))?.trim();
    return k == null || k.isEmpty ? null : k;
  }

  /// Going through Juno's relay rather than your own key.
  bool get usingCloud => apiKey == null && (cloud?.available ?? false);

  bool get enabled => apiKey != null || usingCloud;

  /// Who answers: the relay always uses OpenAI.
  AiProvider get provider => usingCloud ? AiProvider.openai : chosenProvider;

  String get sourceLabel => usingCloud ? 'Juno cloud' : provider.label;

  String get model {
    if (usingCloud) return prefs.getString(_cloudModelKey) ?? AiProvider.openai.defaultModel;
    final m = prefs.getString(modelPrefFor(provider))?.trim();
    return m == null || m.isEmpty ? provider.defaultModel : m;
  }

  int get budgetCents {
    if (usingCloud) return (prefs.getInt(_cloudCapKey) ?? defaultBudgetCents * 10000) ~/ 10000;
    return prefs.getInt(budgetPref) ?? defaultBudgetCents;
  }

  String get _month {
    final n = _clock();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}';
  }

  String get _spentKey => 'ai.spent.$_month';
  String get _callsKey => 'ai.used.$_month';

  // The relay's own figures, mirrored from each reply's headers.
  String get _cloudSpentKey => 'ai.cloud.spent.$_month';
  static const _cloudCapKey = 'ai.cloud.cap';
  static const _cloudModelKey = 'ai.cloud.model';

  /// Spent this month, in millionths of a dollar.
  int get spentMicros => usingCloud ? prefs.getInt(_cloudSpentKey) ?? 0 : prefs.getInt(_spentKey) ?? 0;
  int get callsThisMonth => prefs.getInt(_callsKey) ?? 0;
  bool get capped => spentMicros >= budgetCents * 10000;

  /// Cost in micro-dollars of a call with these token counts. OpenAI bills
  /// cached input at a tenth; other providers' discounts aren't assumed.
  int costMicros(int input, int output, {int cached = 0}) {
    final p = provider;
    final cachedIn = p == AiProvider.openai ? cached.clamp(0, input) : 0;
    final usd = ((input - cachedIn) * p.inPerM + cachedIn * p.inPerM * 0.1 + output * p.outPerM) / 1e6;
    return (usd * 1e6).ceil();
  }

  Future<void> _charge(int micros) async {
    await prefs.setInt(_spentKey, spentMicros + micros);
    await prefs.setInt(_callsKey, callsThisMonth + 1);
  }

  /// OpenAI's reasoning models take different parameters from the rest.
  bool get _reasoning => provider == AiProvider.openai && RegExp(r'^(gpt-5|o\d)').hasMatch(model);

  Map<String, dynamic> _body(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxOutput, {
    required bool effort,
  }) => {
    'model': model,
    'messages': messages,
    if (tools != null && tools.isNotEmpty) 'tools': tools,
    if (_reasoning) ...{
      // Reasoning tokens count toward the limit, so leave room for them.
      'max_completion_tokens': maxOutput + 1500,
      if (effort) 'reasoning_effort': model.startsWith('gpt-5-') || model == 'gpt-5' ? 'minimal' : 'low',
    } else ...{
      'max_tokens': maxOutput,
      'temperature': 0.2,
    },
  };

  /// One chat request. Null when off, capped, or anything goes wrong.
  Future<AiReply?> chat(
    List<Map<String, dynamic>> messages, {
    List<Map<String, dynamic>>? tools,
    int maxOutput = 300,
  }) async {
    if (usingCloud) return _chatCloud(messages, tools, maxOutput);
    final key = apiKey;
    if (key == null || capped) return null;
    Future<http.Response> send({required bool effort}) => _client
        .post(
          Uri.parse(provider.url),
          headers: {'Authorization': 'Bearer $key', 'Content-Type': 'application/json'},
          body: jsonEncode(_body(messages, tools, maxOutput, effort: effort)),
        )
        .timeout(const Duration(seconds: 30));
    try {
      var res = await send(effort: true);
      // A model that doesn't know the effort setting: once more without it.
      if (res.statusCode == 400 &&
          _reasoning &&
          utf8.decode(res.bodyBytes, allowMalformed: true).contains('reasoning_effort')) {
        res = await send(effort: false);
      }
      if (res.statusCode != 200) return null;
      final body = _decode(res);
      final usage = body['usage'] as Map<String, dynamic>?;
      final details = usage?['prompt_tokens_details'] as Map<String, dynamic>?;
      await _charge(
        costMicros(
          (usage?['prompt_tokens'] as num?)?.toInt() ?? _estimateTokens(messages, tools),
          (usage?['completion_tokens'] as num?)?.toInt() ?? maxOutput,
          cached: (details?['cached_tokens'] as num?)?.toInt() ?? 0,
        ),
      );
      return _reply(body);
    } on Object {
      // A timeout may still be billed: count the input and the most output.
      await _charge(costMicros(_estimateTokens(messages, tools), maxOutput));
      return null;
    }
  }

  /// Through the relay: it holds the key, picks the model, enforces the cap
  /// and reports the month's spend in headers, which are mirrored here.
  Future<AiReply?> _chatCloud(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    int maxOutput,
  ) async {
    if (capped) return null;
    try {
      final ep = await cloud!.endpoint();
      if (ep == null) return null;
      final (url, headers) = ep;
      final res = await _client
          .post(
            url,
            headers: {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'messages': messages,
              if (tools != null && tools.isNotEmpty) 'tools': tools,
              'max_output': maxOutput,
            }),
          )
          .timeout(const Duration(seconds: 50));
      final spent = int.tryParse(res.headers['x-juno-spent-micros'] ?? '');
      final cap = int.tryParse(res.headers['x-juno-cap-micros'] ?? '');
      if (spent != null) await prefs.setInt(_cloudSpentKey, spent);
      if (cap != null) await prefs.setInt(_cloudCapKey, cap);
      if (res.statusCode != 200) return null;
      await prefs.setInt(_callsKey, callsThisMonth + 1);
      final body = _decode(res);
      if (body['model'] is String) await prefs.setString(_cloudModelKey, body['model'] as String);
      return _reply(body);
    } on Object {
      return null;
    }
  }

  /// Always UTF-8: without a charset header `body` would fall back to
  /// Latin-1 and garble Arabic, em dashes and the like.
  static Map<String, dynamic> _decode(http.Response res) =>
      jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;

  static AiReply? _reply(Map<String, dynamic> body) {
    final choices = body['choices'] as List<dynamic>?;
    final first = choices?.firstOrNull as Map<String, dynamic>?;
    final message = first?['message'] as Map<String, dynamic>?;
    if (message == null) return null;
    final calls = <AiToolCall>[
      for (final c in (message['tool_calls'] as List<dynamic>?) ?? const [])
        if (c is Map<String, dynamic> && c['function'] is Map<String, dynamic>)
          AiToolCall(
            c['id'] as String? ?? '',
            (c['function'] as Map<String, dynamic>)['name'] as String? ?? '',
            _args((c['function'] as Map<String, dynamic>)['arguments']),
          ),
    ];
    final content = message['content'];
    return AiReply(
      {
        'role': 'assistant',
        'content': content is String ? content : null,
        if (message['tool_calls'] != null) 'tool_calls': message['tool_calls'],
      },
      content is String ? content.trim() : null,
      calls,
    );
  }

  static Map<String, dynamic>? _args(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is! String) return null;
    if (raw.trim().isEmpty) return {};
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : null;
    } on FormatException {
      return null;
    }
  }

  /// Roughly four characters a token.
  static int _estimateTokens(List<Map<String, dynamic>> messages, List<Map<String, dynamic>>? tools) =>
      (jsonEncode(messages).length + (tools == null ? 0 : jsonEncode(tools).length)) ~/ 4;

  Future<String?> _ask(String system, String user, {int maxOutput = 300}) async {
    final r = await chat([
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ], maxOutput: maxOutput);
    return r?.text;
  }

  /// Reads a receipt's total/date/merchant from its OCR text, for when the
  /// on-device parser wasn't confident. Returns parsed JSON fields or null.
  Future<({double? total, String? currency, String? date, String? merchant})?> readReceipt(List<String> lines) async {
    final text = lines.take(80).join('\n');
    final answer = await _ask(
      'You read shop receipts. Reply with only compact JSON: '
      '{"total": number|null, "currency": "USD"|"LBP"|null, "date": "YYYY-MM-DD"|null, "merchant": string|null}. '
      'The total is what was paid, not subtotal, tax, cash or change. Dates on Lebanese receipts are day-first.',
      text,
    );
    if (answer == null) return null;
    try {
      final start = answer.indexOf('{');
      final end = answer.lastIndexOf('}');
      final j = jsonDecode(answer.substring(start, end + 1)) as Map<String, dynamic>;
      return (
        total: (j['total'] as num?)?.toDouble(),
        currency: j['currency'] as String?,
        date: j['date'] as String?,
        merchant: j['merchant'] as String?,
      );
    } on Object {
      return null;
    }
  }

  /// Picks a category for each description from [categories] (names). Only
  /// the descriptions, whether each is money in or out, and the names are
  /// sent. Returns description → category name, for the ones it could place;
  /// names not in the list are dropped. Up to [maxRows] descriptions.
  Future<Map<String, String>> categorize(
    List<(String description, bool income)> rows, {
    required List<String> expenseCategories,
    required List<String> incomeCategories,
    int maxRows = 120,
  }) async {
    final out = <String, String>{};
    final allowed = {...expenseCategories, ...incomeCategories};
    final unique = {for (final r in rows.take(maxRows)) r.$1.trim(): r.$2}..remove('');
    final list = unique.entries.toList();
    for (var i = 0; i < list.length; i += 60) {
      final chunk = list.sublist(i, i + 60 > list.length ? list.length : i + 60);
      final answer = await _ask(
        'You sort bank and card transactions into categories for a household in Lebanon. '
        'Expense categories: ${expenseCategories.join(', ')}. Income categories: ${incomeCategories.join(', ')}. '
        'For each numbered line, pick the best category from the right list, or null if none fits or you are '
        'unsure. Reply with only compact JSON: {"1": "Category", "2": null, …}.',
        [
          for (var j = 0; j < chunk.length; j++) '${j + 1}. ${chunk[j].value ? 'IN' : 'OUT'} ${chunk[j].key}',
        ].join('\n'),
        maxOutput: 40 + chunk.length * 12,
      );
      if (answer == null) break;
      try {
        final j = jsonDecode(answer.substring(answer.indexOf('{'), answer.lastIndexOf('}') + 1));
        if (j is! Map) continue;
        for (final e in j.entries) {
          final n = int.tryParse('${e.key}');
          final name = e.value;
          if (n == null || n < 1 || n > chunk.length || name is! String || !allowed.contains(name)) continue;
          final (desc, income) = (chunk[n - 1].key, chunk[n - 1].value);
          // Never an income category for money out, or the other way round.
          if ((income ? incomeCategories : expenseCategories).contains(name)) out[desc] = name;
        }
      } on Object {
        continue;
      }
    }
    return out;
  }

  /// Two sentences on the week so far, from aggregated [facts] only.
  Future<String?> weekly(String facts) => _ask(
    'You are a calm, practical personal-finance assistant. In at most two short sentences, say how this week is '
    'going from these figures and one thing to keep in mind for the rest of it. No greetings, no bullet points, '
    'no invented numbers.',
    facts,
    maxOutput: 120,
  );

  /// A short, plain-language read of a month. [facts] are aggregated lines
  /// like "Spent $1,850 (+$200 vs August)" — no individual entries.
  Future<String?> summarize(String facts) => _ask(
    'You are a calm, practical personal-finance assistant. In at most 4 short sentences, say what stands out in '
    'these monthly figures and one concrete thing to watch next month. No greetings, no bullet points, no '
    'invented numbers.',
    facts,
  );
}
