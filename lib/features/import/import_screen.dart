import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/db/ledger.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/add/entry_sheet.dart' show ScopeToggle;
import 'package:juno/features/import/csv_import.dart';
import 'package:juno/features/plan/editors.dart' show AccountPicker;
import 'package:juno/features/settings/ai_screen.dart' show aiAssistProvider;

/// Import a bank CSV: pick → map columns → review → commit (undoable).
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  String? _filename;
  CsvTable? _table;
  ColumnMapping _mapping = const ColumnMapping();
  List<ImportRow> _rows = const [];
  bool _categorizing = false;
  String? _accountId;
  Scope _scope = Scope.personal;
  bool _busy = false;
  Uint8List? _xlsx;
  List<String> _sheets = const [];
  String? _sheet;

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Choose a bank CSV',
      type: FileType.custom,
      allowedExtensions: const ['csv', 'txt', 'tsv', 'xlsx'],
    );
    if (files.isEmpty) return;
    final bytes = await files.first.readAsBytes();
    final name = files.first.name;
    CsvTable table;
    if (name.toLowerCase().endsWith('.xlsx')) {
      try {
        _sheets = CsvTable.xlsxSheets(bytes);
        table = CsvTable.fromXlsx(bytes);
      } on Object {
        showToast('Couldn’t read that Excel file — try exporting it as CSV');
        return;
      }
      _xlsx = bytes;
      _sheet = null;
    } else {
      _xlsx = null;
      _sheets = const [];
      String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        text = latin1.decode(bytes);
      }
      table = CsvTable.parse(text);
    }
    setState(() {
      _filename = files.first.name;
      _table = table;
      _mapping = ColumnMapping.guess(table);
    });
    await _rebuild();
  }

  Future<void> _rebuild() async {
    final t = _table;
    if (t == null || !_mapping.isComplete) {
      setState(() => _rows = const []);
      return;
    }
    final ledger = ref.read(ledgerProvider);
    final rows = buildRows(
      table: t,
      mapping: _mapping,
      existingHashes: await ledger.existingDedupeHashes(),
      memory: await ledger.merchantCategoryMemory(),
      categories: ref.read(categoriesProvider).value ?? const [],
      accountId: _accountId ?? ref.read(accountsProvider).value?.firstOrNull?.id ?? '',
    );
    if (mounted) setState(() => _rows = rows);
  }

  void _remap(ColumnMapping m) {
    setState(() => _mapping = m);
    _rebuild();
  }

  /// Rows still without a category, which the AI can try to place.
  List<ImportRow> get _uncategorised =>
      _rows.where((r) => r.include && r.error == null && r.categoryId == null).toList();

  Future<void> _suggest() async {
    final todo = _uncategorised;
    if (todo.isEmpty || _categorizing) return;
    final cats = ref.read(categoriesProvider).value ?? const <Category>[];
    setState(() => _categorizing = true);
    final names = await ref
        .read(aiAssistProvider)
        .categorize(
          [for (final r in todo) (r.description, r.type == TxType.income)],
          expenseCategories: [for (final k in cats.where((k) => k.kind == CategoryKind.expense)) k.name],
          incomeCategories: [for (final k in cats.where((k) => k.kind == CategoryKind.income)) k.name],
        );
    if (!mounted) return;
    final placed = applyCategorySuggestions(todo, names, cats);
    setState(() => _categorizing = false);
    showToast(
      placed == 0
          ? 'AI couldn’t place these — pick them below'
          : 'AI suggested categories for $placed ${placed == 1 ? 'entry' : 'entries'} — check them below',
    );
  }

  Future<void> _commit() async {
    final ledger = ref.read(ledgerProvider);
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    final account = _accountId ?? accounts.firstOrNull?.id;
    if (account == null) {
      showToast('Add an account first (Settings → Accounts)');
      return;
    }
    final chosen = _rows.where((r) => r.include && r.error == null).toList();
    if (chosen.isEmpty) return;
    setState(() => _busy = true);
    try {
      final cats = ref.read(categoryMapProvider);
      final batch = await ledger.commitImport(_filename ?? 'import.csv', [
        for (final r in chosen)
          TransactionsCompanion.insert(
            type: r.type,
            // A category with a household default pulls its rows into the
            // household scope; everything else takes the chosen default.
            scope: cats[r.categoryId]?.defaultScope == Scope.household ? Scope.household : _scope,
            amountCents: r.cents!.abs(),
            accountId: account,
            categoryId: Value(r.categoryId),
            occurredOn: r.day!,
            merchant: Value(r.description),
            dedupeHash: Value(r.hash),
          ),
      ]);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _table = null;
        _rows = const [];
        _filename = null;
      });
      showToast(
        'Imported ${chosen.length} entries',
        onUndo: () => ledger.undoImport(batch),
        duration: const Duration(seconds: 8),
      );
    } on Object catch (e) {
      showToast('Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final ledger = ref.read(ledgerProvider);
    final txs = await ledger.transactions(const TxQuery());
    final csv = exportCsv(txs, ref.read(categoryMapProvider), ref.read(accountMapProvider));
    final uri = await FilePicker.saveFile(
      fileName: 'juno-${Day.today()}.csv',
      bytes: Uint8List.fromList(utf8.encode(csv)),
      mimeType: 'text/csv',
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (uri != null) showToast('Exported ${txs.length} entries');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final t = _table;
    final included = _rows.where((r) => r.include).length;
    final dupes = _rows.where((r) => r.duplicate).length;
    final errors = _rows.where((r) => r.error != null).length;

    return JScreen(
      eyebrow: 'Settings · Import',
      title: 'Bring your *bank* in',
      subtitle:
          'CSV or Excel from any bank, card, Notion or your own sheet. Juno guesses the columns, learns your categories, and skips rows it has seen.',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: JSpace.sm,
                runSpacing: JSpace.sm,
                children: [
                  JButton(
                    label: t == null ? 'Choose CSV or Excel' : 'Choose another',
                    icon: Icons.upload_file_rounded,
                    kind: t == null ? JButtonKind.primary : JButtonKind.secondary,
                    onPressed: _pick,
                  ),
                  JButton(
                    label: 'Export all',
                    icon: Icons.download_rounded,
                    kind: JButtonKind.ghost,
                    onPressed: _export,
                  ),
                ],
              ),
              if (t != null) ...[
                const SizedBox(height: JSpace.xl),
                if (_sheets.length > 1) ...[
                  JChipBar(
                    labels: _sheets,
                    selectedIndex: _sheet == null ? 0 : _sheets.indexOf(_sheet!),
                    onSelected: (i) {
                      final t2 = CsvTable.fromXlsx(_xlsx!, sheet: _sheets[i]);
                      setState(() {
                        _sheet = _sheets[i];
                        _table = t2;
                        _mapping = ColumnMapping.guess(t2);
                      });
                      _rebuild();
                    },
                  ),
                  const SizedBox(height: JSpace.gap),
                ],
                _MappingCard(
                  filename: _filename ?? '',
                  table: t,
                  mapping: _mapping,
                  onChanged: _remap,
                ),
                const SizedBox(height: JSpace.gap),
                JCard(
                  title: 'Into',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      JField(
                        label: 'Account',
                        child: AccountPicker(
                          value: _accountId,
                          onChanged: (v) {
                            setState(() => _accountId = v);
                            _rebuild(); // duplicates are per account
                          },
                        ),
                      ),
                      JField(
                        label: 'Default scope',
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ScopeToggle(value: _scope, onChanged: (s) => setState(() => _scope = s)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: JSpace.gap),
                if (!_mapping.isComplete)
                  JCard(
                    accent: JAccent.warn,
                    alert: true,
                    child: Text(
                      'Pick a date column, a date format and an amount column to preview.',
                      style: JType.body.copyWith(color: c.ink),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: JMicroStat(value: '$included', label: 'To import'),
                      ),
                      Expanded(
                        child: JMicroStat(value: '$dupes', label: 'Already in', valueColor: dupes > 0 ? c.warn : null),
                      ),
                      Expanded(
                        child: JMicroStat(
                          value: '$errors',
                          label: 'Unreadable',
                          valueColor: errors > 0 ? c.expense : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: JSpace.lg),
                  JButton(
                    label: _busy ? 'Importing…' : 'Import $included entries',
                    expand: true,
                    onPressed: included == 0 || _busy ? null : _commit,
                  ),
                  if (_uncategorised.isNotEmpty && ref.watch(aiAssistProvider).enabled) ...[
                    const SizedBox(height: JSpace.lg),
                    JCard(
                      accent: JAccent.household,
                      title: '${_uncategorised.length} without a category',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Juno didn’t recognise these. AI can suggest categories from the descriptions alone — '
                            'nothing else is sent, and you can change any of them before importing.',
                            style: JType.body.copyWith(fontSize: 13.5, color: c.ink),
                          ),
                          const SizedBox(height: JSpace.md),
                          JButton(
                            label: _categorizing ? 'Suggesting…' : 'Suggest with AI',
                            icon: Icons.auto_awesome_outlined,
                            dense: true,
                            onPressed: _categorizing ? null : _suggest,
                          ),
                        ],
                      ),
                    ),
                  ],
                  const JSectionLabel('Review'),
                  _PreviewList(rows: _rows, onChanged: () => setState(() {})),
                ],
              ],
              const _PastImports(),
            ],
          ),
        ),
      ],
    );
  }
}

