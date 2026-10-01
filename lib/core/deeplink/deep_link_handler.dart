import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/app/router.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/deeplink/quick_add.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/money.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/features/add/entry_sheet.dart';
import 'package:juno/features/smart/entry_parser.dart';

/// Listens for `juno://add` links (cold start and while running) and either
/// saves the entry or opens the add sheet prefilled.
class DeepLinkHandler extends ConsumerStatefulWidget {
  const DeepLinkHandler({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<DeepLinkHandler> createState() => _DeepLinkHandlerState();
}

class _DeepLinkHandlerState extends ConsumerState<DeepLinkHandler> {
  StreamSubscription<Uri>? _sub;

  /// iOS can deliver the same cold-start link through both the initial-link
  /// call and the stream; one save per link.
  Uri? _last;
  DateTime _lastAt = DateTime(0);

  @override
  void initState() {
    super.initState();
    // The OS delivers juno:// links on iOS (and macOS). Linux has no URL
    // handler, so desktop uses the in-app tester in Settings → Back Tap.
    final apple = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;
    if (kIsWeb || !apple) return;
    final links = AppLinks();
    _sub = links.uriLinkStream.listen(_onLink, onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onLink(Uri uri) {
    final now = DateTime.now();
    if (uri == _last && now.difference(_lastAt) < const Duration(seconds: 3)) return;
    _last = uri;
    _lastAt = now;
    // Let the first frame (and the router) settle on cold start.
    WidgetsBinding.instance.addPostFrameCallback((_) => handleQuickAdd(ref, uri));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Applies a quick-add link. Public so Settings → Back Tap can test links on
/// desktop, where the OS can't deliver them.
Future<void> handleQuickAdd(WidgetRef ref, Uri uri) async {
  final parsed = QuickAdd.parse(uri);
  if (parsed == null) return;
  final q = parsed.text != null ? await _fromText(ref, parsed) : parsed;

  // Wait for the first emission of the catalog streams on cold start.
  final categories = await ref.read(categoriesProvider.future);
  final accounts = await ref.read(accountsProvider.future);

  // Without an explicit type, the category decides: "Salary" means income.
  final Category? cat;
  final TxType type;
  if (q.type == null) {
    cat = fuzzyMatch(q.category, categories, (c) => c.name);
    type = cat?.kind == CategoryKind.income ? TxType.income : TxType.expense;
  } else {
    type = q.type!;
    final kind = type == TxType.income ? CategoryKind.income : CategoryKind.expense;
    cat = fuzzyMatch(q.category, categories.where((c) => c.kind == kind), (c) => c.name);
  }
  final account =
      fuzzyMatch(q.account, accounts, (a) => a.name) ??
      (q.currency == null ? null : accounts.where((a) => a.currency == q.currency).firstOrNull) ??
      accounts.firstOrNull;
  final scope = q.scope ?? cat?.defaultScope ?? Scope.personal;

  // Asked for a currency no account holds (or a named account in another
  // currency): never save LBP 150,000 into a USD account as $150,000.
  final currencyMismatch = q.currency != null && account != null && account.currency != q.currency;
  if (currencyMismatch) {
    showToast('No ${q.currency} account matched — check the entry before saving');
  }
  if (!q.saveDirectly || account == null || currencyMismatch) {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await showEntrySheet(
      ctx,
      prefill: EntryPrefill(
        type: type,
        amountCents: q.amountCents,
        categoryId: cat?.id,
        accountId: account?.id,
        scope: scope,
        note: q.note,
        day: q.day,
      ),
    );
    return;
  }

  final ledger = ref.read(ledgerProvider);
  final id = await ledger.addTransaction(
    TransactionsCompanion.insert(
      type: type,
      scope: scope,
      amountCents: q.amountCents!,
      accountId: account.id,
      categoryId: Value(cat?.id),
      occurredOn: q.day ?? Day.today(),
      note: Value(q.note ?? ''),
      tags: Value(EntryTags.store(q.tags)),
    ),
  );
  unawaited(HapticFeedback.mediumImpact());
  final parts = [
    Fx.format(q.amountCents!, account.currency),
    cat?.name ?? (q.category == null ? 'Uncategorised' : '“${q.category}” (no match)'),
    scope.label,
  ];
  showToast(
    '${type == TxType.income ? 'Received' : 'Logged'} ${parts.join(' · ')}',
    onUndo: () => ledger.deleteTransaction(id),
    duration: const Duration(seconds: 6),
  );
}

/// Folds a `text=` sentence into the link: explicit parameters still win.
Future<QuickAdd> _fromText(WidgetRef ref, QuickAdd q) async {
  final categories = await ref.read(categoriesProvider.future);
  final accounts = await ref.read(accountsProvider.future);
  final e = parseEntry(
    q.text!,
    categories: categories,
    memory: await ref.read(ledgerProvider).merchantCategoryMemory(),
    hasLbpAccount: accounts.any((a) => a.currency == 'LBP'),
  );
  final cat = categories.where((c) => c.id == e.categoryId).firstOrNull;
  return QuickAdd(
    amountCents: q.amountCents ?? e.amountCents,
    category: q.category ?? cat?.name,
    account: q.account,
    currency: q.currency ?? e.currency,
    tags: q.tags,
    scope: q.scope ?? e.scope,
    type: q.type ?? e.type,
    note: q.note ?? (e.note.isEmpty ? null : e.note),
    day: q.day ?? e.day,
    // A guessed currency is worth a glance before saving.
    confirm: q.confirm || e.currencyGuessed,
  );
}
