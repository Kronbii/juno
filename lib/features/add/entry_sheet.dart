import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/attachments/attachment_store.dart';
import 'package:juno/core/attachments/receipt_scanner.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/add/entry_extras.dart';
import 'package:juno/features/smart/entry_parser.dart';

/// Values to start a new entry with (from a deep link, a duplicate, …).
class EntryPrefill {
  const EntryPrefill({
    this.type,
    this.amountCents,
    this.categoryId,
    this.accountId,
    this.scope,
    this.note,
    this.day,
  });

  final TxType? type;
  final int? amountCents;
  final String? categoryId;
  final String? accountId;
  final Scope? scope;
  final String? note;
  final String? day;
}

/// Opens the entry editor: a bottom sheet on phones, a dialog on desktop.
Future<void> showEntrySheet(BuildContext context, {Transaction? edit, EntryPrefill? prefill}) {
  final wide = MediaQuery.sizeOf(context).width >= JSize.wideBreakpoint;
  final sheet = EntrySheet(edit: edit, prefill: prefill);
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 820),
          child: ClipRRect(borderRadius: BorderRadius.circular(JRadius.card), child: sheet),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    useRootNavigator: true,
    builder: (_) => sheet,
  );
}

class EntrySheet extends ConsumerStatefulWidget {
  const EntrySheet({this.edit, this.prefill, super.key});

  final Transaction? edit;
  final EntryPrefill? prefill;

  @override
  ConsumerState<EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends ConsumerState<EntrySheet> {
  late TxType _type;
  late Scope _scope;
  late String _amount;
  late String _day;
  String? _categoryId;
  String? _accountId;
  String? _toAccountId;
  late final TextEditingController _note;
  late final TextEditingController _tagInput = TextEditingController();
  late List<String> _tags;

  /// Receipts picked in this session, saved once the entry exists.
  final List<PendingFile> _pending = [];

  /// A new entry's id is fixed up front so receipts can point at it.
  late final String _id = widget.edit?.id ?? newId();

  /// Once the user picks a scope themselves, choosing a category stops
  /// overriding it with the category's default.
  bool _scopeTouched = false;
  bool _showAllCategories = false;
  List<String> _recent = const [];
  final _focus = FocusNode();

  bool get _editing => widget.edit != null;

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    final p = widget.prefill;
    _type = e?.type ?? p?.type ?? TxType.expense;
    _scope = e?.scope ?? p?.scope ?? ref.read(scopeFilterProvider) ?? Scope.personal;
    _scopeTouched = e != null || p?.scope != null;
    final cents = e?.amountCents ?? p?.amountCents;
    _amount = cents == null ? '' : _centsToBuffer(cents);
    _day = e?.occurredOn ?? p?.day ?? Day.today();
    _categoryId = e?.categoryId ?? p?.categoryId;
    _accountId = e?.accountId ?? p?.accountId;
    _toAccountId = e?.toAccountId;
    _note = TextEditingController(text: e?.note ?? p?.note ?? '');
    _tags = e == null ? [] : EntryTags.parse(e.tags);
    ref.read(ledgerProvider).recentCategoryIds().then((r) {
      if (mounted) setState(() => _recent = r);
    });
    ref.read(ledgerProvider).merchantCategoryMemory().then((m) => _memory = m);
  }

  /// True while the category was picked by a suggestion, not by you — a
  /// later suggestion may replace it; your own choice is never overridden.
  bool _categoryAuto = false;

  /// As you type a note, use the category you last used for it.
  void _suggestFromNote(String note) {
    if (_categoryId != null && !_categoryAuto) return;
    final key = note.trim().toLowerCase();
    if (key.length < 3) return;
    final wantKind = _type == TxType.income ? CategoryKind.income : CategoryKind.expense;
    final cats = ref.read(categoryMapProvider);
    var hit = _memory[key];
    if (hit == null) {
      var bestLen = 0;
      for (final e in _memory.entries) {
        if (e.key.length >= 3 && e.key.length > bestLen && (key.contains(e.key) || e.key.startsWith(key))) {
          hit = e.value;
          bestLen = e.key.length;
        }
      }
    }
    final cat = cats[hit];
    if (cat == null || cat.kind != wantKind || cat.id == _categoryId) return;
    setState(() {
      _categoryId = cat.id;
      _categoryAuto = true;
      if (!_scopeTouched) _scope = cat.defaultScope;
    });
  }

