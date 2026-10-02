import 'dart:convert';

import 'package:clock/clock.dart' as clk;
import 'package:drift/drift.dart';
import 'package:intl/intl.dart';
import 'package:juno/core/ai/assist.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/assistant/assistant_tools.dart';

/// A draft that can't be logged as it is any more.
class DraftStale implements Exception {
  const DraftStale(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One line of the visible conversation.
class ChatLine {
  const ChatLine.user(this.text) : fromUser = true, looked = const [], failed = false, drafts = const [];

  const ChatLine.assistant(this.text, {this.looked = const [], this.failed = false, this.drafts = const []})
    : fromUser = false;

  factory ChatLine.fromJson(Map<String, dynamic> j) => j['user'] == true
      ? ChatLine.user(j['text'] as String)
      : ChatLine.assistant(
          j['text'] as String,
          looked: [for (final l in (j['looked'] as List<dynamic>?) ?? const []) l as String],
          failed: j['failed'] == true,
          drafts: [
            for (final d in (j['drafts'] as List<dynamic>?) ?? const []) EntryDraft.fromJson(d as Map<String, dynamic>),
          ],
        );

  final String text;
  final bool fromUser;

  /// The lookups behind an answer, shown under it.
  final List<String> looked;
  final bool failed;

  /// Entries the assistant prepared, each waiting for a tap on Log.
  final List<EntryDraft> drafts;

  Map<String, dynamic> toJson() => {
    'text': text,
    if (fromUser) 'user': true,
    if (looked.isNotEmpty) 'looked': looked,
    if (failed) 'failed': true,
    if (drafts.isNotEmpty) 'drafts': [for (final d in drafts) d.toJson()],
  };
}

/// A conversation about your money. The model answers by calling
/// [AssistantTools], which read the local database on the device; it never
/// sees the database itself. It can *prepare* entries, which are saved only
/// when the person taps Log ([log]); it can't edit or delete anything.
///
/// The conversation is kept on this device (prefs), so it survives a
/// restart; it is never synced.
///
/// To keep each request small, a finished turn is folded down to the
/// question and the answer — the lookups it made are dropped from what's
/// sent next time — and only the last [keepTurns] turns are sent.
class Assistant {
  Assistant(this.ai, this.ledger, {DateTime Function()? clock})
    : _clock = clock ?? clk.clock.now,
      tools = AssistantTools(ledger, clock: clock) {
    _load();
  }

  static const storeKey = 'assistant.chat';
  static const keepLines = 60;

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
    _save();
  }

  void _load() {
    final raw = ai.prefs.getString(storeKey);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      lines.addAll([for (final l in j['lines'] as List<dynamic>) ChatLine.fromJson(l as Map<String, dynamic>)]);
      _history.addAll([for (final m in j['history'] as List<dynamic>) (m as Map).cast<String, dynamic>()]);
    } on Object {
      // A corrupt store just means a fresh conversation.
      lines.clear();
      _history.clear();
    }
  }

  Future<void> _save() async {
    if (lines.length > keepLines) lines.removeRange(0, lines.length - keepLines);
    if (_history.length > keepTurns * 2) _history.removeRange(0, _history.length - keepTurns * 2);
    await ai.prefs.setString(
      storeKey,
      jsonEncode({
        'lines': [for (final l in lines) l.toJson()],
        'history': _history,
      }),
    );
  }

  /// Saves [d] as a real entry. Returns its id; logging twice is a no-op.
  ///
  /// Drafts can sit in the chat for days: if the account was archived or
  /// deleted since, this throws [DraftStale] rather than saving into it (a
  /// deleted account's money would vanish from every balance); a category
  /// deleted since is dropped.
  Future<String> log(EntryDraft d) async {
    if (d.loggedId != null) return d.loggedId!;
    final account = await (ledger.db.select(
      ledger.db.accounts,
    )..where((a) => a.id.equals(d.accountId))).getSingleOrNull();
    if (account == null || account.deletedAt != null || account.archived) {
      throw const DraftStale('That account is gone or archived — tap Edit to pick another.');
    }
    final category = d.categoryId == null
        ? null
        : await (ledger.db.select(ledger.db.categories)..where((c) => c.id.equals(d.categoryId!))).getSingleOrNull();
    d.loggedId = await ledger.addTransaction(
      TransactionsCompanion.insert(
        type: d.type,
        scope: d.scope,
        amountCents: d.amountCents,
        accountId: d.accountId,
        categoryId: Value(category == null || category.deletedAt != null ? null : category.id),
        occurredOn: d.day,
        note: Value(d.note),
      ),
    );
    await _save();
    return d.loggedId!;
  }

  /// After the draft was opened in the entry editor: if an entry was saved
  /// there since [since], the draft is that entry now (so Log can't add a
  /// second one).
  Future<void> adoptEdited(EntryDraft d, DateTime since) async {
    if (d.loggedId != null) return;
    final t = ledger.db.transactions;
    final row =
        await (ledger.db.select(t)
              ..where((x) => x.createdAt.isBiggerOrEqualValue(since) & x.deletedAt.isNull())
              ..orderBy([(x) => OrderingTerm.desc(x.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    if (row == null) return;
    d.loggedId = row.id;
    await _save();
  }

  /// Takes a logged draft back out (soft delete, so it syncs).
  Future<void> unlog(EntryDraft d) async {
    final id = d.loggedId;
    if (id == null) return;
    await ledger.deleteTransaction(id);
    d.loggedId = null;
    await _save();
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
- To log, add or record something, call draft_entry once per entry. It shows the user a card with a Log button; nothing is saved until they tap it, so don't ask for confirmation in words — say briefly what you prepared. Pick the closest category. A date word ("yesterday", "on Monday") belongs only to the item it's next to; leave the date out for the others, which means today.
- You cannot edit or delete entries. If asked, tell the user to swipe the entry in Activity.
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
    tools.takeDrafts();
    try {
      final answer = await _answer(q);
      lines.add(answer);
      await _save();
      return answer;
    } finally {
      _busy = false;
    }
  }

  Future<ChatLine> _answer(String q) async {
    if (!ai.enabled) {
      return const ChatLine.assistant('Sign in under Settings → Cloud sync to use the assistant.', failed: true);
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
              : ai.usingCloud
              ? 'Couldn’t reach Juno cloud. Check the connection and try again.'
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
        return ChatLine.assistant(text, looked: looked, drafts: tools.takeDrafts());
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
