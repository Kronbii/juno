import 'package:clock/clock.dart' as clk;
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/features/insights/analytics.dart';
import 'package:juno/features/plan/recurrence.dart';
import 'package:juno/features/smart/advisor.dart';

/// An entry the assistant prepared. Nothing is saved until the person taps
/// Log on it in the chat.
class EntryDraft {
  EntryDraft({
    required this.type,
    required this.amountCents,
    required this.currency,
    required this.accountId,
    required this.categoryId,
    required this.scope,
    required this.day,
    required this.note,
    this.loggedId,
  });

  factory EntryDraft.fromJson(Map<String, dynamic> j) => EntryDraft(
    type: TxType.values.byName(j['type'] as String),
    amountCents: j['amountCents'] as int,
    currency: j['currency'] as String,
    accountId: j['accountId'] as String,
    categoryId: j['categoryId'] as String?,
    scope: Scope.values.byName(j['scope'] as String),
    day: j['day'] as String,
    note: j['note'] as String,
    loggedId: j['loggedId'] as String?,
  );

  final TxType type;
  final int amountCents;
  final String currency;
  final String accountId;
  final String? categoryId;
  final Scope scope;
  final String day;
  final String note;

  /// The saved entry's id once logged (and null again if undone).
  String? loggedId;

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'amountCents': amountCents,
    'currency': currency,
    'accountId': accountId,
    'categoryId': categoryId,
    'scope': scope.name,
    'day': day,
    'note': note,
    'loggedId': loggedId,
  };
}

/// What the assistant may look up. Every tool runs here, on the device,
/// against the local database; only its small JSON result is sent to the
/// model. All are read-only except `draft_entry`, which only *prepares* an
/// entry for the person to confirm. Amounts are US dollars unless a field
/// says otherwise.
class AssistantTools {
  AssistantTools(this.ledger, {DateTime Function()? clock}) : _clock = clock ?? clk.clock.now;

  final Ledger ledger;
  final DateTime Function() _clock;

  final List<EntryDraft> _drafts = [];

  /// Drafts prepared since the last call, handed to the chat to show.
  List<EntryDraft> takeDrafts() {
    final out = List.of(_drafts);
    _drafts.clear();
    return out;
  }