  // ---- quick text ----------------------------------------------------------
  final _quick = TextEditingController();
  Map<String, String> _memory = const {};

  /// Applies what the quick line understood. Fields it didn't mention keep
  /// whatever the user already set.
  void _applyQuick(String text) {
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    final e = parseEntry(
      text,
      categories: ref.read(categoriesProvider).value ?? const [],
      memory: _memory,
      hasLbpAccount: accounts.any((a) => a.currency == 'LBP'),
    );
    setState(() {
      if (e.type != null) _type = e.type!;
      if (e.amountCents != null) _amount = _centsToBuffer(e.amountCents!);
      if (e.categoryId != null) {
        _categoryId = e.categoryId;
        final cat = ref.read(categoryMapProvider)[e.categoryId];
        if (cat != null && !_scopeTouched && e.scope == null) _scope = cat.defaultScope;
      }
      if (e.scope != null) {
        _scope = e.scope!;
        _scopeTouched = true;
      }
      if (e.day != null) _day = e.day!;
      if (e.note.isNotEmpty) _note.text = e.note;
      // A currency in the text picks an account holding it.
      if (e.currency != null && _currencyOf(_accountId) != e.currency) {
        final match = accounts.where((a) => a.currency == e.currency).firstOrNull;
        if (match != null) _accountId = match.id;
      }
    });
  }

  @override
  void dispose() {
    _note.dispose();
    _quick.dispose();
    _tagInput.dispose();
    _focus.dispose();
    super.dispose();
  }

  static String _centsToBuffer(int cents) {
    final whole = cents ~/ 100;
    final frac = cents % 100;
    if (frac == 0) return '$whole';
    return frac % 10 == 0 ? '$whole.${frac ~/ 10}' : '$whole.${frac.toString().padLeft(2, '0')}';
  }

  int get _cents => Money.parse(_amount) ?? 0;

