import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Optional AI help through *your* OpenAI API key — off unless you add one.
///
/// Guard rails, all enforced here:
/// * a monthly call cap (default 100) — at the cap it simply returns null and
///   the on-device result is used;
/// * short prompts and `max_tokens` 300, a small model by default;
/// * only what's needed is sent: receipt *text* (never the photo) or a
///   month's aggregated figures (never individual entries or notes);
/// * every failure (offline, bad key, quota) returns null — the app never
///   depends on it.
///
/// Note: ChatGPT Plus does not include API access; the key needs API billing
/// at platform.openai.com.
class AiAssist {
  AiAssist(this.prefs, {http.Client? client}) : _client = client ?? http.Client();

  final SharedPreferences prefs;
  final http.Client _client;

  static const keyPref = 'ai.key';
  static const modelPref = 'ai.model';
  static const capPref = 'ai.cap';
  static const defaultModel = 'gpt-4o-mini';
  static const defaultCap = 100;

  String? get apiKey {
    final k = prefs.getString(keyPref)?.trim();
    return k == null || k.isEmpty ? null : k;
  }

  bool get enabled => apiKey != null;
  String get model => prefs.getString(modelPref) ?? defaultModel;
  int get cap => prefs.getInt(capPref) ?? defaultCap;

  String get _usedKey {
    final n = DateTime.now();
    return 'ai.used.${n.year}-${n.month.toString().padLeft(2, '0')}';
  }

  int get usedThisMonth => prefs.getInt(_usedKey) ?? 0;
  bool get capped => usedThisMonth >= cap;

  Future<String?> _ask(String system, String user) async {
    final key = apiKey;
    if (key == null || capped) return null;
    // Count before calling: a timeout that still bills must count too.
    await prefs.setInt(_usedKey, usedThisMonth + 1);
    try {
      final res = await _client
          .post(
            Uri.parse('https://api.openai.com/v1/chat/completions'),
            headers: {'Authorization': 'Bearer $key', 'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'max_tokens': 300,
              'temperature': 0.2,
              'messages': [
                {'role': 'system', 'content': system},
                {'role': 'user', 'content': user},
              ],
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final choices = body['choices'] as List<dynamic>?;
      final first = choices?.firstOrNull as Map<String, dynamic>?;
      final message = first?['message'] as Map<String, dynamic>?;
      final content = message?['content'];
      return content is String ? content.trim() : null;
    } on Object {
      return null;
    }
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

  /// A short, plain-language read of a month. [facts] are aggregated lines
  /// like "Spent $1,850 (+$200 vs August)" — no individual entries.
  Future<String?> summarize(String facts) => _ask(
    'You are a calm, practical personal-finance assistant. In at most 4 short sentences, say what stands out in '
    'these monthly figures and one concrete thing to watch next month. No greetings, no bullet points, no '
    'invented numbers.',
    facts,
  );
}