  static Map<String, dynamic> _fn(
    String name,
    String description,
    Map<String, dynamic> props, [
    List<String> required = const [],
  ]) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {'type': 'object', 'properties': props, 'required': required},
    },
  };

  static const _from = {'type': 'string', 'description': 'First day, YYYY-MM-DD. Default: start of this month.'};
  static const _to = {'type': 'string', 'description': 'Last day, YYYY-MM-DD. Default: today.'};
  static const _scope = {
    'type': 'string',
    'enum': ['personal', 'household'],
    'description': 'Only personal or only household money. Omit for both.',
  };

  static final definitions = <Map<String, dynamic>>[
    _fn('summary', 'Income, spending, net, savings rate, personal vs household and top categories for a period.', {
      'from': _from,
      'to': _to,
      'scope': _scope,
    }),
    _fn(
      'category_spending',
      'Spending in categories whose name contains the text, with a month-by-month breakdown.',
      {
        'category': {'type': 'string', 'description': 'Category name or part of it, e.g. "dining".'},
        'from': _from,
        'to': _to,
        'scope': _scope,
      },
      ['category'],
    ),
    _fn('find_entries', 'Individual entries matching filters, newest first, with the total of all matches.', {
      'from': {'type': 'string', 'description': 'First day, YYYY-MM-DD. Default: all time.'},
      'to': _to,
      'search': {'type': 'string', 'description': 'Text in the merchant or note.'},
      'category': {'type': 'string', 'description': 'Category name or part of it.'},
      'type': {
        'type': 'string',
        'enum': ['expense', 'income', 'transfer'],
      },
      'scope': _scope,
      'limit': {'type': 'integer', 'description': 'At most 30. Default 15.'},
    }),
    _fn('top_merchants', 'Where money went, grouped by shop or payee.', {
      'from': _from,
      'to': _to,
      'scope': _scope,
      'limit': {'type': 'integer', 'description': 'At most 15. Default 8.'},
    }),
    _fn('budgets', 'Monthly budgets with spent, remaining and status.', {
      'month': {'type': 'string', 'description': 'YYYY-MM. Default: this month.'},
    }),
    _fn('accounts', 'Account balances today, in their own currency and in dollars, and net worth.', {}),
    _fn('goals', 'Savings goals with target, saved so far and target date.', {}),
    _fn('recurring', 'Recurring bills, subscriptions and income with amount, frequency and next due date.', {}),
    _fn(
      'draft_entry',
      'Prepare a new expense, income or transfer for the user to confirm with a button. Nothing is saved until '
          'they tap Log. Use it when they ask to log, add or record something.',
      {
        'amount': {'type': 'number', 'description': 'In the currency given, e.g. 12.5 or 450000.'},
        'currency': {
          'type': 'string',
          'description': 'USD, LBP or another code. Default USD; amounts of 10,000 or more are usually LBP.',
        },
        'type': {
          'type': 'string',
          'enum': ['expense', 'income'],
        },
        'category': {'type': 'string', 'description': 'Category name, from the list in your instructions.'},
        'scope': _scope,
        'date': {'type': 'string', 'description': 'YYYY-MM-DD. Default: today.'},
        'note': {'type': 'string', 'description': 'Short description, e.g. the shop.'},
        'account': {'type': 'string', 'description': 'Account name. Default: the first account in that currency.'},
      },
      ['amount'],
    ),
    _fn(
      'safe_to_spend',
      'This month: income expected, spent, bills still due, what is left to spend per day, and a month-end forecast.',
      {},
    ),
  ];

  /// Runs [name]. Never throws: a bad call comes back as `{"error": …}` so
  /// the model can correct itself.
  Future<Map<String, dynamic>> run(String name, Map<String, dynamic> args) async {
    try {
      return switch (name) {
        'summary' => await _summary(args),
        'category_spending' => await _categorySpending(args),
        'find_entries' => await _findEntries(args),
        'top_merchants' => await _topMerchants(args),
        'budgets' => await _budgets(args),
        'accounts' => await _accounts(),
        'goals' => await _goals(),
        'recurring' => await _recurring(),
        'safe_to_spend' => await _safeToSpend(),
        'draft_entry' => await _draftEntry(args),
        _ => {'error': 'Unknown tool $name'},
      };
    } on _BadArg catch (e) {
      return {'error': e.message};
    } on Object catch (e) {
      return {'error': 'Lookup failed: $e'};
    }
  }

  // ------------------------------------------------------------ arguments

  static final _dayRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  String _day(Map<String, dynamic> a, String key, String fallback) {
    final v = a[key];
    if (v == null || (v is String && v.trim().isEmpty)) return fallback;
    if (v is! String || !_dayRe.hasMatch(v.trim())) throw _BadArg('$key must be YYYY-MM-DD');
    final s = v.trim();
    final d = Day.parse(s);
    // Rejects 2026-02-31 and the like, which DateTime would roll over.
    if (Day.of(d) != s) throw _BadArg('$key is not a real date');
    return s;
  }

  (String, String) _range(Map<String, dynamic> a) {
    final now = _clock();
    final from = _day(a, 'from', Day.firstOfMonth(now));
    final to = _day(a, 'to', Day.of(now));
    if (from.compareTo(to) > 0) throw _BadArg('from is after to');
    return (from, to);
  }

  static Scope? _scopeOf(Map<String, dynamic> a) {
    final v = a['scope'];
    if (v == null) return null;
    return Scope.values.where((s) => s.name == v).firstOrNull ?? (throw _BadArg('scope must be personal or household'));
  }

  static int _limit(Map<String, dynamic> a, int fallback, int max) {
    final v = a['limit'];
    final n = v is num ? v.toInt() : fallback;
    return n.clamp(1, max);
  }

  static double _usd(int cents) => cents / 100;

  Future<Map<String, Category>> _categories() async => {
    for (final c in await ledger.watchCategories(includeArchived: true).first) c.id: c,
  };

  Future<Map<String, Account>> _accountsById() async => {
    for (final a in await ledger.watchAccounts(includeArchived: true).first) a.id: a,
  };

  Future<Map<String, double>> _rates() async => {'USD': 1, ...await ledger.rates()};

  Future<Set<String>> _matchCategories(String? text) async {
    final q = text?.trim().toLowerCase() ?? '';
    if (q.isEmpty) return {};
    final cats = await _categories();
    final ids = {
      for (final c in cats.values)
        if (c.name.toLowerCase().contains(q) || q.contains(c.name.toLowerCase())) c.id,
    };
    if (ids.isEmpty) {
      throw _BadArg('No category matches "$text". Categories: ${cats.values.map((c) => c.name).join(', ')}');
    }
    return ids;
  }

  // ---------------------------------------------------------------- tools

  Future<Map<String, dynamic>> _summary(Map<String, dynamic> a) async {
    final (from, to) = _range(a);
    final scope = _scopeOf(a);
    final s = PeriodSummary.of(await ledger.transactions(TxQuery(from: from, to: to, scope: scope)));
    final cats = await _categories();
    return {
      'from': from,
      'to': to,
      'scope': scope?.name ?? 'all',
      'income': _usd(s.income),
      'spent': _usd(s.expense),
      'net': _usd(s.net),
      'savings_rate': s.savingsRate == null ? null : (s.savingsRate! * 100).round(),
      if (scope == null) 'personal_spent': _usd(s.byScope[Scope.personal]!),
      if (scope == null) 'household_spent': _usd(s.byScope[Scope.household]!),
      'entries': s.count,
      'top_categories': [
        for (final e in s.rankedCategories.take(8))
          {
            'name': cats[e.key]?.name ?? 'Uncategorised',
            'spent': _usd(e.value),
            'share_pct': s.expense == 0 ? 0 : (e.value * 100 / s.expense).round(),
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _categorySpending(Map<String, dynamic> a) async {
    final (from, to) = _range(a);
    final scope = _scopeOf(a);
    final ids = await _matchCategories(a['category'] as String?);
    final txs = await ledger.transactions(
      TxQuery(from: from, to: to, scope: scope, type: TxType.expense, categoryIds: ids),
    );
    final cats = await _categories();
    final byMonth = <String, int>{};
    var total = 0;
    for (final t in txs) {
      total += t.usd;
      final m = t.occurredOn.substring(0, 7);
      byMonth[m] = (byMonth[m] ?? 0) + t.usd;
    }
    final months = byMonth.keys.toList()..sort();
    return {
      'categories': [for (final id in ids) cats[id]!.name],
      'from': from,
      'to': to,
      'spent': _usd(total),
      'entries': txs.length,
      'by_month': [
        for (final m in months) {'month': m, 'spent': _usd(byMonth[m]!)},
      ],
    };
  }

  Future<Map<String, dynamic>> _findEntries(Map<String, dynamic> a) async {
    // Unlike the other tools, no start date means all time.
    final f = _day(a, 'from', '');
    final from = f.isEmpty ? null : f;
    final to = _day(a, 'to', Day.of(_clock()));
    if (from != null && from.compareTo(to) > 0) throw _BadArg('from is after to');
    final type = a['type'] == null
        ? null
        : TxType.values.where((t) => t.name == a['type']).firstOrNull ??
              (throw _BadArg('type must be expense, income or transfer'));
    final ids = a['category'] == null ? null : await _matchCategories(a['category'] as String?);
    final all = await ledger.transactions(
      TxQuery(
        from: from,
        to: to,
        scope: _scopeOf(a),
        type: type,
        categoryIds: ids,
        search: a['search'] as String?,
      ),
    );
    final limit = _limit(a, 15, 30);
    final cats = await _categories();
    final accounts = await _accountsById();
    String clip(String s) => s.length <= 60 ? s : '${s.substring(0, 59)}…';
    return {
      'matches': all.length,
      'total_expense': _usd(all.where((t) => t.type == TxType.expense).fold(0, (s, t) => s + t.usd)),
      'total_income': _usd(all.where((t) => t.type == TxType.income).fold(0, (s, t) => s + t.usd)),
      'shown': all.length < limit ? all.length : limit,
      'entries': [
        for (final t in all.take(limit))
          {
            'date': t.occurredOn,
            'type': t.type.name,
            'amount': _usd(t.usd),
            if (t.currency != baseCurrency) 'original': Fx.format(t.amountCents, t.currency),
            'category': cats[t.categoryId]?.name,
            'scope': t.scope.name,
            'account': accounts[t.accountId]?.name,
            if (t.merchant.isNotEmpty) 'merchant': clip(t.merchant),
            if (t.note.isNotEmpty) 'note': clip(t.note),
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _topMerchants(Map<String, dynamic> a) async {
    final (from, to) = _range(a);
    final txs = await ledger.transactions(TxQuery(from: from, to: to, scope: _scopeOf(a), type: TxType.expense));
    return {
      'from': from,
      'to': to,
      'merchants': [
        for (final m in topMerchants(txs, n: _limit(a, 8, 15)))
          {'name': m.name, 'spent': _usd(m.total), 'entries': m.count},
      ],
    };
  }

  Future<Map<String, dynamic>> _budgets(Map<String, dynamic> a) async {
    final now = _clock();
    var month = DateTime(now.year, now.month);
    final v = a['month'];
    if (v is String && v.trim().isNotEmpty) {
      final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(v.trim());
      final mm = m == null ? 0 : int.parse(m.group(2)!);
      if (m == null || mm < 1 || mm > 12) throw _BadArg('month must be YYYY-MM');
      month = DateTime(int.parse(m.group(1)!), mm);
    }
    final budgets = await ledger.watchBudgets().first;
    final txs = await ledger.transactions(TxQuery(from: Day.firstOfMonth(month), to: Day.lastOfMonth(month)));
    final cats = await _categories();
    return {
      'month': Day.firstOfMonth(month).substring(0, 7),
      'budgets': [
        for (final s in budgetStatuses(budgets, txs))
          {
            'name': s.budget.categoryId == null ? 'Overall' : cats[s.budget.categoryId]?.name ?? 'Category',
            'scope': s.budget.scope?.name ?? 'all',
            'limit': _usd(s.budget.limitCents),
            'spent': _usd(s.spent),
            'remaining': _usd(s.remaining),
            'status': s.over ? 'over' : (s.near ? 'near limit' : 'ok'),
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _accounts() async {
    final accounts = (await ledger.watchAccounts().first).where((a) => !a.archived);
    final balances = await ledger.watchBalances().first;
    final rates = await _rates();
    var net = 0;
    var netComplete = true;
    final list = <Map<String, dynamic>>[];
    for (final a in accounts) {
      final cents = balances[a.id] ?? a.openingBalanceCents;
      final usd = Fx.tryToUsd(cents, a.currency, rates);
      if (usd == null) {
        netComplete = false;
      } else {
        net += usd;
      }
      list.add({
        'name': a.name,
        'kind': a.kind.name,
        'currency': a.currency,
        'balance': a.currency == baseCurrency ? _usd(cents) : Fx.format(cents, a.currency),
        if (a.currency != baseCurrency) 'balance_usd': usd == null ? null : _usd(usd),
      });
    }
    return {
      'accounts': list,
      'net_worth': _usd(net),
      if (!netComplete) 'note': 'Some accounts have no exchange rate and are left out of net worth.',
      'rates_per_usd': {
        for (final e in rates.entries)
          if (e.key != baseCurrency) e.key: e.value,
      },
    };
  }

  Future<Map<String, dynamic>> _goals() async {
    final goals = (await ledger.watchGoals().first).where((g) => !g.archived);
    final saved = await ledger.watchGoalSaved().first;
    return {
      'goals': [
        for (final g in goals)
          {
            'name': g.name,
            'target': _usd(g.targetCents),
            'saved': _usd(saved[g.id] ?? 0),
            'remaining': _usd((g.targetCents - (saved[g.id] ?? 0)).clamp(0, g.targetCents)),
            'target_date': g.targetDate,
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _recurring() async {
    final rules = (await ledger.watchRecurring().first).where((r) => r.isLive);
    final cats = await _categories();
    final accounts = await _accountsById();
    final rates = await _rates();
    return {
      'rules': [
        for (final r in rules)
          {
            'name': r.note.isNotEmpty ? r.note : cats[r.categoryId]?.name ?? 'Recurring',
            'type': r.type.name,
            'amount': () {
              final code = accounts[r.accountId]?.currency ?? baseCurrency;
              final usd = Fx.tryToUsd(r.amountCents, code, rates);
              return code == baseCurrency || usd == null ? Fx.format(r.amountCents, code) : _usd(usd);
            }(),
            'every': r.interval == 1 ? r.frequency.name : '${r.interval} × ${r.frequency.name}',
            'next_due': r.nextDue,
            'scope': r.scope.name,
            'category': cats[r.categoryId]?.name,
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _safeToSpend() async {
    final now = _clock();
    final month = DateTime(now.year, now.month);
    final p = planMonth(
      monthTxs: await ledger.transactions(TxQuery(from: Day.firstOfMonth(month), to: Day.lastOfMonth(month))),
      rules: await ledger.watchRecurring().first,
      accounts: await _accountsById(),
      rates: await _rates(),
      now: now,
    );
    if (!p.complete) return {'error': 'An exchange rate is missing, so the plan cannot be worked out.'};
    return {
      'income_so_far': _usd(p.income),
      'income_expected': _usd(p.incomeExpected),
      'spent': _usd(p.spent),
      'bills_still_due': _usd(p.committed),
      'left_to_spend': _usd(p.leftToSpend),
      'per_day': _usd(p.perDay),
      'days_left': p.daysLeft,
      'forecast_month_spend': _usd(p.forecastSpend),
      if (!p.meaningful) 'note': 'No income recorded or expected this month, so there is nothing to plan against.',
    };
  }
}

extension on AssistantTools {
  Future<Map<String, dynamic>> _draftEntry(Map<String, dynamic> a) async {
    final amount = a['amount'];
    if (amount is! num || amount <= 0 || amount > 1e12) throw _BadArg('amount must be a positive number');
    final currency = (a['currency'] as String? ?? baseCurrency).trim().toUpperCase();
    final type = switch (a['type']) {
      null || 'expense' => TxType.expense,
      'income' => TxType.income,
      _ => throw _BadArg('type must be expense or income'),
    };
    final accounts = (await ledger.watchAccounts().first).where((x) => !x.archived).toList();
    final wanted = (a['account'] as String?)?.trim().toLowerCase();
    final account = wanted != null && wanted.isNotEmpty
        ? accounts.where((x) => x.name.toLowerCase().contains(wanted)).firstOrNull ??
              (throw _BadArg(
                'No account matches "${a['account']}". Accounts: ${accounts.map((x) => x.name).join(', ')}',
              ))
        : accounts.where((x) => x.currency == currency).firstOrNull ??
              (throw _BadArg(
                'No $currency account. Accounts: ${accounts.map((x) => '${x.name} (${x.currency})').join(', ')}',
              ));
    if (account.currency != currency) {
      throw _BadArg('${account.name} holds ${account.currency}, not $currency');
    }
    final kind = type == TxType.income ? CategoryKind.income : CategoryKind.expense;
    Category? category;
    final catName = (a['category'] as String?)?.trim();
    if (catName != null && catName.isNotEmpty) {
      final ids = await _matchCategories(catName);
      final cats = await _categories();
      category = ids.map((id) => cats[id]!).where((k) => k.kind == kind && !k.archived).firstOrNull;
    }
    final day = _day(a, 'date', Day.of(_clock()));
    final scope = AssistantTools._scopeOf(a) ?? category?.defaultScope ?? Scope.personal;
    final draft = EntryDraft(
      type: type,
      amountCents: (amount * 100).round(),
      currency: currency,
      accountId: account.id,
      categoryId: category?.id,
      scope: scope,
      day: day,
      note: ((a['note'] as String?) ?? '').trim(),
    );
    _drafts.add(draft);
    return {
      'prepared': true,
      'saved': false,
      'summary':
          '${type.name} ${Fx.format(draft.amountCents, currency)} · ${category?.name ?? 'no category'} · '
          '${scope.name} · ${account.name} · $day${draft.note.isEmpty ? '' : ' · ${draft.note}'}',
      'tell_user': 'Shown as a card with a Log button; ask them to check it and tap Log.',
    };
  }
}

class _BadArg implements Exception {
  _BadArg(this.message);

  final String message;
}