  void _key(String k) {
    HapticFeedback.selectionClick();
    setState(() {
      if (k == '⌫') {
        if (_amount.isNotEmpty) _amount = _amount.substring(0, _amount.length - 1);
        return;
      }
      if (k == '.') {
        if (!_amount.contains('.')) _amount = _amount.isEmpty ? '0.' : '$_amount.';
        return;
      }
      final dot = _amount.indexOf('.');
      if (dot >= 0 && _amount.length - dot > 2) return; // two decimals max
      // 11 whole digits: room for LBP amounts in the hundreds of millions.
      if (dot < 0 && _amount.replaceAll('.', '').length >= 11) return;
      _amount = _amount == '0' ? k : '$_amount$k';
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    // Typing in the note field must not also type into the amount.
    if (FocusManager.instance.primaryFocus != _focus) return KeyEventResult.ignored;
    final ch = e.character;
    if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
      _key(ch);
      return KeyEventResult.handled;
    }
    if (ch == '.' || ch == ',') {
      _key('.');
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace) {
      _key('⌫');
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter) {
      // A held Enter repeats; only the first press saves.
      if (e is KeyDownEvent) _save();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool get _hasAccount => (ref.read(accountsProvider).value ?? const []).isNotEmpty || _accountId != null;

  bool get _valid {
    if (_cents <= 0 || !_hasAccount) return false;
    if (_type == TxType.transfer) {
      return _accountId != null && _toAccountId != null && _accountId != _toAccountId;
    }
    return true;
  }

  bool _saving = false;

  /// Guarded: a double tap or a repeated Enter can't save twice, and any
  /// failure is reported instead of leaving the sheet stuck.
  Future<void> _save() async {
    if (!_valid || _saving) return;
    _saving = true;
    try {
      await _saveInner();
    } on Object catch (e) {
      showToast('Couldn’t save: $e');
    } finally {
      _saving = false;
    }
  }

  Future<void> _saveInner() async {
    final ledger = ref.read(ledgerProvider);
    final accounts = ref.read(accountsProvider).value ?? const [];
    final accountId = _accountId ?? (accounts.isEmpty ? null : accounts.first.id);
    if (accountId == null) return;
    final isTransfer = _type == TxType.transfer;
    final companion = TransactionsCompanion(
      type: Value(_type),
      scope: Value(_scope),
      amountCents: Value(_cents),
      accountId: Value(accountId),
      toAccountId: Value(isTransfer ? _toAccountId : null),
      categoryId: Value(isTransfer ? null : _categoryId),
      occurredOn: Value(_day),
      note: Value(_note.text.trim()),
      tags: Value(EntryTags.store([..._tags, ...EntryTags.fromInput(_tagInput.text)])),
    );
    unawaited(HapticFeedback.mediumImpact());
    final cat = ref.read(categoryMapProvider)[_categoryId];
    final currency = _currencyOf(accountId);
    final summary = [
      Fx.format(_cents, currency),
      if (!isTransfer) cat?.name ?? 'Uncategorised',
      if (!isTransfer) _scope.label,
    ].join(' · ');

    final store = AttachmentStore(ledger);
    Future<void> saveReceipts() async {
      for (final f in _pending) {
        await store.save(_id, f);
      }
    }

    if (_editing) {
      await ledger.updateTransaction(widget.edit!.id, companion);
      await saveReceipts();
      if (mounted) Navigator.of(context).pop();
      showToast('Updated $summary');
    } else {
      final id = await ledger.addTransaction(companion.copyWith(id: Value(_id)));
      await saveReceipts();
      if (mounted) Navigator.of(context).pop();
      showToast(
        '${_type == TxType.income
            ? 'Received'
            : isTransfer
            ? 'Moved'
            : 'Logged'} $summary',
        onUndo: () => ledger.deleteTransaction(id),
      );
    }
  }

  Future<void> _delete() async {
    final ledger = ref.read(ledgerProvider);
    final id = widget.edit!.id;
    await ledger.deleteTransaction(id);
    if (mounted) Navigator.of(context).pop();
    showToast('Entry deleted', onUndo: () => ledger.restoreTransaction(id));
  }

  Future<void> _pickDate() async {
    final current = Day.parse(_day);
    // The range always contains the entry's own date (imports and links can
    // carry any date), or the picker asserts.
    final first = current.isBefore(DateTime(2000)) ? current : DateTime(2000);
    final soon = DateTime.now().add(const Duration(days: 365));
    final last = current.isAfter(soon) ? current : soon;
    final picked = await showDatePicker(context: context, initialDate: current, firstDate: first, lastDate: last);
    if (picked != null) setState(() => _day = Day.of(picked));
  }

  /// "≈ $12.40" under a foreign amount; "they receive LBP 1.1M" for a
  /// transfer across currencies.
  String? _conversionHint() {
    final rates = ref.read(ratesProvider);
    final from = _currencyOf(_accountId);
    if (_cents <= 0) return from == baseCurrency ? null : '${currencyInfo(from).name} account';
    if (_type == TxType.transfer && _toAccountId != null) {
      final to = _currencyOf(_toAccountId);
      if (to != from) return 'Arrives as ~${Fx.format(Fx.convert(_cents, from, to, rates), to)}';
    }
    if (from == baseCurrency) return null;
    final usd = Fx.tryToUsd(_cents, from, rates);
    if (usd == null) return 'No $from rate yet — set it in Settings → Currencies';
    return '~${Money.format(usd)} at ${Fx.format(rates[from]! * 100 ~/ 1, from)} / \$1';
  }

  String _currencyOf(String? accountId) => ref.read(accountMapProvider)[accountId]?.currency ?? baseCurrency;

  Future<void> _addReceipt() async {
    final source = AttachmentStore.canUseCamera
        ? await showModalBottomSheet<PickSource>(
            context: context,
            useRootNavigator: true,
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: const Text('Take photo'),
                    onTap: () => Navigator.pop(ctx, PickSource.camera),
                  ),
                  ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: const Text('Choose from library'),
                    onTap: () => Navigator.pop(ctx, PickSource.library),
                  ),
                  ListTile(
                    leading: const Icon(Icons.folder_open_outlined),
                    title: const Text('Files'),
                    onTap: () => Navigator.pop(ctx, PickSource.files),
                  ),
                ],
              ),
            ),
          )
        : PickSource.files;
    if (source == null) return;
    final f = await AttachmentStore.pick(source);
    if (f == null || !mounted) return;
    setState(() => _pending.add(f));
    // Read the receipt on-device and fill what's still empty.
    final read = await ReceiptScanner.read(f.bytes);
    if (read == null || !mounted) return;
    setState(() {
      if (_cents == 0 && read.totalCents != null) {
        _amount = _centsToBuffer(read.totalCents!);
        final accounts = ref.read(accountsProvider).value ?? const <Account>[];
        if (read.currency != null && _currencyOf(_accountId) != read.currency) {
          final match = accounts.where((a) => a.currency == read.currency).firstOrNull;
          if (match != null) _accountId = match.id;
        }
      }
      if (read.day != null && read.day!.compareTo(Day.today()) <= 0) _day = read.day!;
      if (_note.text.isEmpty && read.merchant != null) _note.text = read.merchant!;
    });
    if (read.totalCents != null) {
      showToast(
        read.confident
            ? 'Read ${Fx.format(read.totalCents!, read.currency ?? _currencyOf(_accountId))} from the receipt'
            : 'Best guess from the receipt: ${Fx.format(read.totalCents!, read.currency ?? _currencyOf(_accountId))} — check it',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    _accountId ??= accounts.firstOrNull?.id;

    final typeAccent = switch (_type) {
      TxType.expense => JAccent.expense,
      TxType.income => JAccent.income,
      TxType.transfer => JAccent.brand,
    };

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Material(
        color: c.bg,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(JSpace.page, JSpace.md, JSpace.page, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(child: JEyebrow(_editing ? 'Edit entry' : 'New entry')),
                          if (_editing)
                            JIconButton(
                              icon: Icons.delete_outline_rounded,
                              tooltip: 'Delete',
                              color: c.expense,
                              size: 38,
                              onPressed: _delete,
                            ),
                        ],
                      ),
                      if (!_editing) ...[
                        const SizedBox(height: JSpace.md),
                        TextField(
                          controller: _quick,
                          textInputAction: TextInputAction.done,
                          style: JType.body.copyWith(fontSize: 15, color: c.ink),
                          decoration: InputDecoration(
                            hintText: 'Type it — “12 coffee kalei”, “40k taxi yesterday”',
                            prefixIcon: Icon(Icons.auto_awesome_outlined, size: 17, color: c.inkFaint),
                          ),
                          onChanged: _applyQuick,
                          onSubmitted: (_) => _save(),
                        ),
                      ],
                      const SizedBox(height: JSpace.md),
                      JSegmentBar<TxType>(
                        segments: const {
                          TxType.expense: 'Expense',
                          TxType.income: 'Income',
                          TxType.transfer: 'Transfer',
                        },
                        selected: _type,
                        accentOf: (t) => switch (t) {
                          TxType.expense => JAccent.expense,
                          TxType.income => JAccent.income,
                          TxType.transfer => JAccent.brand,
                        },
                        onChanged: (t) => setState(() {
                          _type = t;
                          final cat = ref.read(categoryMapProvider)[_categoryId];
                          final wantKind = t == TxType.income ? CategoryKind.income : CategoryKind.expense;
                          if (cat != null && cat.kind != wantKind) _categoryId = null;
                        }),
                      ),
                      const SizedBox(height: JSpace.xl),
                      _AmountDisplay(
                        amount: _amount,
                        accent: typeAccent.of(c),
                        currency: _currencyOf(_accountId),
                        hint: _conversionHint(),
                      ),
                      const SizedBox(height: JSpace.lg),
                      if (_type != TxType.transfer)
                        Center(
                          child: ScopeToggle(
                            value: _scope,
                            onChanged: (s) => setState(() {
                              _scope = s;
                              _scopeTouched = true;
                            }),
                          ),
                        ),
                      const SizedBox(height: JSpace.xl),
                      if (_type == TxType.transfer)
                        _TransferAccounts(
                          accounts: accounts,
                          from: _accountId,
                          to: _toAccountId,
                          onFrom: (id) => setState(() => _accountId = id),
                          onTo: (id) => setState(() => _toAccountId = id),
                        )
                      else
                        _CategoryGrid(
                          categories: categories
                              .where(
                                (k) => k.kind == (_type == TxType.income ? CategoryKind.income : CategoryKind.expense),
                              )
                              .toList(),
                          recent: _recent,
                          selected: _categoryId,
                          expanded: _showAllCategories,
                          onExpand: () => setState(() => _showAllCategories = true),
                          onSelected: (k) => setState(() {
                            _categoryId = k.id;
                            _categoryAuto = false;
                            if (!_scopeTouched) _scope = k.defaultScope;
                          }),
                        ),
                      const SizedBox(height: JSpace.lg),
                      Wrap(
                        spacing: JSpace.sm,
                        runSpacing: JSpace.sm,
                        children: [
                          _MetaChip(icon: Icons.calendar_today_outlined, label: Day.relative(_day), onTap: _pickDate),
                          if (_type != TxType.transfer)
                            _AccountMenu(
                              accounts: accounts,
                              selected: _accountId,
                              onSelected: (id) => setState(() => _accountId = id),
                            ),
                        ],
                      ),
                      const SizedBox(height: JSpace.md),
                      TextField(
                        controller: _note,
                        textCapitalization: TextCapitalization.sentences,
                        style: JType.body.copyWith(fontSize: 15, color: c.ink),
                        decoration: const InputDecoration(hintText: 'Note — where, what, who'),
                        onChanged: _suggestFromNote,
                        onSubmitted: (_) => _save(),
                      ),
                      const SizedBox(height: JSpace.md),
                      TagEditor(
                        tags: _tags,
                        input: _tagInput,
                        onChanged: (t) => setState(() => _tags = t),
                      ),
                      const SizedBox(height: JSpace.md),
                      ReceiptsStrip(
                        transactionId: _editing ? _id : null,
                        pending: _pending,
                        onAdd: _addReceipt,
                        onRemovePending: (f) => setState(() => _pending.remove(f)),
                      ),
                      const SizedBox(height: JSpace.lg),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(JSpace.page, 0, JSpace.page, JSpace.md),
                child: Column(
                  children: [
                    _AmountPad(onKey: _key),
                    const SizedBox(height: JSpace.md),
                    JButton(
                      label: !_hasAccount
                          ? 'Add an account first (Settings → Accounts)'
                          : _cents > 0
                          ? '${_editing ? 'Save' : 'Log'} ${Fx.format(_cents, _currencyOf(_accountId))}'
                          : 'Enter an amount',
                      accent: typeAccent,
                      expand: true,
                      onPressed: _valid ? _save : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AmountDisplay extends StatelessWidget {
  const _AmountDisplay({required this.amount, required this.accent, this.currency = baseCurrency, this.hint});

  final String amount;
  final Color accent;
  final String currency;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final empty = amount.isEmpty;
    final parts = (empty ? '0' : amount).split('.');
    final whole = int.tryParse(parts[0]) ?? 0;
    final wholeText = whole.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    final frac = parts.length > 1 ? '.${parts[1]}' : '';
    return Semantics(
      liveRegion: true,
      label: 'Amount ${empty ? 'zero' : amount} ${currencyInfo(currency).name}',
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  currencyInfo(currency).symbol ?? currency,
                  style: JType.panelMetric.copyWith(
                    color: c.inkFaint,
                    fontSize: currencyInfo(currency).symbol == null ? 20 : 30,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '$wholeText$frac',
                  style: JType.heroMetric.copyWith(
                    fontSize: 64,
                    letterSpacing: -3.5,
                    color: empty ? c.inkFaint : c.ink,
                  ),
                ),
                AnimatedContainer(
                  duration: JMotion.fast,
                  margin: const EdgeInsets.only(left: 4),
                  width: 2,
                  height: 46,
                  color: accent,
                ),
              ],
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(hint!, style: JType.chipLabel.copyWith(color: c.inkMuted)),
          ],
        ],
      ),
    );
  }
}