class _MappingCard extends StatelessWidget {
  const _MappingCard({required this.filename, required this.table, required this.mapping, required this.onChanged});

  final String filename;
  final CsvTable table;
  final ColumnMapping mapping;
  final ValueChanged<ColumnMapping> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final sample = table.rows.isEmpty ? <String>[] : table.rows.first;

    Widget column(String label, int? value, ValueChanged<int?> on, {bool optional = false}) => JField(
      label: label,
      child: DropdownButtonFormField<int?>(
        initialValue: value,
        isExpanded: true,
        dropdownColor: c.raised,
        style: JType.body.copyWith(fontSize: 14, color: c.ink),
        items: [
          if (optional) const DropdownMenuItem(child: Text('—')),
          for (var i = 0; i < table.headers.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(
                '${table.headers[i]}${i < sample.length && sample[i].isNotEmpty ? '  ·  ${sample[i]}' : ''}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: on,
      ),
    );

    final dateSamples = mapping.date == null ? const <String>[] : table.rows.map((r) => r[mapping.date!]).toList();
    final workingFormats = DateFormats.candidates
        .where((f) => dateSamples.where((v) => v.isNotEmpty).take(50).every((v) => DateFormats.tryParse(v, f) != null))
        .toList();

    return JCard(
      title: filename,
      trailing: JPill('${table.rows.length} rows'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          column('Date column', mapping.date, (v) {
            final f = v == null ? null : DateFormats.detect(table.rows.map((r) => r[v]));
            onChanged(
              ColumnMapping(
                date: v,
                description: mapping.description,
                amount: mapping.amount,
                debit: mapping.debit,
                credit: mapping.credit,
                category: mapping.category,
                mode: mapping.mode,
                dateFormat: f,
              ),
            );
          }),
          JField(
            label: 'Date format',
            child: DropdownButtonFormField<String?>(
              key: ValueKey('${mapping.date}-${mapping.dateFormat}'),
              initialValue: mapping.dateFormat,
              isExpanded: true,
              dropdownColor: c.raised,
              style: JType.chipLabel.copyWith(fontSize: 14, color: c.ink),
              hint: const Text('Pick a format'),
              items: [
                for (final f in DateFormats.candidates)
                  DropdownMenuItem(
                    value: f,
                    child: Text(workingFormats.contains(f) ? '$f  (fits)' : f),
                  ),
              ],
              onChanged: (f) => onChanged(mapping.copyWith(dateFormat: f)),
            ),
          ),
          if (mapping.dateFormat != null && DateFormats.isAmbiguous(dateSamples, mapping.dateFormat!))
            Padding(
              padding: const EdgeInsets.only(bottom: JSpace.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: c.warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'These dates read both day-first and month-first. Juno chose ${mapping.dateFormat}; '
                      'check a row below (e.g. ${dateSamples.firstOrNull ?? ''}) and switch if it’s wrong.',
                      style: JType.body.copyWith(fontSize: 12.5, color: c.ink),
                    ),
                  ),
                ],
              ),
            ),
          column('Description', mapping.description, (v) => onChanged(mapping.withColumn('description', v))),
          column(
            'Category (optional)',
            mapping.category,
            (v) => onChanged(mapping.withColumn('category', v)),
            optional: true,
          ),
          JField(
            label: 'Amounts',
            child: JSegmentBar<AmountMode>(
              segments: const {
                AmountMode.signedNegativeOut: '− is out',
                AmountMode.signedPositiveOut: '+ is out',
                AmountMode.debitCredit: 'Debit/credit',
              },
              selected: mapping.mode,
              onChanged: (m) => onChanged(mapping.copyWith(mode: m)),
            ),
          ),
          if (mapping.mode == AmountMode.debitCredit) ...[
            column('Debit (out)', mapping.debit, (v) => onChanged(mapping.withColumn('debit', v)), optional: true),
            column('Credit (in)', mapping.credit, (v) => onChanged(mapping.withColumn('credit', v)), optional: true),
          ] else
            column('Amount', mapping.amount, (v) => onChanged(mapping.withColumn('amount', v))),
        ],
      ),
    );
  }
}

