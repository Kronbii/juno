import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';

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
    ref.read(ledgerProvider).recentCategoryIds().then((r) {
      if (mounted) setState(() => _recent = r);
    });
  }

  @override
  void dispose() {
    _note.dispose();
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
      if (dot < 0 && _amount.replaceAll('.', '').length >= 8) return;
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
      _save();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool get _valid {
    if (_cents <= 0) return false;
    if (_type == TxType.transfer) {
      return _accountId != null && _toAccountId != null && _accountId != _toAccountId;
    }
    return true;
  }

  Future<void> _save() async {
    if (!_valid) return;
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
    );
    unawaited(HapticFeedback.mediumImpact());
    final cat = ref.read(categoryMapProvider)[_categoryId];
    final summary = [
      Money.format(_cents),
      if (!isTransfer) cat?.name ?? 'Uncategorised',
      if (!isTransfer) _scope.label,
    ].join(' · ');

    if (_editing) {
      await ledger.updateTransaction(widget.edit!.id, companion);
      if (mounted) Navigator.of(context).pop();
      showToast('Updated $summary');
    } else {
      final id = await ledger.addTransaction(companion);
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
    final picked = await showDatePicker(
      context: context,
      initialDate: Day.parse(_day),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _day = Day.of(picked));
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
                      _AmountDisplay(amount: _amount, accent: typeAccent.of(c)),
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
                        onSubmitted: (_) => _save(),
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
                      label: _cents > 0 ? '${_editing ? 'Save' : 'Log'} ${Money.format(_cents)}' : 'Enter an amount',
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
  const _AmountDisplay({required this.amount, required this.accent});

  final String amount;
  final Color accent;

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
      label: 'Amount ${empty ? 'zero' : amount} dollars',
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(r'$', style: JType.panelMetric.copyWith(color: c.inkFaint, fontSize: 30)),
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
      return FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, style: style));
    }
    return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: style);
  }
}