/// Personal ⇄ Household. Two pills, each in its own scope colour, so the
/// choice reads before you look at the words.
class ScopeToggle extends StatelessWidget {
  const ScopeToggle({required this.value, required this.onChanged, super.key});

  final Scope value;
  final ValueChanged<Scope> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final s in Scope.values) ...[
        if (s != Scope.values.first) const SizedBox(width: JSpace.sm),
        JChip(
          label: s.label,
          selected: s == value,
          accent: s == Scope.personal ? JAccent.brand : JAccent.household,
          leading: Icon(
            s == Scope.personal ? Icons.person_outline_rounded : Icons.home_outlined,
            size: 15,
            color: s == value ? (s == Scope.personal ? context.jc.brand : context.jc.household) : context.jc.inkFaint,
          ),
          onTap: () {
            HapticFeedback.selectionClick();
            onChanged(s);
          },
        ),
      ],
    ],
  );
}

class _CategoryGrid extends StatelessWidget {
  const _CategoryGrid({
    required this.categories,
    required this.recent,
    required this.selected,
    required this.expanded,
    required this.onExpand,
    required this.onSelected,
  });

  final List<Category> categories;
  final List<String> recent;
  final String? selected;
  final bool expanded;
  final VoidCallback onExpand;
  final ValueChanged<Category> onSelected;