class _PreviewList extends ConsumerWidget {
  const _PreviewList({required this.rows, required this.onChanged});

  final List<ImportRow> rows;
  final VoidCallback onChanged;

  static const _max = 400;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final cats = ref.watch(categoryMapProvider);
    final allCats = ref.watch(categoriesProvider).value ?? const <Category>[];

    Future<void> pickCategory(ImportRow r) async {
      final kind = r.type == TxType.income ? CategoryKind.income : CategoryKind.expense;
      final picked = await showJSheet<String>(
        context,
        title: 'Category for *this*',
        child: Builder(
          // The sheet lives on the root navigator; pop with its own context.
          builder: (sheet) => Wrap(
            spacing: JSpace.sm,
            runSpacing: JSpace.sm,
            children: [
              for (final k in allCats.where((k) => k.kind == kind))
                JChip(
                  label: k.name,
                  selected: k.id == r.categoryId,
                  leading: Icon(categoryIcon(k.icon), size: 14, color: seriesColor(c, k.colorIndex)),
                  onTap: () => Navigator.of(sheet).pop(k.id),
                ),
            ],
          ),
        ),
      );
      if (picked != null) {
        // Apply to every row with the same description — one decision per
        // merchant, not per line.
        final key = r.description.toLowerCase().trim();
        for (final o in rows) {
          if (o.description.toLowerCase().trim() == key && o.type == r.type) {
            o
              ..categoryId = picked
              ..aiSuggested = false;
          }
        }
        onChanged();
      }
    }

