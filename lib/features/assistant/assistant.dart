import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/assistant/assistant_tools.dart';

/// One line of the visible conversation.
class ChatLine {
  const ChatLine.user(this.text) : fromUser = true, looked = const [], failed = false;

  const ChatLine.assistant(this.text, {this.looked = const [], this.failed = false}) : fromUser = false;

  final String text;
  final bool fromUser;

  /// The lookups behind an answer, shown under it.
  final List<String> looked;
  final bool failed;
}

/// A conversation about your money. The model answers by calling
/// [AssistantTools], which read the local database on the device; it never
/// sees the database itself, and it cannot change anything.
///
/// To keep each request small, a finished turn is folded down to the
/// question and the answer — the lookups it made are dropped from what's
/// sent next time — and only the last [keepTurns] turns are sent.
class Assistant {
  Assistant(this.ai, this.ledger, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      tools = AssistantTools(ledger, clock: clock);

  final AiAssist ai;
  final Ledger ledger;
  final AssistantTools tools;
  final DateTime Function() _clock;

  static const keepTurns = 6;
  static const maxRounds = 6;

  final List<ChatLine> lines = [];

  /// Folded history: alternating user / assistant messages.
  final List<Map<String, dynamic>> _history = [];

  bool get busy => _busy;
  bool _busy = false;

  void reset() {
    lines.clear();
    _history.clear();
  }

  Future<String> _system() async {
    final now = _clock();
    final cats = await ledger.watchCategories().first;
    final accounts = await ledger.watchAccounts().first;
    final rates = await ledger.rates();
    // Stable instructions first, so providers that cache a repeated prefix
    // can reuse it; the parts that change go last.
    return '''
You are Juno, the assistant inside a personal finance app. The user supports their family and is the only one paying, so spending is split into "personal" (their own) and "household" (the family's).

Rules:
- Every figure you give must come from a tool result in this conversation. Never guess or invent numbers. If the tools can't answer, say so.
- Amounts are US dollars unless marked otherwise. Write them like \$1,240 or \$12.50.
- Be brief: a few sentences, or a short list when the user asks for one. No greetings, no filler.
- You can only read. You cannot add, edit or delete entries; if asked, tell the user where to do it in the app (the + button, or swipe an entry in Activity).
- When a question is vague about time, use this month and say so.
- Reply in the language the user writes in.

Categories: ${cats.map((c) => c.name).join(', ')}.
Accounts: ${accounts.map((a) => '${a.name} (${a.currency})').join(', ')}.
Exchange rates per US dollar: ${rates.isEmpty ? 'none set' : rates.entries.map((e) => '${e.key} ${e.value}').join(', ')}.
Today is ${DateFormat('EEEE d MMMM y').format(now)} (${Day.of(now)}).''';
  }

  /// Asks [question]. Adds the question and the answer (or a failure) to
  /// [lines] and returns the answer line.
  Future<ChatLine> ask(String question) async {
    final q = question.trim();
    if (q.isEmpty || _busy) return const ChatLine.assistant('', failed: true);
    _busy = true;
    lines.add(ChatLine.user(q));
    try {
      final answer = await _answer(q);
      lines.add(answer);
      return answer;
    } finally {
      _busy = false;
    }
  }

  Future<ChatLine> _answer(String q) async {
    if (!ai.enabled) {
      return const ChatLine.assistant('Add an API key in Settings → AI assist to use the assistant.', failed: true);
    }
    final turn = <Map<String, dynamic>>[
      {'role': 'user', 'content': q},
    ];
    final looked = <String>[];
    final system = await _system();
    for (var round = 0; round < maxRounds; round++) {
      final reply = await ai.chat(
        [
          {'role': 'system', 'content': system},
          ..._recent(),
          ...turn,
        ],
        tools: AssistantTools.definitions,
        maxOutput: 600,
      );
      if (reply == null) {
        return ChatLine.assistant(
          ai.capped
              ? 'This month’s AI budget is used up. It resets on the 1st, or you can raise it in Settings → AI assist.'
              : 'Couldn’t reach ${ai.provider.label}. Check the connection and the API key, then try again.',
          failed: true,
        );
      }
      turn.add(reply.message);
      if (reply.toolCalls.isEmpty) {
        final text = reply.text ?? '';
        if (text.isEmpty) break;
        _history
          ..add({'role': 'user', 'content': q})
          ..add({'role': 'assistant', 'content': text});
        return ChatLine.assistant(text, looked: looked);
      }
      for (final call in reply.toolCalls) {
        final result = call.args == null
            ? {'error': 'The arguments were not valid JSON.'}
            : await tools.run(call.name, call.args!);
        if (!looked.contains(call.name)) looked.add(call.name);
        turn.add({'role': 'tool', 'tool_call_id': call.id, 'content': jsonEncode(result)});
      }
    }
    return const ChatLine.assistant('I couldn’t work that one out. Try asking it more narrowly.', failed: true);
  }

  List<Map<String, dynamic>> _recent() {
    const keep = keepTurns * 2;
    return _history.length <= keep ? _history : _history.sublist(_history.length - keep);
  }
}