  static const _collapsedCount = 8;

  @override
  Widget build(BuildContext context) {
    final rank = {for (var i = 0; i < recent.length; i++) recent[i]: i};
    final ordered = [...categories]
      ..sort((a, b) {
        final ra = rank[a.id] ?? 1 << 20;
        final rb = rank[b.id] ?? 1 << 20;
        return ra != rb ? ra.compareTo(rb) : a.sort.compareTo(b.sort);
      });
    var shown = expanded ? ordered : ordered.take(_collapsedCount).toList();
    // Keep the selected category visible even when it is not in the top set.
    if (!expanded && selected != null && !shown.any((k) => k.id == selected)) {
      final sel = ordered.where((k) => k.id == selected);
      shown = [...sel, ...shown.take(_collapsedCount - 1)];
    }
    final more = !expanded && ordered.length > shown.length;

    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth > 400 ? 5 : 4;
        final w = (box.maxWidth - (cols - 1) * JSpace.sm) / cols;
        return Wrap(
          spacing: JSpace.sm,
          runSpacing: JSpace.sm,
          children: [
            for (final k in shown)
              SizedBox(
                width: w,
                child: _CategoryCell(category: k, selected: k.id == selected, onTap: () => onSelected(k)),
              ),
            if (more)
              SizedBox(
                width: w,
                child: _MoreCell(onTap: onExpand, count: ordered.length - shown.length),
              ),
          ],
        );
      },
    );
  }
}