    return JGroup(
      children: [
        for (final r in rows.take(_max))
          Opacity(
            opacity: r.include ? 1 : 0.45,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, JSpace.card, 6),
              child: Row(
                children: [
                  Checkbox(
                    value: r.include,
                    onChanged: r.error != null
                        ? null
                        : (v) {
                            r.include = v ?? false;
                            onChanged();
                          },
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.description.isEmpty ? '(no description)' : r.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: JType.bodyStrong.copyWith(color: c.ink, fontSize: 13.5),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Text(
                              r.day == null ? '—' : Day.short(r.day!).toUpperCase(),
                              style: JType.microLabel.copyWith(color: c.inkFaint),
                            ),
                            const SizedBox(width: 8),
                            if (r.error != null)
                              JPill(r.error!, color: c.expense)
                            else if (r.duplicate)
                              JPill('Already imported', color: c.warn)
                            else if (r.aiSuggested) ...[
                              JPill('AI', color: c.household),
                              const SizedBox(width: 6),
                            ],
                            if (r.error == null && !r.duplicate)
                              InkWell(
                                onTap: () => pickCategory(r),
                                child: Text(
                                  cats[r.categoryId]?.name ?? 'Choose category',
                                  style: JType.body.copyWith(
                                    fontSize: 12,
                                    color: r.categoryId == null ? c.brand : c.inkMuted,
                                    decoration: TextDecoration.underline,
                                    decorationColor: c.hairlineStrong,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Text(
                    r.cents == null ? '—' : Money.signed(r.cents!),
                    style: JType.rowMetric.copyWith(
                      fontSize: 13,
                      color: (r.cents ?? 0) > 0 ? c.income : c.ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (rows.length > _max)
          Padding(
            padding: const EdgeInsets.all(JSpace.card),
            child: Text(
              '+ ${rows.length - _max} more rows (imported with the same rules)',
              style: JType.body.copyWith(color: c.inkFaint),
            ),
          ),
      ],
    );
  }
}

class _PastImports extends ConsumerWidget {
  const _PastImports();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final batches = ref.watch(importsProvider).value ?? const <ImportBatche>[];
    if (batches.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const JSectionLabel('Past imports', top: JSpace.xxl),
        JGroup(
          children: [
            for (final b in batches)
              JSettingRow(
                icon: Icons.description_outlined,
                title: b.filename,
                subtitle: '${b.rowCount} entries · ${Day.relative(Day.of(b.createdAt.toLocal()))}',
                trailing: JButton(
                  label: 'Undo',
                  kind: JButtonKind.ghost,
                  accent: JAccent.expense,
                  dense: true,
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Undo this import?'),
                        content: Text(
                          'Removes the ${b.rowCount} entries that came from ${b.filename}.',
                          style: JType.body.copyWith(color: c.inkMuted),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Undo import')),
                        ],
                      ),
                    );
                    if (ok ?? false) await ref.read(ledgerProvider).undoImport(b.id);
                  },
                ),
              ),
          ],
        ),
      ],
    );
  }
}