class _CategoryCell extends StatelessWidget {
  const _CategoryCell({required this.category, required this.selected, required this.onTap});

  final Category category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final color = seriesColor(c, category.colorIndex);
    return Semantics(
      selected: selected,
      button: true,
      label: category.name,
      child: Material(
        color: selected ? c.tint(color) : c.surface,
        borderRadius: BorderRadius.circular(JRadius.chip),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: JMotion.fast,
            height: 78,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(JRadius.chip),
              border: Border.all(color: selected ? color : c.hairline),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(categoryIcon(category.icon), size: 20, color: selected ? color : c.inkMuted),
                const SizedBox(height: 6),
                _CellLabel(category.name, color: selected ? c.ink : c.inkMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreCell extends StatelessWidget {
  const _MoreCell({required this.onTap, required this.count});

  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(JRadius.chip),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 78,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(JRadius.chip),
            border: Border.all(color: c.hairline),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.grid_view_rounded, size: 18, color: c.inkFaint),
              const SizedBox(height: 7),
              Text('+$count more', style: JType.microLabel.copyWith(color: c.inkFaint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TransferAccounts extends StatelessWidget {
  const _TransferAccounts({
    required this.accounts,
    required this.from,
    required this.to,
    required this.onFrom,
    required this.onTo,
  });

  final List<Account> accounts;
  final String? from;
  final String? to;
  final ValueChanged<String> onFrom;
  final ValueChanged<String> onTo;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    Widget column(String label, String? sel, ValueChanged<String> on) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: JType.microLabel.copyWith(color: c.inkFaint)),
          const SizedBox(height: JSpace.sm),
          for (final a in accounts)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: JChip(label: a.name, selected: a.id == sel, onTap: () => on(a.id)),
            ),
        ],
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        column('From', from, onFrom),
        Padding(
          padding: const EdgeInsets.only(top: 28, left: 8, right: 8),
          child: Icon(Icons.arrow_forward_rounded, size: 18, color: c.inkFaint),
        ),
        column('To', to, onTo),
      ],
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => JChip(
    label: label,
    selected: false,
    onTap: onTap,
    leading: Icon(icon, size: 14, color: context.jc.inkFaint),
  );
}

class _AccountMenu extends StatelessWidget {
  const _AccountMenu({required this.accounts, required this.selected, required this.onSelected});

  final List<Account> accounts;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final current = accounts.where((a) => a.id == selected).firstOrNull;
    return PopupMenuButton<String>(
      tooltip: 'Account',
      onSelected: onSelected,
      itemBuilder: (_) => [for (final a in accounts) PopupMenuItem(value: a.id, child: Text(a.name))],
      child: IgnorePointer(
        child: _MetaChip(
          icon: Icons.account_balance_wallet_outlined,
          label: current?.name ?? 'Account',
          onTap: () {},
        ),
      ),
    );
  }
}

/// The numeric keypad. Hairline keys, mono digits; on desktop the physical
/// keyboard drives the same buffer.
class _AmountPad extends StatelessWidget {
  const _AmountPad({required this.onKey});

  final ValueChanged<String> onKey;

  static const _keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', '⌫'];

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return LayoutBuilder(
      builder: (context, box) {
        final w = (box.maxWidth - 2 * JSpace.sm) / 3;
        return Wrap(
          spacing: JSpace.sm,
          runSpacing: JSpace.sm,
          children: [
            for (final k in _keys)
              SizedBox(
                width: w,
                height: 50,
                child: Material(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(JRadius.chip),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onKey(k),
                    onLongPress: k == '⌫'
                        ? () {
                            for (var i = 0; i < 12; i++) {
                              onKey('⌫');
                            }
                          }
                        : null,
                    child: Center(
                      child: k == '⌫'
                          ? Icon(Icons.backspace_outlined, size: 19, color: c.inkMuted)
                          : Text(k, style: JType.cardMetric.copyWith(fontSize: 20, color: c.ink)),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A category name in a grid cell: multi-word names wrap to two lines; a
/// single long word ("Subscriptions") shrinks to fit rather than breaking
/// mid-word.
class _CellLabel extends StatelessWidget {
  const _CellLabel(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = JType.body.copyWith(fontSize: 11, height: 1.15, fontWeight: FontWeight.w600, color: color);
    if (!text.trim().contains(' ')) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(text, maxLines: 1, style: style),
      );
    }
    return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: style);
  }
}
